// Cross-session memory of pending assets the device refuses to let go of.
//
// Why this exists — the failure it heals (HISTORY 2026-08-03, CLAUDE.md #16):
//
// An asset announced in the sync plist has a delivery window that expires in
// under a minute of post-AssetManifest idle. Miss it and FileBegin/FileComplete
// are still ACCEPTED on the wire but bind nothing: the row lands with
// `base_location_id = 0` and `location = ''`, the uploaded bytes are GC-swept,
// and SyncFinished never arrives. The asset then stays *pending* on the device
// forever — it reappears in every later AssetManifest and blocks SyncFinished
// for every subsequent sync, including tiny ones that have nothing to do with it.
//
// `prepareSync` already fires `FileError(ErrorCode: 0)` at stale IDs, which is
// the documented way to drop a pending asset (CLAUDE.md #8) and works fine for
// assets that merely failed mid-transfer. It does NOT clear an *expired* one —
// verified across two sessions. The only thing that does is `delete_track` on
// the underlying row, which needs its own delete-only session and therefore
// cannot happen from inside the sync session that observed the problem.
//
// Hence the ledger: session N records the stale IDs it tried and failed to
// clear, and the *next* run consults it before opening its own session. An ID
// that survives a FileError(0) and shows up in a later manifest is, by
// construction, one FileError(0) has demonstrably failed on.
//
// Deleting rows out from under the user is not something to do on a hunch, so
// escalation is gated on all four of:
//   1. the ID appeared in an AssetManifest at least twice, with a FileError(0)
//      sent between the sightings (`sightings >= escalationThreshold`),
//   2. it is not an asset the current run is shipping,
//   3. a row with that `item_store.sync_id` actually exists, and
//   4. that row is provably UNBOUND (`base_location_id = 0`, empty location)
//      — i.e. it is already broken and unplayable, so deleting it destroys
//      nothing the user can currently use.
// Every escalation is logged at `.notice` and surfaced in the run status.
//
// Storage is UserDefaults keyed by device UDID, in the app's defaults domain
// so the GUI and `mediaporterctl` share one ledger (same hop as `Credentials`).

import Foundation

public enum StuckAssetLedger {
    /// Manifest sightings required before an ID becomes deletable. Two means
    /// "we saw it, sent FileError(0), and it came back anyway".
    public static let escalationThreshold = 2

    private static let defaultsKey = "stuckPendingAssets"

    /// Shared defaults store. Mirrors `Credentials.appDefaults()`: the app's
    /// own domain is `UserDefaults.standard`, and `UserDefaults(suiteName:)`
    /// returns nil when handed your own bundle identifier.
    private static var store: UserDefaults {
        if Bundle.main.bundleIdentifier == Credentials.appDefaultsDomain {
            return .standard
        }
        return UserDefaults(suiteName: Credentials.appDefaultsDomain) ?? .standard
    }

    /// udid → (assetID string → sighting count)
    private static func load() -> [String: [String: Int]] {
        store.dictionary(forKey: defaultsKey) as? [String: [String: Int]] ?? [:]
    }

    private static func save(_ v: [String: [String: Int]]) {
        store.set(v, forKey: defaultsKey)
    }

    /// Record the stale IDs a just-opened session found in its AssetManifest,
    /// and drop any previously-tracked ID that did NOT come back (that one got
    /// cleared, so it's no longer stuck). Call once per manifest, right after
    /// the FileError(0) sweep.
    ///
    /// Returns the IDs that have now crossed `escalationThreshold`.
    @discardableResult
    public static func recordManifest(staleIDs: [String], udid: String) -> [Int64] {
        var all = load()
        let previous = all[udid] ?? [:]
        var current: [String: Int] = [:]
        for id in staleIDs {
            // Only IDs still present keep their history; absent ones fall away
            // with `previous` because we rebuild rather than merge.
            current[id] = (previous[id] ?? 0) + 1
        }
        if current.isEmpty {
            all.removeValue(forKey: udid)
        } else {
            all[udid] = current
        }
        save(all)

        let cleared = previous.keys.filter { current[$0] == nil }
        if !cleared.isEmpty {
            DebugLog.notice("atc.stuck.cleared",
                "FileError(0) worked for \(cleared.count) asset(s): \(cleared.sorted().joined(separator: ","))")
        }
        let escalated = current.filter { $0.value >= escalationThreshold }.keys.compactMap(Int64.init)
        if !escalated.isEmpty {
            DebugLog.notice("atc.stuck.escalate",
                "\(escalated.count) asset(s) survived FileError(0) and will be delete_track'd on the next run: "
                + escalated.map(String.init).sorted().joined(separator: ","))
        }
        return escalated.sorted()
    }

    /// IDs recorded for this device that have crossed the threshold. Read by
    /// the pre-run heal pass before any session is opened.
    public static func escalatable(udid: String) -> [Int64] {
        let entry = load()[udid] ?? [:]
        return entry.filter { $0.value >= escalationThreshold }
            .keys.compactMap(Int64.init).sorted()
    }

