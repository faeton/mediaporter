// Snapshot of the device's media library for duplicate detection (#10b).
//
// On each analyze run (when the device is connected) we pull
// MediaLibrary.sqlitedb via AFC and read item_extra to learn what's already
// there. analyzeOne then tags each FileJob whose (title, durationMs) matches
// an existing entry so the UI can show "on device" and the pipeline can skip
// it by default.
//
// Match key: title + duration_ms (±2 s tolerance). Title is what SyncItem
// would set in the plist — episode title for TV, movie/file title for
// movies. duration_ms is from ffprobe (incoming) vs total_time_ms (on
// device); they round-trip exactly when we sync, so the only slack is
// floating-point.
//
// Same DB-pull mechanic as gate-test: pull .sqlitedb + -wal + -shm
// (medialibraryd is in WAL mode, recent commits live in -wal). Read-only
// sqlite3 query against the local copy — never touch the device's open
// database.

import Foundation

public struct DeviceLibraryEntry: Sendable, Hashable {
    public let title: String
    public let durationMs: Int
}

public enum DeviceLibraryQueryError: LocalizedError {
    case sqlite3Missing
    case dbPullFailed(String)
    case queryFailed(String)

    public var errorDescription: String? {
        switch self {
        case .sqlite3Missing: return "/usr/bin/sqlite3 not found"
        case .dbPullFailed(let m): return "Failed to pull MediaLibrary.sqlitedb: \(m)"
        case .queryFailed(let m): return "sqlite3 query failed: \(m)"
        }
    }
}

private let dbDir = "/iTunes_Control/iTunes"
private let dbFiles = ["MediaLibrary.sqlitedb", "MediaLibrary.sqlitedb-wal", "MediaLibrary.sqlitedb-shm"]

/// Pull the device's MediaLibrary.sqlitedb and return every (title,
/// total_time_ms) row. Returns an empty array if the device is offline or
/// the DB can't be parsed — callers treat that as "no dedup info" rather
/// than failing the analyze run.
public func loadDeviceLibrary(device: DeviceInfo) throws -> [DeviceLibraryEntry] {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("mp-devlib-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }

    let afc: AFCClient
    do {
        afc = try AFCClient(device: device)
    } catch {
        throw DeviceLibraryQueryError.dbPullFailed(error.localizedDescription)
    }
    defer { afc.close() }

    var mainPulled = false
    for f in dbFiles {
        do {
            let data = try afc.readFile("\(dbDir)/\(f)")
            try data.write(to: tmp.appendingPathComponent(f))
            if f == dbFiles[0] { mainPulled = true }
        } catch {
            // -wal / -shm can legitimately be missing right after a
            // checkpoint. The main .sqlitedb missing is fatal.
            if f == dbFiles[0] {
                throw DeviceLibraryQueryError.dbPullFailed(error.localizedDescription)
            }
        }
    }
    guard mainPulled else { return [] }

    let dbPath = tmp.appendingPathComponent(dbFiles[0]).path
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    proc.arguments = [
        "-readonly", "-separator", "\t", dbPath,
        // Filter to entries that actually correspond to video files we'd
        // sync — saves parsing musical content / podcasts / etc. on busy
        // devices. media_kind 2 = movie, 32 = TV show (per
        // research/docs/MEDIA_LIBRARY_DB.md).
        "SELECT title, CAST(total_time_ms AS INTEGER) FROM item_extra WHERE media_kind IN (2, 32);"
    ]
    let out = Pipe()
    proc.standardOutput = out
    proc.standardError = FileHandle.nullDevice
    do {
        try proc.run()
        proc.waitUntilExit()
    } catch {
        throw DeviceLibraryQueryError.queryFailed(error.localizedDescription)
    }
    guard proc.terminationStatus == 0 else {
        throw DeviceLibraryQueryError.queryFailed("sqlite3 exit \(proc.terminationStatus)")
    }

    let raw = out.fileHandleForReading.readDataToEndOfFile()
    guard let text = String(data: raw, encoding: .utf8) else { return [] }

    var entries: [DeviceLibraryEntry] = []
    for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
        let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { continue }
        let title = String(parts[0])
        guard let dur = Int(parts[1]) else { continue }
        entries.append(DeviceLibraryEntry(title: title, durationMs: dur))
    }
    return entries
}

