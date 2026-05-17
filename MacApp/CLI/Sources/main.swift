// mediaporterctl — headless CLI driver for MediaPorterCore.
// Purpose: validate the core pipeline end-to-end without a UI.
// Commands:
//   devices                 — list connected iOS devices
//   analyze <file>          — probe a file and print the transcode plan
//   sync <file> [file...]   — full pipeline (transcode + upload + register)
//                             to the connected device using defaults.
//                             Movies + plain TV episodes work without
//                             interactive input; TMDb enrichment is skipped
//                             (no API key in CLI), filename-derived metadata
//                             is used.
//   bench-upload <file>     — measure AFC throughput at several chunk sizes
//   recover / pull / ls / stat / gate-test / streaming-test — see -h
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
      sync <file> [file...]   full pipeline (transcode + upload + register)
                              for the given files. Uses defaults — no TMDb
                              enrichment (no API key in CLI), no cluster-
                              extras (sidecar dubs/subs), no interactive
                              show-picker. Suitable for movies and simple
                              TV files.
      delete <title> [--yes]  list device items whose title matches
                              (case-insensitive substring) and remove
                              them via ATC delete_track + AFC.remove of
                              the underlying MP4 and Airlock artwork.
                              Without --yes it lists candidates only.
      smoke-test [--fixture path] [--keep]
                              release-readiness check: sync a small fixture
                              (default: Mediaporter.Alpha.S01E01.mp4), then
                              verify the row landed bound, the MP4 is on
                              device, then delete and verify cleanup.
                              Exit 0 PASS, exit 1 FAIL. --keep skips the
                              delete phase so you can inspect the device.
      bench-upload <file> [--chunks 1M,4M,16M] [--passes N]
                              measure AFC throughput at several chunk sizes
                              (default 256K, 1M, 4M, 16M; --chunks accepts
                              a comma-separated list with K/M suffixes,
                              e.g. 1M,4M,8M,16M,32M) and print the best
                              fit. Each pass removes its own upload so
                              the device isn't left with stale assets.
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
    guard argv.count >= 3 else { usage() }
    runSync(paths: Array(argv[2...]))
case "delete":
    guard argv.count >= 3 else { usage() }
    let confirm = argv.contains("--yes")
    let pattern = argv[2]
    runDelete(titleLike: pattern, confirm: confirm)
case "smoke-test":
    var fixturePath: String? = nil
    var keep = false
    var i = 2
    while i < argv.count {
        if argv[i] == "--fixture", i + 1 < argv.count {
            fixturePath = argv[i + 1]; i += 2
        } else if argv[i] == "--keep" {
            keep = true; i += 1
        } else {
            i += 1
        }
    }
    runSmokeTest(fixturePath: fixturePath, keep: keep)
case "bench-upload":
    guard argv.count >= 3 else { usage() }
    var benchChunks: [Int]? = nil
    var benchPasses = 2
    if let i = argv.firstIndex(of: "--chunks"), i + 1 < argv.count {
        benchChunks = parseChunkList(argv[i + 1])
    }
    if let i = argv.firstIndex(of: "--passes"), i + 1 < argv.count, let v = Int(argv[i + 1]) {
        benchPasses = max(1, v)
    }
    runBenchUpload(path: argv[2], chunkSizes: benchChunks, passes: benchPasses)
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

// MARK: - sync (full pipeline, headless)

