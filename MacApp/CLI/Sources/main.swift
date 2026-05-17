// mediaporterctl — headless CLI driver for MediaPorterCore.
// Purpose: validate the core pipeline end-to-end without a UI.
// Commands:
//   devices                 — list connected iOS devices
//   analyze <file>          — probe a file and print the transcode plan
//   sync <file> [file...]   — (todo) full pipeline to connected device
//
// Deliberately minimal. UI rework will come later on top of the same core.

import Foundation
import MediaPorterCore

let argv = CommandLine.arguments
let prog = (argv.first as NSString?)?.lastPathComponent ?? "mediaporterctl"

func usage() -> Never {
    let out = """
    usage: \(prog) <command> [args]

    commands:
      devices                 list connected iOS devices
      analyze <file>          probe a file and print the transcode plan
      sync <file> [file...]   (not implemented yet)
      recover                 register orphaned uploads on the device using
                              tagged .m4v files left in the system tempdir
      pull <remote> [local]   copy a file off the device via AFC. Default
                              local path is the basename of the remote.
                              Useful for inspecting MediaLibrary.sqlitedb,
                              ArtworkDB, etc. without third-party tools.
                              When the remote ends in .sqlitedb, auto-pulls
                              -wal and -shm sidecars too so the local
                              snapshot includes uncommitted WAL writes
                              (missing sidecars are not fatal).
      gate-test <f1> <f2> [--sleep SECS]
                              plan #8 gating: upload two files, send
                              FileComplete #1, pull MediaLibrary.sqlitedb
                              and check whether the row appeared at T+0
                              and T+SECS (default 60). Prints verdict on
                              whether interleaving register with upload
                              would buy anything.
    """
    FileHandle.standardError.write(Data((out + "\n").utf8))
    exit(2)
}

guard argv.count >= 2 else { usage() }

switch argv[1] {
case "devices":
    runDevices()
case "analyze":
    guard argv.count >= 3 else { usage() }
    runAnalyze(path: argv[2])
case "sync":
    FileHandle.standardError.write(Data("sync: not implemented yet\n".utf8))
    exit(2)
case "recover":
    runRecover()
case "pull":
    guard argv.count >= 3 else { usage() }
    let local = argv.count >= 4 ? argv[3] : (argv[2] as NSString).lastPathComponent
    runPull(remote: argv[2], local: local)
case "ls":
    guard argv.count >= 3 else { usage() }
    runLs(remote: argv[2])
case "stat":
    guard argv.count >= 3 else { usage() }
    runStat(remote: argv[2])
case "gate-test":
    guard argv.count >= 4 else { usage() }
    var sleepSec: Double = 60
    if let i = argv.firstIndex(of: "--sleep"), i + 1 < argv.count, let v = Double(argv[i + 1]) {
        sleepSec = v
    }
    runGateTest(f1: argv[2], f2: argv[3], sleepSec: sleepSec)
case "streaming-test":
    guard argv.count >= 4 else { usage() }
    runStreamingTest(f1: argv[2], f2: argv[3])
case "-h", "--help", "help":
    usage()
default:
    FileHandle.standardError.write(Data("unknown command: \(argv[1])\n".utf8))
    usage()
}

// MARK: - devices

func runDevices() {
    do {
        let device = try discoverDevice()
        print("UDID:           \(device.udid)")
        print("Name:           \(device.deviceName)")
        print("Model:          \(device.displayName)")
        print("Class:          \(device.deviceClass)")
        print("Screen:         \(device.screenDescription)")
        print("Suggested:      \(device.suggestedResolution.rawValue)")
    } catch {
        FileHandle.standardError.write(Data("no device: \(error)\n".utf8))
        exit(1)
    }
}

// MARK: - analyze

