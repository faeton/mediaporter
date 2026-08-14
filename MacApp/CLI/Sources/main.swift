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
      keys                    show which TMDb / OpenSubtitles credentials
                              this binary resolves and from where (presence
                              and provenance only — never the values).
                              Needs no device.
      heal [--dry-run]        inspect and clear assets stuck pending on the
                              device. Lists every asset a prior sync failed
                              to clear with FileError(0), whether its row is
                              bound, and (without --dry-run) delete_tracks
                              the unbound ones. A stuck asset blocks
                              SyncFinished on EVERY later sync, so this is
                              the recovery path when syncs start hanging at
                              "finalizing…".
      verify <syncID> [...]   read back rows by item_store.sync_id and report
                              whether each is bound to a real file. Use the
                              asset IDs from the atc.FileBegin log lines.
      idle-test <file> [--idle 0,60,120]
                              measure the device's asset delivery window:
                              sync one small file per idle value, holding
                              the open session idle that many seconds
                              between AssetManifest and FileBegin, and
                              report whether the row bound. Cleans up
                              after each point.
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

// B2: every subcommand except help touches the private frameworks — fail
// with a clear message instead of the old fatalError when a macOS update
// breaks a private API.
if !["-h", "--help", "help"].contains(argv[1]),
   let fwError = preflightPrivateFrameworks() {
    FileHandle.standardError.write(Data(
        "error: \(fwError.localizedDescription)\nMediaPorter isn't compatible with this version of macOS yet — check porter.md for an update.\n".utf8))
    exit(3)
}

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
case "keys":
    runKeys()
case "heal":
    runHeal(dryRun: argv.contains("--dry-run"))
case "verify":
    guard argv.count >= 3 else { usage() }
    runVerify(syncIDs: argv[2...].compactMap { Int64($0) })
case "idle-test":
    guard argv.count >= 3 else { usage() }
    var idles: [Double] = [0, 60, 120, 180]
    if let i = argv.firstIndex(of: "--idle"), i + 1 < argv.count {
        idles = argv[i + 1].split(separator: ",").compactMap { Double($0) }
    }
    runIdleTest(path: argv[2], idleSecs: idles)
case "-h", "--help", "help":
    usage()
default:
    writeUserStderr("unknown command: \(argv[1])\n")
    usage()
}

// MARK: - devices

func runDevices() {
    // Start the full monitor so we enumerate ALL attached devices (USB + Wi-Fi)
    // and exercise the per-UDID dedup (a device on both transports shows once,
    // preferred USB). Brief wait so USB attaches (instant) and any Wi-Fi
    // announcement land.
    DeviceMonitor.shared.start()
    Thread.sleep(forTimeInterval: 2.0)
    let devices = DeviceMonitor.shared.allDevices

    guard !devices.isEmpty else {
        // Fall back to the one-shot path (covers the just-attached single device
        // that hasn't hit the monitor yet).
        do {
            let device = try discoverDevice()
            printDevice(device, index: nil)
        } catch {
            writeUserStderr("no device: \(error)\n")
            exit(1)
        }
        return
    }

    print("\(devices.count) device\(devices.count == 1 ? "" : "s") attached:\n")
    for (i, d) in devices.enumerated() {
        printDevice(d, index: devices.count > 1 ? i + 1 : nil)
        if i < devices.count - 1 { print("") }
    }
}

private func printDevice(_ device: DeviceInfo, index: Int?) {
    let prefix = index.map { "[\($0)] " } ?? ""
    let transport = device.interface.label.isEmpty ? "unknown" : device.interface.label
    print("\(prefix)UDID:       \(device.udid)")
    print("    Name:       \(device.deviceName)")
    print("    Model:      \(device.displayName)")
    print("    Class:      \(device.deviceClass)")
    print("    Transport:  \(transport)")
    print("    Screen:     \(device.screenDescription)")
    print("    Suggested:  \(device.suggestedResolution.rawValue)")
}

// MARK: - analyze

func runAnalyze(path: String) {
    let url = URL(fileURLWithPath: path)
    guard FileManager.default.fileExists(atPath: url.path) else {
        writeUserStderr("not found: \(path)\n")
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
        writeUserStderr("probe failed: \(e)\n")
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
        writeUserStderr("no device: \(error)\n")
        exit(1)
    }
    let url = URL(fileURLWithPath: local)
    do {
        try pullDeviceFile(remote: remote, to: url, device: device)
    } catch {
        writeUserStderr("pull failed: \(error.localizedDescription)\n")
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
                writeUserStderr("\(sidecarRemote): \(error.localizedDescription) (non-fatal)\n")
            }
        }
    }
}