/// Drives `PipelineController.runFullPipeline()` for one or more local
/// video files. No interactive TMDb picker — tmdbAPIKey stays empty so
/// metadata falls back to filename. AFC + ATC + transcode (when needed)
/// run end-to-end against the connected device. Exit code 1 on any job
/// failing or no device.
///
/// Uses `dispatchMain()` instead of a semaphore: PipelineController is
/// `@MainActor`-isolated, so any property access or method call from
/// another actor hops to the main queue. A semaphore on the main thread
/// blocks the main queue and the hop never completes — the process
/// hangs forever waiting on a Task that can't be scheduled. With
/// `dispatchMain()`, main is given over to the dispatch runtime and
/// MainActor work flows; we terminate via `exit()` from the task.
func runSync(paths: [String]) -> Never {
    let urls = paths.map { URL(fileURLWithPath: $0) }
    for u in urls where !FileManager.default.fileExists(atPath: u.path) {
        FileHandle.standardError.write(Data("not found: \(u.path)\n".utf8))
        exit(1)
    }
    Task { @MainActor in
        var exitCode: Int32 = 0
        defer { exit(exitCode) }
        let pc = PipelineController()

        // Set deviceInfo directly — DeviceMonitor's 2 s polling loop would
        // also work but adds startup latency we don't need for a one-shot
        // CLI invocation.
        do {
            pc.deviceInfo = try discoverDevice()
        } catch {
            FileHandle.standardError.write(Data("no device: \(error.localizedDescription)\n".utf8))
            exitCode = 1
            return
        }
        print("Device: \(pc.deviceInfo!.displayName)")

        // Append jobs directly — skip addFiles()'s auto-kickoff of
        // analyzeAll() so we don't race with our own awaited call.
        for u in urls { pc.jobs.append(FileJob(url: u)) }

        // Live progress printer. Single-line in-place updates via "\r" so
        // we don't flood the terminal during long uploads. Polls every
        // 250 ms; finalizes with a newline on exit.
        let printer = Task { @MainActor in
            var lastLine = ""
            while !Task.isCancelled {
                let line: String = {
                    if pc.overallProgress > 0 {
                        let pct = Int(pc.overallProgress * 100)
                        let bar = makeBar(pc.overallProgress, width: 24)
                        return "\(bar) \(pct)%  \(pc.overallStatus)"
                    } else {
                        return pc.overallStatus
                    }
                }()
                if line != lastLine {
                    FileHandle.standardError.write(Data("\r\u{1b}[2K\(line)".utf8))
                    lastLine = line
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }

        await pc.runFullPipeline()

        printer.cancel()
        FileHandle.standardError.write(Data("\r\u{1b}[2K".utf8)) // clear status line

        print("")
        print("Result:")
        var allOK = true
        for job in pc.jobs {
            let mark: String
            switch job.status {
            case .synced: mark = "OK"
            default:
                mark = "FAIL [\(job.status.rawValue)]"
                allOK = false
            }
            print("  \(mark)  \(job.fileName)")
            if let err = job.error { print("        \(err)") }
        }
        if !allOK { exitCode = 1 }
        if let stats = pc.lastRunStats {
            print("")
            print(String(format: "Run: %.1fs total (%.1fs transcode, %.1fs upload)",
                stats.totalWallSeconds, stats.totalTranscodeSeconds, stats.totalUploadSeconds))
            if let avg = stats.avgUploadMBps {
                print(String(format: "Avg upload: %.1f MB/s", avg))
            }
        }
    }
    dispatchMain()
}

private func makeBar(_ frac: Double, width: Int) -> String {
    let clamped = max(0, min(1, frac))
    let fill = Int(Double(width) * clamped)
    return "[" + String(repeating: "#", count: fill)
              + String(repeating: "-", count: max(0, width - fill)) + "]"
}

// MARK: - delete (ATC delete_track + AFC remove)

/// List items on the device whose title contains `titleLike` (case-
/// insensitive substring). With `confirm=false` we just print the
/// candidates and exit — operator inspects then re-runs with `--yes`.
/// With `confirm=true` we issue a single delete-only ATC session
/// covering every match and AFC.remove each media file + artwork blob.
func runDelete(titleLike: String, confirm: Bool) {
    let device: DeviceInfo
    do { device = try discoverDevice() }
    catch {
        FileHandle.standardError.write(Data("no device: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
    print("Device: \(device.displayName)")

    let candidates: [DeleteCandidate]
    do {
        candidates = try findDeleteCandidates(titleLike: titleLike, device: device)
    } catch {
        FileHandle.standardError.write(Data("query failed: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
    if candidates.isEmpty {
        print("No items match \"\(titleLike)\".")
        exit(0)
    }
    print("Found \(candidates.count) match(es):")
    for c in candidates {
        // media_kind on device: 2 = movie, 32/64 = TV episode (kind 64 is
        // the modern value used on iOS 17+ — observed live on akm16pro
        // 2026-05-17 for both Odd Taxi episodes and the Alpha test fixture).
        let kindTag: String
        switch c.mediaKind {
        case 2: kindTag = "Movie"
        case 32, 64: kindTag = "TV"
        default: kindTag = "k=\(c.mediaKind)"
        }
        let path = c.mediaPath ?? "(unbound)"
        let syncTag = c.syncID == 0 ? "sync_id=0 — UNDELETABLE" : "sync_id=\(c.syncID)"
        print("  • [\(kindTag)] \"\(c.title)\"  \(syncTag)  \(path)")
    }
    let deletable = candidates.filter { $0.syncID != 0 }
    if deletable.isEmpty {
        print("\nEvery match has sync_id=0 (likely inserted by a non-ATC path or pre-")
        print("upgrade row). medialibraryd resolves delete_track by sync_id, so we")
        print("have no handle to remove these via ATC. Aborting.")
        exit(1)
    }
    if !confirm {
        print("\nDry run. Add --yes to delete the \(deletable.count) deletable row(s).")
        exit(0)
    }

    print("\nDeleting…")
    let syncIDs = deletable.map { Int($0.syncID) }
    let mediaPaths = deletable.compactMap { $0.mediaPath }
    let artworkSyncIDs = deletable.map { Int($0.syncID) }
    do {
        let result = try deleteFromDevice(
            syncIDs: syncIDs,
            mediaPaths: mediaPaths,
            artworkSyncIDs: artworkSyncIDs,
            verbose: false
        )
        print("Submitted \(result.syncIDsSubmitted) delete_track op(s)")
        // medialibraryd usually cleans the bound MP4 and Airlock artwork
        // itself as soon as the delete_track commits — when that happens
        // our AFC.remove finds the path already gone (rc != 0) and the
        // counts read 0. That's success, not failure; the post-delete
        // stat / DB re-query is the real verification.
        print("AFC cleanup: \(result.mediaFilesRemoved) media file(s) and \(result.artworkBlobsRemoved) artwork blob(s)")
        if result.mediaFilesRemoved == 0 && !mediaPaths.isEmpty {
            print("  (zero is normal — medialibraryd typically deletes the")
            print("   bound file itself when delete_track commits)")
        }
    } catch {
        FileHandle.standardError.write(Data("delete failed: \(error.localizedDescription)\n".utf8))
        exit(1)
    }

    // Verify by re-querying. If any row survived (medialibraryd didn't
    // commit the delete), report it.
    do {
        let after = try findDeleteCandidates(titleLike: titleLike, device: device)
        let stillPresent = after.filter { c in deletable.contains(where: { $0.syncID == c.syncID }) }
        if stillPresent.isEmpty {
            print("Verified: 0 row(s) remain in MediaLibrary.sqlitedb.")
        } else {
            print("Warning: \(stillPresent.count) row(s) still present after delete:")
            for c in stillPresent { print("  • \(c.title) (sync_id=\(c.syncID))") }
        }
    } catch {
        FileHandle.standardError.write(Data("verify query failed: \(error.localizedDescription) (non-fatal)\n".utf8))
    }
}

// MARK: - bench-upload (chunk-size benchmark, punch-list #3)

func parseChunkList(_ s: String) -> [Int] {
    s.split(separator: ",").compactMap { tok -> Int? in
        let t = tok.trimmingCharacters(in: .whitespaces).uppercased()
        guard let last = t.last else { return nil }
        let body = String(t.dropLast())
        if last == "K", let n = Int(body) { return n * 1024 }
        if last == "M", let n = Int(body) { return n * 1024 * 1024 }
        return Int(t) // raw bytes
    }
}

func runBenchUpload(path: String, chunkSizes: [Int]?, passes: Int) {
    let url = URL(fileURLWithPath: path)
    guard FileManager.default.fileExists(atPath: url.path) else {
        FileHandle.standardError.write(Data("not found: \(path)\n".utf8))
        exit(1)
    }
    let chunks = chunkSizes ?? [256 * 1024, 1024 * 1024, 4 * 1024 * 1024, 16 * 1024 * 1024]
    let sema = DispatchSemaphore(value: 0)
    var thrown: Error?
    var report: BenchUploadReport?
    Task {
        do {
            report = try await benchUploadChunkSizes(
                fileURL: url, chunkSizes: chunks, passes: passes
            ) { line in print(line) }
        } catch {
            thrown = error
        }
        sema.signal()
    }
    sema.wait()

    if let e = thrown {
        FileHandle.standardError.write(Data("bench-upload failed: \(e.localizedDescription)\n".utf8))
        exit(1)
    }
    guard let r = report else { return }

    print("")
    print("=== AFC chunk-size benchmark ===")
    print(String(format: "File: %@ (%.1f MB)",
        r.fileURL.lastPathComponent, Double(r.fileBytes) / 1_048_576))
    print(String(format: "Warmup: %.2fs", r.warmupSeconds))
    if let note = r.note { print("Note: \(note)") }
    print("")
    print("  chunk    median   MB/s")
    for res in r.results {
        let chunkLabel = res.chunkSizeBytes >= 1024 * 1024
            ? "\(res.chunkSizeBytes / (1024 * 1024)) MB"
            : "\(res.chunkSizeBytes / 1024) KB"
        // `%s` in Swift String(format:) expects a C-string pointer — passing
        // a Swift String segfaults inside _platform_strlen. Use interpolation
        // for the label and only format the numerics.
        let padded = chunkLabel.padding(toLength: 7, withPad: " ", startingAt: 0)
        print("  \(padded) \(String(format: "%5.2fs  %6.1f", res.medianSeconds, res.medianMBps))")
    }
    if let best = r.best {
        let label = best.chunkSizeBytes >= 1024 * 1024
            ? "\(best.chunkSizeBytes / (1024 * 1024)) MB"
            : "\(best.chunkSizeBytes / 1024) KB"
        print("")
        print(">>> Winner: \(label) at \(String(format: "%.1f", best.medianMBps)) MB/s")
    }
}

// MARK: - smoke-test (release-readiness end-to-end check)

/// Sync a small fixture, verify the row landed bound, then delete and
/// verify cleanup. One process, one exit code — fits CI/release-tag
/// gating. Uses the same paths as production (PipelineController for
/// sync, deleteFromDevice for cleanup) so any regression in either
/// shows up here before we cut a build.
func runSmokeTest(fixturePath: String?, keep: Bool) -> Never {
    let defaultFixture = "/Users/faeton/Sites/mediaporter/test_fixtures/mediaporter-test-shows/Mediaporter.Alpha.S01E01.mp4"
    let url = URL(fileURLWithPath: fixturePath ?? defaultFixture)
    guard FileManager.default.fileExists(atPath: url.path) else {
        FileHandle.standardError.write(Data(
            "fixture not found: \(url.path)\n".utf8))
        exit(1)
    }

    Task { @MainActor in
        var exitCode: Int32 = 0
        var failures: [String] = []
        defer {
            print("")
            if failures.isEmpty {
                print("✓ SMOKE TEST PASSED")
            } else {
                print("✗ SMOKE TEST FAILED:")
                for f in failures { print("  - \(f)") }
                exitCode = 1
            }
            exit(exitCode)
        }

        // Device.
        let device: DeviceInfo
        do { device = try discoverDevice() } catch {
            failures.append("no device: \(error.localizedDescription)")
            return
        }
        print("Device: \(device.displayName)")
        print("Fixture: \(url.lastPathComponent)")

        // === PHASE 1: SYNC ===
        print("")
        print("[1/3] sync")
        let pc = PipelineController()
        pc.deviceInfo = device
        pc.jobs.append(FileJob(url: url))

        let printer = Task { @MainActor in
            var last = ""
            while !Task.isCancelled {
                let line: String
                if pc.overallProgress > 0 {
                    let pct = Int(pc.overallProgress * 100)
                    line = "\(makeBar(pc.overallProgress, width: 24)) \(pct)%  \(pc.overallStatus)"
                } else {
                    line = pc.overallStatus
                }
                if line != last {
                    FileHandle.standardError.write(Data("\r\u{1b}[2K\(line)".utf8))
                    last = line
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        await pc.runFullPipeline()
        printer.cancel()
        FileHandle.standardError.write(Data("\r\u{1b}[2K".utf8))

        guard let job = pc.jobs.first else {
            failures.append("PipelineController dropped the job")
            return
        }
        guard job.status == .synced else {
            failures.append("sync failed: status=\(job.status.rawValue) error=\(job.error ?? "(none)")")
            return
        }
        let syncedTitle = job.metadata?.title ?? job.fileName
        print("  synced: title=\"\(syncedTitle)\"")

        // === PHASE 2: VERIFY ON DEVICE ===
        print("")
        print("[2/3] verify on device")
        // We synced a fixture named "Mediaporter.*" — the parser uses
        // "Mediaporter" or "Mediaporter Alpha" as the show, and the title
        // ends up something like "Mediaporter Alpha — S01E01". A LIKE on
        // "Mediaporter" is wide enough to catch all the fixture variants
        // and narrow enough to never hit user content.
        let searchKey = "Mediaporter"
        let candidates: [DeleteCandidate]
        do {
            candidates = try findDeleteCandidates(titleLike: searchKey, device: device)
        } catch {
            failures.append("DB query failed: \(error.localizedDescription)")
            return
        }
        // Filter to the row we just synced. We require an explicit match
        // — no `?? candidates.first` fallback — otherwise a phantom row
        // from a previous abandoned smoke run could mask a true failure
        // where our row never actually landed (codex review 2026-05-18).
        //
        // Match semantics: for TV `job.metadata?.title` returns showName
        // ("Mediaporter Alpha") while the DB title is the episode label
        // ("Mediaporter Alpha — S01E01") — the show name is a substring,
        // so contains() catches it. For movies showName isn't applicable
        // and metadata.title == DB title exactly. We also check the
        // filename stem as a third anchor (covers off-format DB titles).
        let stem = url.deletingPathExtension().lastPathComponent
        let ours = candidates.filter { c in
            c.title == syncedTitle
                || c.title.contains(syncedTitle)
                || c.title.contains(stem)
        }
        guard let cand = ours.first else {
            let titles = candidates.map { "\"\($0.title)\"" }.joined(separator: ", ")
            failures.append(
                "row not found: searched LIKE '%\(searchKey)%' and got \(candidates.count) match(es) [\(titles)] but none matched syncedTitle=\"\(syncedTitle)\" or stem=\"\(stem)\"")
            return
        }
        guard cand.syncID != 0 else {
            failures.append("row has sync_id=0 — un-deletable, sync went through a non-ATC path")
            return
        }
        guard let path = cand.mediaPath else {
            failures.append("row unbound (no base_location_id) — file would be swept by GC")
            return
        }
        let onDeviceSize: Int64?
        do { onDeviceSize = try statDeviceFile(path, device: device) }
        catch {
            failures.append("stat \(path): \(error.localizedDescription)")
            return
        }
        guard let size = onDeviceSize else {
            failures.append("MP4 missing on device: \(path)")
            return
        }
        // Default fixture is a TV episode — kind 32 or 64 (per
        // DeviceLibraryQuery + delete-command comment, 64 is the modern
        // iOS 17+ value, 32 the legacy). A custom --fixture pointing at
        // a movie would land kind 2; that's also fine. Reject only the
        // "unknown" sentinel 0 and surface unexpected values explicitly.
        let isDefaultFixture = (fixturePath == nil)
        if isDefaultFixture {
            guard cand.mediaKind == 32 || cand.mediaKind == 64 else {
                failures.append(
                    "TV fixture got unexpected media_kind=\(cand.mediaKind) — expected 32 or 64 (TV episode). Was the TV-vs-movie classifier broken upstream?")
                return
            }
        } else {
            guard cand.mediaKind != 0 else {
                failures.append("custom fixture got media_kind=0 (unknown)")
                return
            }
        }
        print("  row: sync_id=\(cand.syncID) kind=\(cand.mediaKind) bound to \(path)")
        print("  file: \(size) bytes on device")

        if keep {
            print("")
            print("--keep specified, skipping cleanup. Row left on device.")
            return
        }

        // === PHASE 3: DELETE + VERIFY ===
        print("")
        print("[3/3] cleanup")
        let result: DeleteResult
        do {
            result = try deleteFromDevice(
                syncIDs: [Int(cand.syncID)],
                mediaPaths: [path],
                artworkSyncIDs: [Int(cand.syncID)],
                verbose: false
            )
        } catch {
            failures.append("delete failed: \(error.localizedDescription)")
            return
        }
        print("  submitted \(result.syncIDsSubmitted) delete_track op(s)")
        let after: [DeleteCandidate]
        do { after = try findDeleteCandidates(titleLike: searchKey, device: device) }
        catch {
            failures.append("post-delete query failed: \(error.localizedDescription)")
            return
        }
        let stillThere = after.first(where: { $0.syncID == cand.syncID })
        if stillThere != nil {
            failures.append("row sync_id=\(cand.syncID) still present after delete")
        }
        do {
            if try statDeviceFile(path, device: device) != nil {
                failures.append("MP4 \(path) still present after delete")
            }
        } catch {
            // stat failure isn't itself a smoke failure — could be
            // permission glitch on a deleted parent. Note it but don't
            // fail.
            print("  warn: post-delete stat \(path): \(error.localizedDescription)")
        }
        if stillThere == nil {
            print("  row gone, file gone")
        }
    }
    dispatchMain()
}