/// A row on the device that the user could ask us to delete. `syncID`
/// is the load-bearing field for ATC `delete_track` — it's the original
/// wire pid captured in `item_store.sync_id`, not the renumbered DB
/// `item_pid`. `mediaPath` is what we'll `afc.remove(...)` after the
/// ATC delete commits.
public struct DeleteCandidate: Sendable {
    public let itemPid: Int64       // for display only
    public let syncID: Int64        // wire pid → what we send in delete_track
    public let title: String
    public let mediaPath: String?   // /iTunes_Control/Music/Fxx/yyyy.mp4 (nil if unbound)
    public let mediaKind: Int       // 2 movie, 32 TV show
    public let totalTimeMs: Int

    public init(itemPid: Int64, syncID: Int64, title: String,
                mediaPath: String?, mediaKind: Int, totalTimeMs: Int) {
        self.itemPid = itemPid; self.syncID = syncID; self.title = title
        self.mediaPath = mediaPath; self.mediaKind = mediaKind
        self.totalTimeMs = totalTimeMs
    }
}

/// Find delete candidates by title substring (case-insensitive). Pulls
/// the device DB (+ WAL/SHM) and runs the codex-recommended join
/// (item × item_extra × item_store × base_location).
public func findDeleteCandidates(
    titleLike: String, device: DeviceInfo
) throws -> [DeleteCandidate] {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("mp-delete-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }

    let afc: AFCClient
    do { afc = try AFCClient(device: device) }
    catch { throw DeviceLibraryQueryError.dbPullFailed(error.localizedDescription) }
    defer { afc.close() }

    var mainPulled = false
    for f in dbFiles {
        do {
            let data = try afc.readFile("\(dbDir)/\(f)")
            try data.write(to: tmp.appendingPathComponent(f))
            if f == dbFiles[0] { mainPulled = true }
        } catch {
            if f == dbFiles[0] {
                throw DeviceLibraryQueryError.dbPullFailed(error.localizedDescription)
            }
        }
    }
    guard mainPulled else { return [] }

    let dbPath = tmp.appendingPathComponent(dbFiles[0]).path
    // We pass the pattern as a literal parameter via SQLite's `-cmd .param`
    // dance — but sqlite3 CLI's parameter binding is awkward, so we use the
    // simpler approach: escape single quotes in the pattern and embed it.
    // Risk is purely local to this Mac process; no untrusted input.
    let escaped = titleLike.replacingOccurrences(of: "'", with: "''")
    let sql = """
    SELECT
      i.item_pid,
      COALESCE(s.sync_id, 0),
      e.title,
      COALESCE(bl.path || '/' || e.location, ''),
      COALESCE(e.media_kind, 0),
      COALESCE(CAST(e.total_time_ms AS INTEGER), 0)
    FROM item i
    JOIN item_extra e ON e.item_pid = i.item_pid
    LEFT JOIN item_store s ON s.item_pid = i.item_pid
    LEFT JOIN base_location bl ON bl.base_location_id = i.base_location_id
    WHERE LOWER(e.title) LIKE LOWER('%\(escaped)%');
    """
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    proc.arguments = ["-readonly", "-separator", "\t", dbPath, sql]
    let out = Pipe()
    let err = Pipe()
    proc.standardOutput = out
    proc.standardError = err
    do { try proc.run(); proc.waitUntilExit() }
    catch { throw DeviceLibraryQueryError.queryFailed(error.localizedDescription) }
    let errText = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    guard proc.terminationStatus == 0 else {
        throw DeviceLibraryQueryError.queryFailed("sqlite3 exit \(proc.terminationStatus): \(errText)")
    }
    let raw = out.fileHandleForReading.readDataToEndOfFile()
    guard let text = String(data: raw, encoding: .utf8) else { return [] }

    var candidates: [DeleteCandidate] = []
    for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
        let parts = line.split(separator: "\t", maxSplits: 5,
            omittingEmptySubsequences: false)
        guard parts.count == 6,
              let itemPid = Int64(parts[0]),
              let syncID = Int64(parts[1]),
              let kind = Int(parts[4]),
              let dur = Int(parts[5]) else { continue }
        let title = String(parts[2])
        let pathFrag = String(parts[3])
        let mediaPath: String? = pathFrag.isEmpty ? nil : "/\(pathFrag)"
        candidates.append(DeleteCandidate(
            itemPid: itemPid, syncID: syncID, title: title,
            mediaPath: mediaPath, mediaKind: kind, totalTimeMs: dur
        ))
    }
    return candidates
}

