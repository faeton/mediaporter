// High-level sync API — upload-first architecture.
// Upload files via AFC first, then short ATC session for metadata + registration.
//
// Decomposed so PipelineController can pipeline transcode + upload:
//   prepareSyncFiles(...)         → allocate asset IDs + device paths up front
//   AFCUploader(device)           → hold one AFC connection open across many files
//   registerUploadedFiles(...)    → single short ATC session at end

import Foundation

struct SyncResult {
    let fileURL: URL
    let success: Bool
    let error: String?
    let devicePath: String?
}

/// A sync item with its pre-allocated asset ID + target device path.
struct PreparedSyncFile {
    let item: SyncItem
    let assetID: Int
    let devicePath: String
    let slot: String

    var asSyncFileInfo: SyncFileInfo {
        SyncFileInfo(item: item, assetID: assetID, devicePath: devicePath, slot: slot)
    }
}

/// Pre-allocate asset IDs + device paths for every item. Pure — does not touch the device.
func prepareSyncFiles(_ items: [SyncItem]) -> [PreparedSyncFile] {
    items.map { item in
        let (path, slot) = ATCSession.generateDevicePath()
        let assetID = ATCSession.generateAssetID()
        return PreparedSyncFile(item: item, assetID: assetID, devicePath: path, slot: slot)
    }
}

/// Long-lived AFC connection — upload many files over one handle.
final class AFCUploader {
    private let afc: AFCClient

    init(device: DeviceInfo) throws {
        self.afc = try AFCClient(device: device)
    }

    /// Upload a single prepared file, reporting byte-level progress.
    /// The `isCancelled` closure is polled between 1 MB chunks.
    ///
    /// After AFC EOF, re-stats the remote path and compares to the local
    /// file size. libimobiledevice + pymobiledevice3 both query st_size
    /// after AFC write for the same reason: catch truncation / late AFC
    /// failures BEFORE ATC `FileComplete` tries to bind a broken asset.
    /// Throws `AFCError.sizeMismatch` on disagreement so the pipeline's
    /// cleanup path will FileError(0) the asset and unblock SyncFinished.
    /// A nil stat (afcd not reporting size on this iOS) is treated as
    /// non-fatal and only logged — we don't want a flaky stat layer to
    /// gate uploads that otherwise succeeded.
    func upload(
        _ file: PreparedSyncFile,
        progress: ((Int, Int) -> Void)? = nil,
        isCancelled: (() -> Bool)? = nil
    ) throws {
        afc.makedirs("/iTunes_Control/Music/\(file.slot)")
        try afc.writeFileStreaming(
            remotePath: file.devicePath,
            localURL: file.item.fileURL,
            progress: progress,
            isCancelled: isCancelled
        )
        let expected = Int64(
            (try? FileManager.default.attributesOfItem(
                atPath: file.item.fileURL.path)[.size] as? Int) ?? 0)
        guard expected > 0 else {
            DebugLog.write("afc.upload.verify",
                "\(file.devicePath) skipped — local stat returned 0")
            return
        }
        switch afc.statResult(file.devicePath) {
        case .ok(let actual):
            if actual != expected {
                DebugLog.write("afc.upload.verify",
                    "\(file.devicePath) MISMATCH expected=\(expected) actual=\(actual)")
                throw AFCError.sizeMismatch(
                    path: file.devicePath, expected: expected, actual: actual)
            }
            DebugLog.write("afc.upload.verify",
                "\(file.devicePath) size=\(actual) OK")
        case .missingSize:
            // afcd opened the info dict but didn't return st_size. Not seen on
            // shipping iOS; if it ever surfaces, surface it loudly here so we
            // can decide whether to escalate to a fatal.
            DebugLog.write("afc.upload.verify",
                "\(file.devicePath) stat dict has no st_size key (expected=\(expected)) — proceeding non-fatal")
        case .openFailed(let rc):
            // The file we just wrote can't be re-opened for info. Suspicious
            // but treat as non-fatal — usbmuxd / afcd hiccups happen, and
            // failing the upload here turns a noisy transient into a hard
            // user-visible error. Distinct log line so triage can tell this
            // from a genuine missing-key case.
            DebugLog.write("afc.upload.verify",
                "\(file.devicePath) stat open failed rc=\(rc) (expected=\(expected)) — proceeding non-fatal")
        }
    }