// MARK: - ls / stat

func runLs(remote: String) {
    let device: DeviceInfo
    do { device = try discoverDevice() }
    catch {
        writeUserStderr("no device: \(error)\n")
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
        writeUserStderr("ls failed: \(error.localizedDescription)\n")
        exit(1)
    }
}

func runStat(remote: String) {
    let device: DeviceInfo
    do { device = try discoverDevice() }
    catch {
        writeUserStderr("no device: \(error)\n")
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
        writeUserStderr("stat failed: \(error.localizedDescription)\n")
        exit(1)
    }
}

// MARK: - streaming-test (plan #8 validation)

func runStreamingTest(f1: String, f2: String) {
    let u1 = URL(fileURLWithPath: f1)
    let u2 = URL(fileURLWithPath: f2)
    for u in [u1, u2] {
        guard FileManager.default.fileExists(atPath: u.path) else {
            writeUserStderr("not found: \(u.path)\n")
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
        writeUserStderr("streaming-test failed: \(e.localizedDescription)\n")
        exit(1)
    }
}

// MARK: - gate-test (plan #8)

func runGateTest(f1: String, f2: String, sleepSec: Double) {
    let u1 = URL(fileURLWithPath: f1)
    let u2 = URL(fileURLWithPath: f2)
    for u in [u1, u2] {
        guard FileManager.default.fileExists(atPath: u.path) else {
            writeUserStderr("not found: \(u.path)\n")
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
        writeUserStderr("gate-test failed: \(e.localizedDescription)\n")
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

// MARK: - idle-test

/// Sweep the AssetManifest → first-FileBegin gap. See `idleWindowTest`.
func runIdleTest(path: String, idleSecs: [Double]) -> Never {
    let url = URL(fileURLWithPath: path)
    guard FileManager.default.fileExists(atPath: url.path) else {
        writeUserStderr("not found: \(url.path)\n")
        exit(1)
    }

    var results: [IdleWindowResult] = []
    for secs in idleSecs {
        print("\n=== idle = \(Int(secs)) s ===")
        let sema = DispatchSemaphore(value: 0)
        var result: Result<IdleWindowResult, Error>!
        Task {
            do { result = .success(try await idleWindowTest(file: url, idleSeconds: secs)) }
            catch { result = .failure(error) }
            sema.signal()
        }
        sema.wait()
        switch result! {
        case .success(let r): results.append(r)
        case .failure(let e):
            writeUserStderr("idle-test (\(Int(secs)) s) failed: \(e.localizedDescription)\n")
        }
    }

    print("")
    print("=== Idle Window Verdict ===")
    for r in results {
        print(String(format: "  idle %4.0f s  ->  %@   finish=%@",
                     r.idleSeconds, r.bound ? "BOUND  " : "UNBOUND", r.finishOutcome))
    }
    let firstFail = results.first { !$0.bound }
    if let f = firstFail {
        print("\n>>> Bind fails from \(Int(f.idleSeconds)) s of post-manifest idle onward.")
        print("    The session must not be opened before the first file can ship.")
    } else if !results.isEmpty {
        print("\n>>> All idles bound. The manifest→FileBegin gap is NOT the variable.")
    }
    exit(results.contains { !$0.bound } ? 1 : 0)
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
        writeUserStderr("no device: \(error)\n")
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
        writeUserStderr("\(error.localizedDescription)\n")
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
/// Report which credentials this binary resolves and from where. Values are
/// never printed — only presence, length and provenance — so the output is
/// safe to paste into a bug report. Needs no device, which makes it the way
/// to check key plumbing when nothing is plugged in.
func runKeys() -> Never {
    func describe(_ name: String, _ value: String?, _ source: Credentials.Source) {
        if let v = value, !v.isEmpty {
            print("  \(name.padding(toLength: 24, withPad: " ", startingAt: 0)) set (\(v.count) chars, \(source.label))")
        } else {
            print("  \(name.padding(toLength: 24, withPad: " ", startingAt: 0)) not set")
        }
    }

    print("Credential resolution for \(Bundle.main.bundleIdentifier ?? "mediaporterctl"):")
    print("")
    describe("TMDb API key", Credentials.tmdbAPIKey(), Credentials.tmdbSource())
    describe("OpenSubtitles API key", Credentials.openSubtitlesAPIKey(), Credentials.openSubtitlesSource())
    describe("OpenSubtitles username", Credentials.openSubtitlesUsername(),
             Credentials.source(defaultsKey: Credentials.osUsernameDefaultsKey,
                                env: "OPENSUBTITLES_USERNAME", toml: "opensubtitles_username"))
    describe("OpenSubtitles password", Credentials.openSubtitlesPassword(),
             Credentials.source(defaultsKey: Credentials.osPasswordDefaultsKey,
                                env: "OPENSUBTITLES_PASSWORD", toml: "opensubtitles_password"))
    let langs = Credentials.openSubtitlesLanguages()
    print("  \("OpenSubtitles languages".padding(toLength: 24, withPad: " ", startingAt: 0)) \(langs.isEmpty ? "not set" : langs)")
    print("")
    print("TMDb enrichment: \(Credentials.tmdbAPIKey() != nil ? "ON" : "off")")
    print("Subtitle fetch:  \(Credentials.openSubtitlesEnabled() ? "ON" : "off (needs key + username + password + languages)")")
    exit(0)
}

// MARK: - heal / verify

/// Inspect (and optionally clear) assets stuck pending on the device.
///
/// A pending asset that `FileError(0)` can't clear blocks `SyncFinished` for
/// every later sync — the symptom is a run that uploads fine and then hangs on
/// "finalizing…" until the 120 s deadline, forever, even for a tiny file. See
/// CLAUDE.md #16.
func runHeal(dryRun: Bool) -> Never {
    let device: DeviceInfo
    do { device = try discoverDevice() }
    catch {
        writeUserStderr("error: \(error.localizedDescription)\n")
        exit(1)
    }

    // Artwork sweep first, and unconditionally: stranded Airlock blobs are
    // independent of the stuck-asset ledger (they accumulate from TV.app
    // deletions we never see), so they must not sit behind the early exit
    // below.
    // Any step that fails must survive into the exit code — automation that
    // reads `heal` exiting 0 would otherwise conclude everything was checked.
    var healFailed = false
    do {
        let sweep = try sweepOrphanAirlockArtwork(device: device, dryRun: dryRun)
        if sweep.orphaned.isEmpty {
            print("Airlock artwork: \(sweep.scanned) blob(s), none orphaned.")
        } else {
            print("Airlock artwork: \(sweep.scanned) blob(s), \(sweep.orphaned.count) orphaned"
                + (dryRun ? " (dry run — not removed):" : ", \(sweep.removed) removed:"))
            for name in sweep.orphaned { print("  • \(name)") }
        }
    } catch {
        healFailed = true
        writeUserStderr("artwork sweep failed: \(error.localizedDescription)\n")
    }
    print("")

    // Report-only: repairing a split needs the rows re-inserted, which means
    // re-uploading the files. That is the user's call, not something heal
    // should do behind their back — so we name the episodes and stop.
    do {
        let splits = try findSeasonOrderSplits(device: device)
        if splits.isEmpty {
            print("Season sort keys: no split seasons.")
        } else {
            print("Season sort keys: \(splits.count) split season(s) — each of these")
            print("draws a duplicate \"Season N\" header in TV.app:")
            for s in splits {
                let keys = s.keys
                    .map { "\"\($0.name)\" ×\($0.count)" }
                    .joined(separator: " vs ")
                print("  • \(s.album) — season \(s.seasonNumber): \(keys)")
                if s.minority.isEmpty {
                    print("    (nothing we shipped on the losing side — nothing to re-sync)")
                } else {
                    print("    re-sync these \(s.minority.count) episode(s):")
                    for e in s.minority {
                        print("      E\(String(format: "%02d", e.episodeSortID))"
                            + "  \(e.title)  [\(e.syncID)]")
                    }
                }
            }
            print("  Fix: delete those episodes and sync them again. As long as the rest")
            print("  of the season stays put, the album survives and the re-insert picks")
            print("  up the season-number key.")
        }
    } catch {
        healFailed = true
        writeUserStderr("season-order check failed: \(error.localizedDescription)\n")
    }
    print("")
    if healFailed {
        writeUserStderr("heal: one or more checks did not run (see errors above)\n")
    }

    let tracked = StuckAssetLedger.all(udid: device.udid)
    guard !tracked.isEmpty else {
        print("No stuck assets tracked for this device.")
        print("")
        print("The ledger only fills in when a sync sees the SAME pending asset in")
        print("two AssetManifests with a FileError(0) sent in between. If syncs are")
        print("hanging at \"finalizing…\" and nothing is listed here, run a sync so a")
        print("manifest gets read, then run this again.")
        exit(healFailed ? 1 : 0)
    }

    print("Stuck assets tracked for \(device.udid.prefix(16))…:")
    let ids = tracked.keys.sorted()
    let rows = (try? findDeleteCandidates(bySyncIDs: ids, device: device)) ?? [:]
    for id in ids {
        let sightings = tracked[id] ?? 0
        let state: String
        if let row = rows[id] {
            state = row.isBound
                ? "BOUND -> \(row.mediaPath ?? "?") (will NOT be deleted)"
                : "UNBOUND — \"\(row.title)\" has no file, unplayable"
        } else {
            state = "no row in MediaLibrary (nothing to delete)"
        }
        let mark = sightings >= StuckAssetLedger.escalationThreshold ? "!" : " "
        print("  \(mark) \(id)  seen \(sightings)x  \(state)")
    }
    print("")

    let escalatable = StuckAssetLedger.escalatable(udid: device.udid)
    let deletable = escalatable.filter { rows[$0]?.isBound == false }
    if deletable.isEmpty {
        print("Nothing to delete: an asset must be seen \(StuckAssetLedger.escalationThreshold)x AND have an unbound row.")
        exit(healFailed ? 1 : 0)
    }
    if dryRun {
        print("--dry-run: would delete_track \(deletable.count) unbound row(s): \(deletable.map(String.init).joined(separator: ", "))")
        exit(healFailed ? 1 : 0)
    }

    let result = healStuckAssets(device: device, verbose: true)
    for p in result.problems { writeUserStderr("warning: \(p)\n") }
    print("Deleted \(result.deleted.count) row(s).")
    if !result.skippedBound.isEmpty {
        print("Left \(result.skippedBound.count) bound row(s) alone.")
    }
    exit(result.problems.isEmpty ? 0 : 1)
}

/// Read rows back by wire pid and report whether each bound to a real file.
/// The wire pids are the `asset=` values in the `atc.FileBegin` log lines.
func runVerify(syncIDs: [Int64]) -> Never {
    guard !syncIDs.isEmpty else {
        writeUserStderr("error: no valid sync IDs given\n")
        exit(2)
    }
    let device: DeviceInfo
    do { device = try discoverDevice() }
    catch {
        writeUserStderr("error: \(error.localizedDescription)\n")
        exit(1)
    }
    let rows: [Int64: DeleteCandidate]
    do { rows = try findDeleteCandidates(bySyncIDs: syncIDs, device: device) }
    catch {
        writeUserStderr("error: \(error.localizedDescription)\n")
        exit(1)
    }
    var bad = 0
    for id in syncIDs {
        guard let row = rows[id] else {
            print("\(id)  MISSING — no row with this sync_id")
            bad += 1
            continue
        }
        if row.isBound {
            print("\(id)  BOUND    \"\(row.title)\" -> \(row.mediaPath ?? "?")")
        } else {
            print("\(id)  UNBOUND  \"\(row.title)\" — base_location_id=0, won't play")
            bad += 1
        }
    }
    exit(bad == 0 ? 0 : 1)
}

/// Hand the pipeline the same TMDb / OpenSubtitles credentials the GUI uses.
/// `Credentials` reads this process's defaults first, then the MediaPorter
/// app's defaults domain, then env / config.toml / .env — so keys typed into
/// Settings apply to CLI and test-harness runs without being re-entered, and
/// a `sync` from the terminal exercises the same metadata path as a real one.
@MainActor
func applyCredentials(to pc: PipelineController) {
    if let key = Credentials.tmdbAPIKey() {
        pc.tmdbAPIKey = key
        print("TMDb: enabled (\(Credentials.tmdbSource().label))")
    } else {
        print("TMDb: no key found — titles/posters won't be enriched")
    }

    pc.openSubtitlesAPIKey = Credentials.openSubtitlesAPIKey() ?? ""
    pc.openSubtitlesUsername = Credentials.openSubtitlesUsername() ?? ""
    pc.openSubtitlesPassword = Credentials.openSubtitlesPassword() ?? ""
    pc.openSubtitlesLanguages = Credentials.openSubtitlesLanguages()
    if pc.openSubtitlesReady {
        print("OpenSubtitles: enabled (\(Credentials.openSubtitlesSource().label), langs=\(pc.openSubtitlesLanguages))")
    } else if !pc.openSubtitlesAPIKey.isEmpty {
        print("OpenSubtitles: key present but incomplete (needs username, password and languages)")
    }
}

/// `dispatchMain()`, main is given over to the dispatch runtime and
/// MainActor work flows; we terminate via `exit()` from the task.
func runSync(paths: [String]) -> Never {
    let urls = paths.map { URL(fileURLWithPath: $0) }
    for u in urls where !FileManager.default.fileExists(atPath: u.path) {
        writeUserStderr("not found: \(u.path)\n")
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
            writeUserStderr("no device: \(error.localizedDescription)\n")
            exitCode = 1
            return
        }
        print("Device: \(pc.deviceInfo!.displayName)")
        applyCredentials(to: pc)

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
                    writeUserStderr("\r\u{1b}[2K\(line)")
                    lastLine = line
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }

        await pc.runFullPipeline()

        printer.cancel()
        writeUserStderr("\r\u{1b}[2K") // clear status line

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
        writeUserStderr("no device: \(error.localizedDescription)\n")
        exit(1)
    }
    print("Device: \(device.displayName)")

    let candidates: [DeleteCandidate]
    do {
        candidates = try findDeleteCandidates(titleLike: titleLike, device: device)
    } catch {
        writeUserStderr("query failed: \(error.localizedDescription)\n")
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
        writeUserStderr("delete failed: \(error.localizedDescription)\n")
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
        writeUserStderr("verify query failed: \(error.localizedDescription) (non-fatal)\n")
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
        writeUserStderr("not found: \(path)\n")
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
        writeUserStderr("bench-upload failed: \(e.localizedDescription)\n")
        exit(1)
    }
    guard let r = report else { return }

    print("")
    print("=== AFC chunk-size benchmark ===")
    print("Transport: \(r.transport)")
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
        writeUserStderr("fixture not found: \(url.path)\n")
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
        applyCredentials(to: pc)
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
                    writeUserStderr("\r\u{1b}[2K\(line)")
                    last = line
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        await pc.runFullPipeline()
        printer.cancel()
        writeUserStderr("\r\u{1b}[2K")

        guard let job = pc.jobs.first else {
            failures.append("PipelineController dropped the job")
            return
        }
        guard job.status == .synced else {
            failures.append("sync failed: status=\(job.status.rawValue) error=\(job.error ?? "(none)")")
            return
        }
        guard let assetID = job.syncedAssetID else {
            failures.append("PipelineController didn't expose syncedAssetID for a .synced job — internal regression in runFullPipeline")
            return
        }
        print("  synced: asset_id=\(assetID)")

        // === PHASE 2: VERIFY ON DEVICE ===
        print("")
        print("[2/3] verify on device")
        // Direct sync_id lookup. We generated `assetID` in
        // `ATCSession.generateAssetID()` and shipped it as
        // `insert_track.pid`; iOS stores it verbatim in
        // `item_store.sync_id`. Querying by it sidesteps title-shape
        // drift (showName vs episode-label vs filename stem) and is
        // also immune to phantom rows from previous abandoned runs
        // — no other row on the device can have the same 18-digit
        // wire pid.
        let cand: DeleteCandidate
        do {
            guard let c = try findDeleteCandidate(bySyncID: Int64(assetID), device: device) else {
                failures.append(
                    "row not found: no item_store row has sync_id=\(assetID). We generated this id, shipped it in insert_track.pid, and the pipeline reported .synced — so medialibraryd either didn't accept the insert or renumbered the sync_id (would be a protocol regression).")
                return
            }
            cand = c
        } catch {
            failures.append("DB query failed: \(error.localizedDescription)")
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
        let stillThere: DeleteCandidate?
        do { stillThere = try findDeleteCandidate(bySyncID: cand.syncID, device: device) }
        catch {
            failures.append("post-delete query failed: \(error.localizedDescription)")
            return
        }
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