public extension Array where Element == DeviceLibraryEntry {
    /// True if any entry matches the given title (exact) within ±2 s of
    /// the given duration. Used by analyzeOne to flag duplicate jobs.
    func contains(title: String, durationMs: Int) -> Bool {
        let tolerance = 2000
        return contains { e in
            e.title == title && abs(e.durationMs - durationMs) <= tolerance
        }
    }
}

/// Cleanup-side reading of the device library: which `/iTunes_Control/Music/Fxx/<name>`
/// paths the device's medialibraryd considers registered. The path is the
/// concatenation of `base_location.path` (e.g. `iTunes_Control/Music/F39`)
/// and `item_extra.location` (e.g. `FSYH.mp4`), normalized with a leading
/// slash to match what `DeviceMaintenance.scanStagingMedia` returns.
///
/// Used to identify true orphans: scanned files that don't appear in this
/// set are leftovers from abandoned syncs and safe to delete.
public struct RegisteredPaths: Sendable {
    /// Fully-qualified registered paths (e.g. /iTunes_Control/Music/F39/FSYH.mp4).
    public let paths: Set<String>
    /// Slot directories (e.g. F39) that have at least one item row but no
    /// resolvable filename — the row exists with `base_location_id > 0` but
    /// `item_extra.location` is empty (binding still in flight from a fresh
    /// sync). Anything in those slots gets the benefit of the doubt and is
    /// kept regardless of filename match.
    public let pendingSlots: Set<String>
}

public func loadDeviceRegisteredPaths(device: DeviceInfo) throws -> RegisteredPaths {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("mp-devpaths-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }

    let afc: AFCClient
    do { afc = try AFCClient(device: device) }
    catch { throw DeviceLibraryQueryError.dbPullFailed(error.localizedDescription) }
    defer { afc.close() }

    var mainPulled = false
    for f in dbFiles {
        do {
            let data = try afc.readFile("\(dbDir)/\(f)")
            try data.write(to: tmp.appendingPathComponent(f))
            if f == dbFiles[0] { mainPulled = true }
        } catch {
            if f == dbFiles[0] {
                throw DeviceLibraryQueryError.dbPullFailed(error.localizedDescription)
            }
        }
    }
    guard mainPulled else { return RegisteredPaths(paths: [], pendingSlots: []) }

    let dbPath = tmp.appendingPathComponent(dbFiles[0]).path
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    // Outer left join — we want rows where base_location_id > 0 even if
    // item_extra.location hasn't been populated yet (post-sync binding lag,
    // observed during the re-upload diagnostic). For those we report just
    // the slot dir in pendingSlots and skip the path entry.
    proc.arguments = [
        "-readonly", "-separator", "\t", dbPath,
        """
        SELECT COALESCE(bl.path, ''), COALESCE(e.location, '')
        FROM item i
        LEFT JOIN base_location bl ON bl.base_location_id = i.base_location_id
        LEFT JOIN item_extra e ON e.item_pid = i.item_pid
        WHERE i.base_location_id > 0;
        """
    ]
    let out = Pipe()
    proc.standardOutput = out
    proc.standardError = FileHandle.nullDevice
    do {
        try proc.run()
        proc.waitUntilExit()
    } catch {
        throw DeviceLibraryQueryError.queryFailed(error.localizedDescription)
    }
    guard proc.terminationStatus == 0 else {
        throw DeviceLibraryQueryError.queryFailed("sqlite3 exit \(proc.terminationStatus)")
    }

    let raw = out.fileHandleForReading.readDataToEndOfFile()
    guard let text = String(data: raw, encoding: .utf8) else {
        return RegisteredPaths(paths: [], pendingSlots: [])
    }

    var paths = Set<String>()
    var pendingSlots = Set<String>()
    for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
        let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { continue }
        let basePath = String(parts[0])
        let filename = String(parts[1])
        guard basePath.hasPrefix("iTunes_Control/Music/") else { continue }
        let slot = basePath.split(separator: "/").last.map(String.init) ?? ""
        if filename.isEmpty {
            if !slot.isEmpty { pendingSlots.insert(slot) }
        } else {
            paths.insert("/\(basePath)/\(filename)")
        }
    }
    return RegisteredPaths(paths: paths, pendingSlots: pendingSlots)
}