    func close() { afc.close() }
}

/// Run a single short ATC session to register every already-uploaded file with the device.
///
/// After a multi-GB pipelined upload run, the device's medialibraryd /
/// atc-mediasvc daemons can take several seconds to settle before they're
/// ready for a new ATC session. We do a brief settle sleep, and if the
/// handshake fails (typically "No ReadyForSync received" on a still-busy
/// daemon) retry it once with a longer pause.
func registerUploadedFiles(
    device: DeviceInfo,
    files: [PreparedSyncFile],
    verbose: Bool = false
) throws {
    let syncFiles = files.map { $0.asSyncFileInfo }

    var lastError: Error?
    for attempt in 0..<2 {
        // Settle delay before each attempt — short before the first, longer
        // before the retry. Lets the device's media indexer catch up.
        let settle: UInt32 = attempt == 0 ? 3 : 8
        sleep(settle)

        do {
            let session = ATCSession(device: device, verbose: verbose)
            let (grappa, anchorStr) = try session.handshake()
            let newAnchor = String(Int(anchorStr)! + 1)

            let plistData = session.buildSyncPlist(files: syncFiles, anchor: Int(newAnchor)!)
            let cigData = try session.computeCIG(deviceGrappa: grappa, plistData: plistData)

            let registerAFC = try AFCClient(device: device)
            try session.register(
                afc: registerAFC,
                files: syncFiles,
                plistData: plistData,
                cigData: cigData,
                anchor: newAnchor
            )
            registerAFC.close()
            session.close()
            return
        } catch let err as SyncError {
            // Only retry handshake failures — anything past the handshake
            // (CIG, plist write, file complete) is likely a real protocol
            // problem and a second attempt won't help.
            if case .handshakeFailed = err {
                lastError = err
                continue
            }
            throw err
        }
    }
    throw lastError ?? SyncError.handshakeFailed("ATC handshake failed after retry")
}

/// Streaming-register lifecycle for the pipelined runner (plan #8).
///
/// Shape: open → registerFile per uploaded file → finish.
/// Wraps ATCSession: handshake retry on the open call (matches the legacy
/// `registerUploadedFiles` behaviour), keeps a single ATC + AFC connection
/// alive across the whole batch.
///
/// Caller responsibilities:
/// - Build the full plist+CIG up front (all asset IDs / device paths must
///   be known before `open` — medialibraryd doesn't accept new operations
///   after MetadataSyncFinished).
/// - Upload bytes via a separate AFCUploader (different AFC connection);
///   call `registerFile(...)` immediately after each upload finishes.
/// - On any failure that leaves an asset un-uploaded, call
///   `abandonAsset(assetID:)` so SyncFinished isn't blocked.
final class RegisterSession {
    private let device: DeviceInfo
    private let verbose: Bool
    private var session: ATCSession?
    private var afc: AFCClient?

    init(device: DeviceInfo, verbose: Bool = false) {
        self.device = device
        self.verbose = verbose
    }