func runAnalyze(path: String) {
    let url = URL(fileURLWithPath: path)
    guard FileManager.default.fileExists(atPath: url.path) else {
        FileHandle.standardError.write(Data("not found: \(path)\n".utf8))
        exit(1)
    }

    let sema = DispatchSemaphore(value: 0)
    var result: Result<MediaInfo, Error>!
    Task {
        do {
            result = .success(try await probeFile(url: url))
        } catch {
            result = .failure(error)
        }
        sema.signal()
    }
    sema.wait()

    let info: MediaInfo
    switch result! {
    case .success(let v): info = v
    case .failure(let e):
        FileHandle.standardError.write(Data("probe failed: \(e)\n".utf8))
        exit(1)
    }

    print("File:     \(url.lastPathComponent)")
    print("Format:   \(info.formatName)")
    print("Duration: \(String(format: "%.1fs", info.duration))")

    for v in info.videoStreams {
        let dim = "\(v.width ?? 0)x\(v.height ?? 0)"
        print("  video  #\(v.index)  \(v.codecName)  \(dim)")
    }
    for a in info.audioStreams {
        let lang = a.language ?? "und"
        let ch = a.channels ?? 0
        print("  audio  #\(a.index)  \(a.codecName)  \(ch)ch  [\(lang)]")
    }
    for s in info.subtitleStreams {
        let lang = s.language ?? "und"
        print("  sub    #\(s.index)  \(s.codecName)  [\(lang)]")
    }

    let decision = evaluateCompatibility(mediaInfo: info)
    print("")
    print("Plan:")
    print("  needs_transcode: \(decision.needsTranscode)")
    print("  needs_remux:     \(decision.needsRemux)")
    for (idx, action) in decision.streamActions.sorted(by: { $0.key < $1.key }) {
        print("  stream #\(idx): \(action)")
    }

    let audioActions = classifyAllAudio(info.audioStreams)
    if !audioActions.isEmpty {
        print("")
        print("Audio classification:")
        for a in audioActions {
            var line = "  #\(a.stream.index)  \(a.stream.codecName) → \(a.action)"
            if let tc = a.targetCodec { line += " (\(tc)" }
            if let ch = a.targetChannels { line += " \(ch)ch" }
            if let br = a.targetBitrate { line += " @\(br)" }
            if a.targetCodec != nil { line += ")" }
            print(line)
        }
    }
}

// MARK: - pull

