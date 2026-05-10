// Gating experiment for plan.md P1 #8 (interleave register with upload).
//
// Hypothesis under test: medialibraryd commits per FileComplete, so
// interleaving register messages with the upload loop would land each row
// progressively instead of in a 30 s/file burst at terminal SyncFinished.
//
// Method: upload two files via AFC, then run the normal register flow
// EXCEPT — between FileComplete #1 and FileComplete #2 we sleep ~60 s
// (Ping-aware so the session doesn't drop) and pull MediaLibrary.sqlitedb
// twice (T+0 immediately after FileComplete #1, T+60 after the sleep).
// Each pull is queried for the two filenames in `item_extra.location`.
//
// Verdict:
// - file1 row at T+0 or T+60 → medialibraryd commits per file → #8 viable
// - both rows only after register returns → buffer-until-terminal → #8 dies
//
// Caller is the CLI subcommand `gate-test`. Production sync paths do not
// touch this file.

import Foundation

public struct GateTestReport {
    public var file1Name: String
    public var file2Name: String
    public var rowsAtT0: Set<String>      // basenames seen in DB right after FileComplete #1
    public var rowsAtT60: Set<String>     // basenames seen 60 s later, still pre-FileComplete #2
    public var rowsAfterRegister: Set<String> // basenames seen after register() returns
    public var registerSeconds: Double
    public var sleepSeconds: Double
}

public enum GateTestError: LocalizedError {
    case sqlite3Missing
    case dbPullFailed(String)
    case sqliteQueryFailed(String)
    case probeFailed(String)
    case afcOpenFailed(String)

    public var errorDescription: String? {
        switch self {
        case .sqlite3Missing: return "/usr/bin/sqlite3 not found"
        case .dbPullFailed(let m): return "DB pull failed: \(m)"
        case .sqliteQueryFailed(let m): return "sqlite3 query failed: \(m)"
        case .probeFailed(let m): return "probe failed: \(m)"
        case .afcOpenFailed(let m): return "AFC open failed: \(m)"
        }
    }
}

private let dbDir = "/iTunes_Control/iTunes"
private let dbFile = "MediaLibrary.sqlitedb"
private let dbWal  = "MediaLibrary.sqlitedb-wal"
private let dbShm  = "MediaLibrary.sqlitedb-shm"