    /// Opens the ATC session, writes plist+CIG, sends MetadataSyncFinished,
    /// waits for AssetManifest, clears stale pending assets, starts the
    /// Ping drainer. Retries the handshake once with a longer settle —
    /// after a multi-GB upload session medialibraryd can take seconds to
    /// be ready.
    ///
    /// `files` carries the SyncFileInfos used for the plist build. fileSize
    /// inside the items is unused at this stage (plist doesn't reference
    /// it); callers can pass placeholder sizes if real values aren't known
    /// yet.
    func open(files: [SyncFileInfo], progress: ((String) -> Void)? = nil) throws {
        var lastError: Error?
        for attempt in 0..<2 {
            // Fresh session per attempt — handshake leaves stale state if
            // it half-completes. Brief settle even on first attempt so
            // medialibraryd has a moment to commit any in-flight state from
            // the previous run; longer on retry.
            let settle: UInt32 = attempt == 0 ? 2 : 6
            progress?(attempt == 0
                ? "Waiting for device to settle…"
                : "Retrying after handshake failure — waiting longer…")
            sleep(settle)

            let s = ATCSession(device: device, verbose: verbose)
            do {
                progress?("Connecting to device (ATC handshake)…")
                let (grappa, anchorStr) = try s.handshake()
                let newAnchor = String(Int(anchorStr)! + 1)
                progress?("Building sync manifest…")
                let plistData = s.buildSyncPlist(files: files, anchor: Int(newAnchor)!)
                let cigData = try s.computeCIG(deviceGrappa: grappa, plistData: plistData)
                let registerAFC = try AFCClient(device: device)
                try s.prepareSync(
                    afc: registerAFC, files: files,
                    plistData: plistData, cigData: cigData, anchor: newAnchor,
                    progress: progress
                )
                self.session = s
                self.afc = registerAFC
                return
            } catch let err as SyncError {
                s.close()
                if case .handshakeFailed = err {
                    lastError = err
                    continue
                }
                throw err
            } catch {
                s.close()
                throw error
            }
        }
        throw lastError ?? SyncError.handshakeFailed("ATC handshake failed after retry")
    }

    func registerFile(_ f: SyncFileInfo) throws {
        guard let session else { throw SyncError.handshakeFailed("registerFile before open") }
        try session.registerFile(f)
    }

    func beginFile(_ f: SyncFileInfo) throws {
        guard let session else { throw SyncError.handshakeFailed("beginFile before open") }
        try session.beginFile(f)
    }

    func completeFile(_ f: SyncFileInfo) throws {
        guard let session else { throw SyncError.handshakeFailed("completeFile before open") }
        try session.completeFile(f)
    }

    func abandonAsset(assetID: Int) {
        session?.abandonAsset(assetID: assetID)
    }

    func sendProgress(assetID: Int, fraction: Double) {
        session?.sendProgress(assetID: assetID, fraction: fraction)
    }

    func finish() {
        session?.finishSync()
        afc?.close(); afc = nil
        session?.close(); session = nil
    }

    /// Cancel-path finalization. After the caller has abandoned every
    /// in-flight / pending asset via `abandonAsset`, give medialibraryd
    /// a short window to commit those FileError(0)s — without this, the
    /// network buffer can carry our messages but `close()`'s
    /// `ATH.invalidate` may tear the socket down before they're flushed.
    /// Empirically a few seconds is enough; we cap at `deadlineSeconds`
    /// so a cancelling user isn't stuck on the 120 s normal-path wait.
    /// (#15 from research/docs/ATC_PIPELINE_OPTIMIZATION.md.)
    func finishGraceful(deadlineSeconds: TimeInterval = 15) {
        session?.finishSync(deadlineSeconds: deadlineSeconds)
        afc?.close(); afc = nil
        session?.close(); session = nil
    }

    /// Tear down without waiting for SyncFinished. Reserved for paths
    /// where the session is already known to be unusable (handshake
    /// failure, mid-handshake error) — for cancel/error AFTER a
    /// successful open, prefer `finishGraceful` so abandons get flushed.
    func close() {
        afc?.close(); afc = nil
        session?.close(); session = nil
    }
}