func runPull(remote: String, local: String) {
    let device: DeviceInfo
    do {
        device = try discoverDevice()
    } catch {
        FileHandle.standardError.write(Data("no device: \(error)\n".utf8))
        exit(1)
    }
    let url = URL(fileURLWithPath: local)
    do {
        try pullDeviceFile(remote: remote, to: url, device: device)
    } catch {
        FileHandle.standardError.write(Data("pull failed: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
    let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    print("\(remote) -> \(url.path) (\(size) bytes)")

    // SQLite WAL safety net. iOS keeps MediaLibrary.sqlitedb in WAL
    // journal_mode — the main file is the durable snapshot, the latest
    // writes (often the just-bound base_location_id / location /
    // file_size we want to inspect) live in -wal until checkpoint.
    // Reading the main file alone gives a stale view and has fooled
    // me into diagnosing a binding regression that didn't exist.
    // Auto-pull -wal and -shm alongside whenever the remote ends in
    // .sqlitedb so the sibling files sit next to the pulled main and
    // sqlite3 picks them up. Missing siblings are NOT fatal — a fully
    // checkpointed DB has empty/absent -wal, that's normal.
    if remote.hasSuffix(".sqlitedb") {
        for suffix in ["-wal", "-shm"] {
            let sidecarRemote = remote + suffix
            let sidecarLocal = url.deletingLastPathComponent()
                .appendingPathComponent(url.lastPathComponent + suffix)
            do {
                try pullDeviceFile(remote: sidecarRemote, to: sidecarLocal, device: device)
                let sz = (try? FileManager.default.attributesOfItem(
                    atPath: sidecarLocal.path)[.size] as? Int) ?? 0
                print("\(sidecarRemote) -> \(sidecarLocal.path) (\(sz) bytes)")
            } catch {
                // Sibling missing is expected for a checkpointed DB.
                // Log to stderr so triage knows we tried but don't exit.
                FileHandle.standardError.write(Data(
                    "\(sidecarRemote): \(error.localizedDescription) (non-fatal)\n".utf8))
            }
        }
    }
}

// MARK: - ls / stat

func runLs(remote: String) {
    let device: DeviceInfo
    do { device = try discoverDevice() }
    catch {
        FileHandle.standardError.write(Data("no device: \(error)\n".utf8))
        exit(1)
    }
    do {
        let entries = try listDeviceDirectory(remote, device: device)
        if entries.isEmpty {
            print("(empty or missing: \(remote))")
        } else {
            for e in entries.sorted() { print(e) }
        }
    } catch {
        FileHandle.standardError.write(Data("ls failed: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
}

func runStat(remote: String) {
    let device: DeviceInfo
    do { device = try discoverDevice() }
    catch {
        FileHandle.standardError.write(Data("no device: \(error)\n".utf8))
        exit(1)
    }
    do {
        if let sz = try statDeviceFile(remote, device: device) {
            print("\(remote): \(sz) bytes")
        } else {
            print("\(remote): MISSING")
            exit(2)
        }
    } catch {
        FileHandle.standardError.write(Data("stat failed: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
}

// MARK: - streaming-test (plan #8 validation)

func runStreamingTest(f1: String, f2: String) {
    let u1 = URL(fileURLWithPath: f1)
    let u2 = URL(fileURLWithPath: f2)
    for u in [u1, u2] {
        guard FileManager.default.fileExists(atPath: u.path) else {
            FileHandle.standardError.write(Data("not found: \(u.path)\n".utf8))
            exit(1)
        }
    }
    let sema = DispatchSemaphore(value: 0)
    var thrown: Error?
    Task {
        do {
            try await streamingRegisterSmokeTest(file1: u1, file2: u2)
        } catch {
            thrown = error
        }
        sema.signal()
    }
    sema.wait()
    if let e = thrown {
        FileHandle.standardError.write(Data("streaming-test failed: \(e.localizedDescription)\n".utf8))
        exit(1)
    }
}

// MARK: - gate-test (plan #8)

func runGateTest(f1: String, f2: String, sleepSec: Double) {
    let u1 = URL(fileURLWithPath: f1)
    let u2 = URL(fileURLWithPath: f2)
    for u in [u1, u2] {
        guard FileManager.default.fileExists(atPath: u.path) else {
            FileHandle.standardError.write(Data("not found: \(u.path)\n".utf8))
            exit(1)
        }
    }

    let sema = DispatchSemaphore(value: 0)
    var result: Result<GateTestReport, Error>!
    Task {
        do {
            let r = try await gateTestInterleave(
                file1: u1, file2: u2, sleepSeconds: sleepSec
            )
            result = .success(r)
        } catch {
            result = .failure(error)
        }
        sema.signal()
    }
    sema.wait()

    let report: GateTestReport
    switch result! {
    case .success(let r): report = r
    case .failure(let e):
        FileHandle.standardError.write(Data("gate-test failed: \(e.localizedDescription)\n".utf8))
        exit(1)
    }

    print("")
    print("=== Gate Test Verdict ===")
    print("File 1: \(report.file1Name)")
    print("File 2: \(report.file2Name)")
    print("register() wall time: \(String(format: "%.2f", report.registerSeconds)) s")
    print("")
    print("After FileComplete #1, T+0s    : \(format(report.rowsAtT0, [report.file1Name, report.file2Name]))")
    print("After FileComplete #1, T+\(Int(report.sleepSeconds))s   : \(format(report.rowsAtT60, [report.file1Name, report.file2Name]))")
    print("After register() returns        : \(format(report.rowsAfterRegister, [report.file1Name, report.file2Name]))")
    print("")
    if report.rowsAtT0.contains(report.file1Name) || report.rowsAtT60.contains(report.file1Name) {
        print(">>> #8 VIABLE: file 1 row landed before FileComplete #2 / SyncFinished.")
        print("    medialibraryd commits per FileComplete — interleaving will pay off.")
    } else if report.rowsAfterRegister.contains(report.file1Name) {
        print(">>> #8 NOT VIABLE: rows only land after terminal SyncFinished.")
        print("    medialibraryd batches the whole sync — interleaving buys nothing.")
    } else {
        print(">>> INCONCLUSIVE: file 1 row never appeared. Sync may have failed.")
    }
}

private func format(_ found: Set<String>, _ all: [String]) -> String {
    all.map { "\($0)=\(found.contains($0) ? "YES" : "no")" }.joined(separator: "  ")
}

// MARK: - recover

func runRecover() {
    let device: DeviceInfo
    do {
        device = try discoverDevice()
    } catch {
        FileHandle.standardError.write(Data("no device: \(error)\n".utf8))
        exit(1)
    }
    print("Device: \(device.displayName) (\(device.udid.prefix(16))...)")

    let report: OrphanRecoveryReport
    let sema = DispatchSemaphore(value: 0)
    var reportResult: Result<OrphanRecoveryReport, Error>!
    Task {
        do {
            let r = try await recoverOrphansEndToEnd(device: device)
            reportResult = .success(r)
        } catch {
            reportResult = .failure(error)
        }
        sema.signal()
    }
    sema.wait()
    switch reportResult! {
    case .success(let r): report = r
    case .failure(let error):
        FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
        exit(1)
    }

    print("Local /tmp m4v files found:    \(report.localFound)")
    print("Device orphan files found:     \(report.deviceFound)")
    print("Registered (matched by size):  \(report.registered)")
    print("Device files without a match:  \(report.deviceUnmatched)")
    print("Local files without a match:   \(report.candidatesUnmatched)")
    if !report.registeredTitles.isEmpty {
        print("")
        print("Registered:")
        for t in report.registeredTitles {
            print("  - \(t)")
        }
    }
}