/// Exercises the streaming register path (RegisterSession + ATCSession's
/// prepareSync/registerFile/finishSync) end-to-end on two files. Pulls
/// MediaLibrary.sqlitedb after each registerFile so the operator can see
/// rows materialize per-file instead of in a batch. Used to validate the
/// plan #8 refactor without going through the GUI.
public func streamingRegisterSmokeTest(
    file1: URL, file2: URL,
    log: @escaping (String) -> Void = { print($0) }
) async throws {
    let device = try discoverDevice()
    log("Device: \(device.displayName) (\(device.udid.prefix(16))...)")

    let info1 = try await probeFile(url: file1)
    let info2 = try await probeFile(url: file2)
    let item1 = makeSyncItem(url: file1, duration: info1.duration)
    let item2 = makeSyncItem(url: file2, duration: info2.duration)
    let prepared = prepareSyncFiles([item1, item2])
    let p1 = prepared[0], p2 = prepared[1]
    let basename1 = (p1.devicePath as NSString).lastPathComponent
    let basename2 = (p2.devicePath as NSString).lastPathComponent
    log("Asset paths:")
    log("  #1 \(p1.devicePath) (asset=\(p1.assetID))")
    log("  #2 \(p2.devicePath) (asset=\(p2.assetID))")

    // Open the streaming register session UP FRONT — before any byte ships.
    // This is the #8 production order: plist + AssetManifest first, then
    // upload+register per file.
    log("Opening RegisterSession (streaming)...")
    let openStart = Date()
    let session = RegisterSession(device: device, verbose: true)
    try session.open(files: [p1.asSyncFileInfo, p2.asSyncFileInfo])
    log("  open complete in \(String(format: "%.2f", Date().timeIntervalSince(openStart)))s")

    let probeAFC = try AFCClient(device: device)
    defer { probeAFC.close() }

    // File 1: upload + registerFile, then probe DB.
    log("Uploading file 1...")
    let u1 = try AFCUploader(device: device)
    try u1.upload(p1)
    u1.close()
    log("  upload OK; sending FileBegin/FileComplete...")
    try session.registerFile(p1.asSyncFileInfo)
    log("  registered. probing DB...")
    let after1 = pullAndQuery(probeAFC: probeAFC, names: [basename1, basename2], log: log)
    log("  rows after file 1 register: \(after1.sorted().joined(separator: ", "))")

    // File 2: upload + registerFile, then probe DB.
    log("Uploading file 2...")
    let u2 = try AFCUploader(device: device)
    try u2.upload(p2)
    u2.close()
    log("  upload OK; sending FileBegin/FileComplete...")
    try session.registerFile(p2.asSyncFileInfo)
    log("  registered. probing DB...")
    let after2 = pullAndQuery(probeAFC: probeAFC, names: [basename1, basename2], log: log)
    log("  rows after file 2 register: \(after2.sorted().joined(separator: ", "))")

    log("Calling finishSync (waiting SyncFinished)...")
    let finishStart = Date()
    session.finish()
    log("  finishSync returned in \(String(format: "%.2f", Date().timeIntervalSince(finishStart)))s")

    let finalRows = pullAndQuery(probeAFC: probeAFC, names: [basename1, basename2], log: log)
    log("  rows after finishSync: \(finalRows.sorted().joined(separator: ", "))")

    print("")
    print("=== Streaming Register Smoke Test ===")
    print("After registerFile #1: \(after1.contains(basename1) ? "OK" : "MISS")")
    print("After registerFile #2: file1=\(after2.contains(basename1) ? "YES" : "no")  file2=\(after2.contains(basename2) ? "YES" : "no")")
    print("After finishSync     : file1=\(finalRows.contains(basename1) ? "YES" : "no")  file2=\(finalRows.contains(basename2) ? "YES" : "no")")
    if after2.contains(basename1) && after2.contains(basename2) {
        print(">>> PASS: both rows materialized progressively before finishSync.")
    } else {
        print(">>> FAIL: rows didn't land per-FileComplete on the streaming path.")
    }
}

public func gateTestInterleave(
    file1: URL, file2: URL, sleepSeconds: TimeInterval = 60,
    log: @escaping (String) -> Void = { print($0) }
) async throws -> GateTestReport {
    let device = try discoverDevice()
    log("Device: \(device.displayName) (\(device.udid.prefix(16))...)")

    // Build minimal SyncItems (movies, no artwork — we only need rows in
    // item_extra to look up by location). Probe gives us duration.
    let info1: MediaInfo
    let info2: MediaInfo
    do {
        info1 = try await probeFile(url: file1)
        info2 = try await probeFile(url: file2)
    } catch {
        throw GateTestError.probeFailed(error.localizedDescription)
    }

    let item1 = makeSyncItem(url: file1, duration: info1.duration)
    let item2 = makeSyncItem(url: file2, duration: info2.duration)
    let prepared = prepareSyncFiles([item1, item2])
    let p1 = prepared[0], p2 = prepared[1]
    let basename1 = (p1.devicePath as NSString).lastPathComponent
    let basename2 = (p2.devicePath as NSString).lastPathComponent
    log("Asset paths:")
    log("  #1 \(p1.devicePath) (asset=\(p1.assetID))")
    log("  #2 \(p2.devicePath) (asset=\(p2.assetID))")

    // Upload both files first (matches production sync).
    log("Uploading both files via AFC...")
    let uploader = try AFCUploader(device: device)
    try uploader.upload(p1)
    try uploader.upload(p2)
    uploader.close()
    log("  upload OK")

    // Register, but with a probe between FileComplete #1 and #2.
    let session = ATCSession(device: device, verbose: false)
    let (grappa, anchorStr) = try session.handshake()
    let newAnchor = String(Int(anchorStr)! + 1)
    let plistData = session.buildSyncPlist(files: [p1.asSyncFileInfo, p2.asSyncFileInfo], anchor: Int(newAnchor)!)
    let cigData = try session.computeCIG(deviceGrappa: grappa, plistData: plistData)
    let registerAFC = try AFCClient(device: device)

    var rowsAtT0 = Set<String>()
    var rowsAtT60 = Set<String>()
    let probeAFC: AFCClient
    do {
        probeAFC = try AFCClient(device: device)
    } catch {
        throw GateTestError.afcOpenFailed(error.localizedDescription)
    }

    let registerStart = Date()
    try session.register(
        afc: registerAFC,
        files: [p1.asSyncFileInfo, p2.asSyncFileInfo],
        plistData: plistData,
        cigData: cigData,
        anchor: newAnchor
    ) { idx, _ in
        guard idx == 0 else { return }
        // T+0 probe: pull DB right after FileComplete #1 was queued.
        log("\n--- probe T+0s (right after FileComplete #1) ---")
        let t0 = pullAndQuery(probeAFC: probeAFC, names: [basename1, basename2], log: log)
        rowsAtT0 = t0
        log("  rows seen: \(t0.isEmpty ? "<none>" : t0.sorted().joined(separator: ", "))")

        // Ping-aware sleep, then second probe.
        log("\n--- sleeping \(Int(sleepSeconds)) s (Ping-aware) ---")
        session.pingAwareSleep(seconds: sleepSeconds)

        log("\n--- probe T+\(Int(sleepSeconds))s (still pre-FileComplete #2) ---")
        let t60 = pullAndQuery(probeAFC: probeAFC, names: [basename1, basename2], log: log)
        rowsAtT60 = t60
        log("  rows seen: \(t60.isEmpty ? "<none>" : t60.sorted().joined(separator: ", "))")
    }
    let registerSeconds = Date().timeIntervalSince(registerStart)
    registerAFC.close()
    session.close()

    // Final probe after register returns — confirms both rows landed
    // (sanity check that the test sync itself succeeded).
    log("\n--- probe AFTER register() returned ---")
    let after = pullAndQuery(probeAFC: probeAFC, names: [basename1, basename2], log: log)
    log("  rows seen: \(after.isEmpty ? "<none>" : after.sorted().joined(separator: ", "))")
    probeAFC.close()

    return GateTestReport(
        file1Name: basename1,
        file2Name: basename2,
        rowsAtT0: rowsAtT0,
        rowsAtT60: rowsAtT60,
        rowsAfterRegister: after,
        registerSeconds: registerSeconds,
        sleepSeconds: sleepSeconds
    )
}