/// Remove previously-synced assets from the device's MediaLibrary.
///
/// Wire flow per codex review (2026-05-17) + T5 evidence in
/// research/docs/PHANTOM_REP_PID_TESTS.md:
///   1. ATC handshake.
///   2. Write a delete-only sync plist (single `delete_track` op per
///      `syncID`, no `update_db_info`) + CIG via AFC.
///   3. Send `MetadataSyncFinished`. Drain Pings, accept AssetManifest
///      if it shows up but DO NOT require it (delete-only sessions
///      sometimes get no manifest and still commit).
///   4. Wait for `SyncFinished`.
///   5. AFC.remove the media file at each `mediaPath` and the
///      `/Airlock/Media/Artwork/<syncID>` artwork blob. Missing files
///      are tolerated (ENOENT = already gone, treat as success).
///
/// `syncIDs` MUST be `item_store.sync_id` from the on-device DB — the
/// original wire pid from the original insert. Passing `item.item_pid`
/// (the renumbered DB pid) silently no-ops because medialibraryd
/// resolves deletes against `sync_id`.
///
/// Returns the number of media paths actually removed (i.e. existed at
/// AFC level before the call).
public struct DeleteResult: Sendable {
    public let syncIDsSubmitted: Int
    public let mediaFilesRemoved: Int
    public let artworkBlobsRemoved: Int
}

public func deleteFromDevice(
    syncIDs: [Int],
    mediaPaths: [String],
    artworkSyncIDs: [Int] = [],
    verbose: Bool = false
) throws -> DeleteResult {
    guard !syncIDs.isEmpty else {
        return DeleteResult(syncIDsSubmitted: 0, mediaFilesRemoved: 0, artworkBlobsRemoved: 0)
    }
    let device = try discoverDevice()

    let session = ATCSession(device: device, verbose: verbose)
    let (grappa, anchorStr) = try session.handshake()
    let newAnchor = String(Int(anchorStr)! + 1)
    let plistData = session.buildDeletePlist(syncIDs: syncIDs, anchor: Int(newAnchor)!)
    let cigData = try session.computeCIG(deviceGrappa: grappa, plistData: plistData)

    let afc = try AFCClient(device: device)
    try session.prepareDelete(
        afc: afc, plistData: plistData, cigData: cigData, anchor: newAnchor
    )
    session.finishSync()

    // Now physical cleanup. Pure AFC; we tolerate ENOENT because the
    // device may have already GC'd the file between our DB query and
    // our delete.
    var mediaRemoved = 0
    for p in mediaPaths {
        let rc = afc.removePath(p)
        if rc == 0 {
            mediaRemoved += 1
            DebugLog.write("atc.delete.file", "removed \(p)")
        } else {
            DebugLog.notice("atc.delete.file", "remove \(p) rc=\(rc) (ignored — likely already gone)")
        }
    }
    var artworkRemoved = 0
    for sid in artworkSyncIDs {
        let path = "/Airlock/Media/Artwork/\(sid)"
        let rc = afc.removePath(path)
        if rc == 0 {
            artworkRemoved += 1
            DebugLog.write("atc.delete.artwork", "removed \(path)")
        } else {
            DebugLog.notice("atc.delete.artwork", "remove \(path) rc=\(rc) (ignored — likely already gone)")
        }
    }

    afc.close()
    session.close()
    return DeleteResult(
        syncIDsSubmitted: syncIDs.count,
        mediaFilesRemoved: mediaRemoved,
        artworkBlobsRemoved: artworkRemoved
    )
}

/// One-shot sync: upload all files, then register. Kept for non-pipelined callers.
func syncFiles(
    items: [SyncItem],
    verbose: Bool = false,
    progress: ((String, Int, Int) -> Void)? = nil
) throws -> [SyncResult] {
    guard !items.isEmpty else { return [] }

    let device = try discoverDevice()
    if verbose { print("Device: \(device.udid)") }

    let prepared = prepareSyncFiles(items)

    if verbose { print("  Pre-uploading files via AFC...") }
    let uploader = try AFCUploader(device: device)
    for f in prepared {
        if verbose {
            print("  AFC: uploading \(f.item.fileURL.lastPathComponent) -> \(f.devicePath) (\(f.item.fileSize / 1_048_576) MB)")
        }
        try uploader.upload(f) { sent, total in
            progress?(f.item.title, sent, total)
        }
    }
    uploader.close()

    try registerUploadedFiles(device: device, files: prepared, verbose: verbose)

    return prepared.map { f in
        SyncResult(fileURL: f.item.fileURL, success: true, error: nil, devicePath: f.devicePath)
    }
}
