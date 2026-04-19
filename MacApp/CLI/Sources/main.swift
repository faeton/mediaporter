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