// MARK: - Helpers

private func makeSyncItem(url: URL, duration: TimeInterval) -> SyncItem {
    let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
    let size = (attrs?[.size] as? Int) ?? 0
    let title = url.deletingPathExtension().lastPathComponent
    return SyncItem(
        fileURL: url,
        title: title,
        sortName: title,
        durationMs: Int(duration * 1000),
        fileSize: size,
        isMovie: true,
        isTVShow: false
    )
}

/// Pull the live MediaLibrary.sqlitedb (+ -wal/-shm) off the device into a
/// fresh tempdir, then ask sqlite3 which of `names` appear in
/// item_extra.location. Returns the matched basenames.
///
/// Pulling all three files matters: medialibraryd is in WAL mode and the
/// most recent commits live in the -wal until checkpoint. SQLite needs all
/// three present to read a consistent view.
private func pullAndQuery(
    probeAFC: AFCClient, names: [String], log: (String) -> Void
) -> Set<String> {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("mp-gate-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }

    let pullStart = Date()
    for f in [dbFile, dbWal, dbShm] {
        let remote = "\(dbDir)/\(f)"
        do {
            let data = try probeAFC.readFile(remote)
            try data.write(to: tmp.appendingPathComponent(f))
        } catch {
            // -wal / -shm can legitimately be missing if SQLite just
            // checkpointed. -sqlitedb missing is fatal.
            if f == dbFile {
                log("  ! pull \(f) failed: \(error.localizedDescription)")
                return []
            }
        }
    }
    log("  pulled DB in \(String(format: "%.2f", Date().timeIntervalSince(pullStart)))s")

    let dbPath = tmp.appendingPathComponent(dbFile).path
    var found = Set<String>()
    for name in names {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        proc.arguments = [
            "-readonly", dbPath,
            "SELECT location FROM item_extra WHERE location = '\(name)';"
        ]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            log("  ! sqlite3 launch failed: \(error.localizedDescription)")
            continue
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let s = String(data: data, encoding: .utf8) ?? ""
        if s.trimmingCharacters(in: .whitespacesAndNewlines) == name {
            found.insert(name)
        }
    }
    return found
}