    /// Every tracked ID for this device with its sighting count — diagnostics
    /// (`mediaporterctl heal --dry-run`) and nothing else.
    public static func all(udid: String) -> [Int64: Int] {
        var out: [Int64: Int] = [:]
        for (k, v) in load()[udid] ?? [:] {
            if let id = Int64(k) { out[id] = v }
        }
        return out
    }

    /// Drop IDs from the ledger once they've been dealt with (deleted, or
    /// found to be absent from the device entirely).
    public static func forget(_ ids: [Int64], udid: String) {
        guard !ids.isEmpty else { return }
        var all = load()
        guard var entry = all[udid] else { return }
        for id in ids { entry.removeValue(forKey: String(id)) }
        if entry.isEmpty { all.removeValue(forKey: udid) } else { all[udid] = entry }
        save(all)
    }

    public static func reset(udid: String) {
        var all = load()
        all.removeValue(forKey: udid)
        save(all)
    }
}

/// Outcome of one auto-heal pass, for logging and the UI notice.
public struct HealResult: Sendable {
    /// Rows actually removed via `delete_track`.
    public var deleted: [Int64] = []
    /// Tracked IDs that turned out to be BOUND — a real, playable row. Never
    /// deleted; left alone and dropped from the ledger so we stop watching them.
    public var skippedBound: [Int64] = []
    /// Tracked IDs with no row at all. Nothing to delete; forgotten.
    public var skippedMissing: [Int64] = []
    /// Non-fatal problems (DB pull failed, delete session failed).
    public var problems: [String] = []

    public var didSomething: Bool { !deleted.isEmpty }

    /// One-line summary for the run status, or nil when nothing happened.
    public var summary: String? {
        guard !deleted.isEmpty else { return nil }
        return deleted.count == 1
            ? "Cleared 1 stuck library entry left over from a failed sync"
            : "Cleared \(deleted.count) stuck library entries left over from failed syncs"
    }
}

/// Delete rows for assets that are stuck pending on the device AND provably
/// unbound. Safe to call before every run: it is a no-op unless a previous
/// session recorded an ID that outlived its FileError(0).
///
/// Must run with NO sync session open — `deleteFromDevice` opens its own
/// delete-only session, and two concurrent ATC sessions do not coexist.
///
/// `excluding` is the current run's asset IDs. They're freshly generated
/// 18-digit randoms so a collision is vanishingly unlikely, but an in-flight
/// asset is the one thing that must never be deleted, so it's checked anyway.
public func healStuckAssets(
    device: DeviceInfo,
    excluding inFlight: Set<Int64> = [],
    verbose: Bool = false
) -> HealResult {
    var result = HealResult()
    let tracked = StuckAssetLedger.escalatable(udid: device.udid)
        .filter { !inFlight.contains($0) }
    guard !tracked.isEmpty else { return result }

    DebugLog.notice("heal.begin", "candidates=\(tracked.map(String.init).joined(separator: ","))")

    let rows: [Int64: DeleteCandidate]
    do {
        rows = try findDeleteCandidates(bySyncIDs: tracked, device: device)
    } catch {
        // Can't verify → don't delete. The ledger keeps the IDs for next time.
        result.problems.append("couldn't read device library: \(error.localizedDescription)")
        DebugLog.error("heal.verify", "library read failed: \(error.localizedDescription)")
        return result
    }

    var toDelete: [Int64] = []
    for id in tracked {
        guard let row = rows[id] else {
            // Pending on the device but no row to delete — nothing this
            // function can do, and nothing to protect. Stop tracking it.
            result.skippedMissing.append(id)
            continue
        }
        if row.isBound {
            // A real, playable row. Its presence in the manifest is something
            // else's problem; deleting it would destroy working content.
            result.skippedBound.append(id)
            DebugLog.notice("heal.skip",
                "\(id) is BOUND (\(row.mediaPath ?? "?")) — refusing to delete")
            continue
        }
        toDelete.append(id)
    }

    if !toDelete.isEmpty {
        do {
            // No mediaPaths: an unbound row by definition points at no file.
            // Artwork can still exist at /Airlock/Media/Artwork/<syncID>
            // (it's uploaded during completeFile, before binding is settled),
            // so hand the IDs over for blob cleanup — missing blobs are
            // tolerated as ENOENT.
            let r = try deleteFromDevice(
                syncIDs: toDelete.map(Int.init),
                mediaPaths: [],
                artworkSyncIDs: toDelete.map(Int.init),
                verbose: verbose
            )
            result.deleted = toDelete
            DebugLog.notice("heal.deleted",
                "submitted=\(r.syncIDsSubmitted) files=\(r.mediaFilesRemoved) artwork=\(r.artworkBlobsRemoved) ids=\(toDelete.map(String.init).joined(separator: ","))")
        } catch {
            result.problems.append("delete failed: \(error.localizedDescription)")
            DebugLog.error("heal.delete", "failed: \(error.localizedDescription)")
        }
    }

    // Forget everything we resolved. Anything that failed stays tracked so the
    // next run retries it.
    StuckAssetLedger.forget(
        result.deleted + result.skippedBound + result.skippedMissing,
        udid: device.udid
    )
    return result
}
