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
