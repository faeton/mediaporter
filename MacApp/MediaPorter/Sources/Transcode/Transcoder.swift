// FFmpeg transcoder — build command, run with progress tracking.

import Foundation

enum TranscodeError: LocalizedError {
    case ffmpegNotFound
    case failed(String)
    case outputMissing

    var errorDescription: String? {
        switch self {
        case .ffmpegNotFound: return "ffmpeg not found. Install: brew install ffmpeg"
        case .failed(let msg): return "Transcode failed: \(msg)"
        case .outputMissing: return "Transcode output file missing"
        }
    }
}

/// Thread-safe registry of running ffmpeg processes so we can cancel them all on Ctrl+C or
/// user-initiated cancel. Mirrors transcode.py's _active_procs set + cancel_all().
private final class ActiveProcesses: @unchecked Sendable {
    static let shared = ActiveProcesses()
    private let lock = NSLock()
    private var procs: Set<ObjectIdentifier> = []
    private var byID: [ObjectIdentifier: Process] = [:]

    func add(_ p: Process) {
        lock.lock(); defer { lock.unlock() }
        let id = ObjectIdentifier(p)
        procs.insert(id)
        byID[id] = p
    }

    func remove(_ p: Process) {
        lock.lock(); defer { lock.unlock() }
        let id = ObjectIdentifier(p)
        procs.remove(id)
        byID[id] = nil
    }

    func cancelAll() {
        lock.lock()
        let running = Array(byID.values)
        lock.unlock()
        for p in running where p.isRunning {
            p.terminate()
        }
    }
}

/// Thread-safe rolling-tail buffer for ffmpeg stderr. Keeps the last N lines so we can
/// include them in error messages without letting the 64 KB OS pipe fill up and deadlock
/// ffmpeg's write(2). Mirrors transcode.py's stderr-drain thread.
private final class StderrTail: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    private let maxLines: Int
    private var carry = ""

    init(maxLines: Int = 200) { self.maxLines = maxLines }

    func append(_ chunk: Data) {
        guard let s = String(data: chunk, encoding: .utf8), !s.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        let combined = carry + s
        let parts = combined.components(separatedBy: "\n")
        carry = parts.last ?? ""
        for part in parts.dropLast() where !part.isEmpty {
            lines.append(part)
            if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
        }
    }

    func joined() -> String {
        lock.lock(); defer { lock.unlock() }
        var out = lines
        if !carry.isEmpty { out.append(carry) }
        return out.joined(separator: "\n")
    }
}

/// Escape a filesystem path for use inside an ffmpeg filter argument value
/// (e.g. `subtitles=filename=<path>`). The filter-graph parser treats these
/// bytes specially inside a filter arg value: `\`, `'`, `:`, `[`, `]`, `,`,
/// `;`, `=`. All of them must be backslash-escaped or the parser may split
/// the arg in the middle of a path.
private func escapeFilterPath(_ path: String) -> String {
    var out = ""
    for ch in path {
        switch ch {
        case "\\", "'", ":", "[", "]", ",", ";", "=":
            out.append("\\")
            out.append(ch)
        default:
            out.append(ch)
        }
    }
    return out
}

public enum Transcoder {
    /// Terminate every ffmpeg process that's currently running.
    public static func cancelAll() {
        ActiveProcesses.shared.cancelAll()
    }

    /// Detect if VideoToolbox HEVC encoder is available.
    static func detectVideoToolbox() -> Bool {
        guard let ffmpeg = FFmpegLocator.ffmpeg else { return false }
        let proc = Process()
        proc.executableURL = ffmpeg
        proc.arguments = ["-hide_banner", "-encoders"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        proc.standardInput = FileHandle.nullDevice
        do {
            try proc.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            let output = String(data: data, encoding: .utf8) ?? ""
            return output.contains("hevc_videotoolbox")
        } catch {
            return false
        }
    }

    /// Build the ffmpeg command for a transcode/remux job.
    static func buildCommand(
        mediaInfo: MediaInfo,
        decision: TranscodeDecision,
        audioActions: [AudioAction],
        outputPath: URL,
        quality: QualityPreset = .balanced,
        hwAccel: Bool = true,
        maxResolution: ResolutionLimit = .original,
        selectedAudio: [Int]? = nil,
        selectedSubtitles: [Int]? = nil,
        externalSubs: [ExternalSubtitle] = [],
        burnIn: BurnInSubtitle? = nil
    ) -> [String] {
        guard let ffmpeg = FFmpegLocator.ffmpeg else { return [] }
        var cmd = [ffmpeg.path, "-hide_banner", "-y", "-progress", "pipe:1"]

        // Split externals: the one being burned (if any) is consumed by the
        // subtitles filter directly, not added as a mapped stream.
        let burnExternalIdx: Int? = {
            if case .external(let i) = burnIn, i < externalSubs.count { return i }
            return nil
        }()
        let embedExternals: [ExternalSubtitle] = externalSubs.enumerated().compactMap { i, s in
            i == burnExternalIdx ? nil : s
        }

        // Embedded burn-in target: figure out whether it's a bitmap sub (PGS/VOBSUB).
        // Bitmap subs can't be rendered by libass — we have to route them through
        // the `overlay` filter on a filter_complex graph. Text subs stay on `-vf
        // subtitles=...` (libass). External subs are always text (srt/ass).
        let burnEmbeddedIdx: Int? = {
            if case .embedded(let i) = burnIn { return i }
            return nil
        }()
        let isBitmapBurn: Bool = {
            guard let i = burnEmbeddedIdx, i < mediaInfo.subtitleStreams.count else { return false }
            return CodecSets.bitmapSubtitles.contains(mediaInfo.subtitleStreams[i].codecName)
        }()

        // Input file
        cmd += ["-i", mediaInfo.path.path]

        // External subtitle inputs (only the ones we embed)
        for sub in embedExternals {
            cmd += ["-i", sub.path.path]
        }

        // Map video. For bitmap burn-in the labeled filter_complex output
        // [vout] replaces the direct video map; added later after the filter
        // chain is built.
        if !isBitmapBurn {
            cmd += ["-map", "0:v:0"]
        }

        // Map selected audio streams
        let audioIndices = selectedAudio ?? Array(0..<mediaInfo.audioStreams.count)
        for i in audioIndices {
            guard i < mediaInfo.audioStreams.count else { continue }
            cmd += ["-map", "0:a:\(i)"]
        }

        // Skip the burn-in target from the mapped subtitle set so it doesn't
        // show up twice (once burned, once as a selectable text track).
        let rawSubIndices = selectedSubtitles ?? []
        let subIndices = rawSubIndices.filter { $0 != burnEmbeddedIdx }

        for i in subIndices {
            guard i < mediaInfo.subtitleStreams.count else { continue }
            let action = decision.streamActions[mediaInfo.subtitleStreams[i].index]
            if action != "skip" {
                cmd += ["-map", "0:s:\(i)"]
            }
        }

        // Map external subs
        for (idx, _) in embedExternals.enumerated() {
            cmd += ["-map", "\(idx + 1):0"]
        }

        // Video codec + resolution scaling + burn-in filter
        if let videoStream = mediaInfo.videoStreams.first {
            let baseAction = decision.streamActions[videoStream.index] ?? "copy"
            let needsDownscale = maxResolution.wouldDownscale(from: videoStream.height)
            // If downscaling, must transcode (can't scale with copy).
            // If burning subs, must transcode (copy can't apply filters).
            let action = (needsDownscale || burnIn != nil) ? "transcode" : baseAction

            if action == "copy" {
                cmd += ["-c:v", "copy"]
                if ["hevc", "h265"].contains(videoStream.codecName) {
                    cmd += ["-tag:v", "hvc1"]
                }
            } else {
                // Bitmap burn-in needs a filter_complex graph (overlay) because libass
                // only handles text. Text burn-in (and plain scale) stays on -vf.
                if isBitmapBurn, let burnIdx = burnEmbeddedIdx {
                    var chain = "[0:v:0]"
                    if needsDownscale, let maxH = maxResolution.maxHeight {
                        chain += "scale=-2:\(maxH)[vs];[vs]"
                    }
                    chain += "[0:s:\(burnIdx)]overlay[vout]"
                    cmd += ["-filter_complex", chain, "-map", "[vout]"]
                } else {
                    var filters: [String] = []
                    if needsDownscale, let maxH = maxResolution.maxHeight {
                        filters.append("scale=-2:\(maxH)")
                    }
                    if let burn = burnIn {
                        switch burn {
                        case .embedded(let i):
                            // text sub — libass via subtitles filter
                            let esc = escapeFilterPath(mediaInfo.path.path)
                            filters.append("subtitles=filename=\(esc):si=\(i)")
                        case .external(let i):
                            guard i < externalSubs.count else { break }
                            let esc = escapeFilterPath(externalSubs[i].path.path)
                            filters.append("subtitles=filename=\(esc)")
                        }
                    }
                    if !filters.isEmpty {
                        cmd += ["-vf", filters.joined(separator: ",")]
                    }
                }

                if hwAccel && detectVideoToolbox() {
                    cmd += ["-c:v", "hevc_videotoolbox", "-q:v", String(quality.vtQuality), "-tag:v", "hvc1"]
                } else {
                    cmd += ["-c:v", "libx265", "-crf", String(quality.crf),
                            "-preset", quality.preset, "-tag:v", "hvc1", "-pix_fmt", "yuv420p"]
                }
            }
        }

        // Audio codec — per-track copy vs transcode (AC3 is NOT compatible; forced to AAC).
        // Mixed codecs (e.g. aac+eac3) are fine and play correctly in the TV app.
        for (outIdx, audioIdx) in audioIndices.enumerated() {
            guard audioIdx < audioActions.count else { continue }
            let aa = audioActions[audioIdx]

            if aa.action == "transcode" {
                let channels = aa.targetChannels ?? (aa.stream.channels ?? 2)
                let bitrate = aa.targetBitrate ?? (channels >= 6 ? "384k" : "256k")
                cmd += ["-c:a:\(outIdx)", "aac", "-b:a:\(outIdx)", bitrate, "-ac:a:\(outIdx)", String(min(channels, 6))]
            } else {
                cmd += ["-c:a:\(outIdx)", "copy"]
            }

            // Audio metadata
            let lang = aa.stream.language ?? "und"
            cmd += ["-metadata:s:a:\(outIdx)", "language=\(lang)"]
            if let title = aa.stream.title {
                cmd += ["-metadata:s:a:\(outIdx)", "handler_name=\(title)"]
            }

            // Disposition: pin track 0 as the only default — the mp4 muxer forces
            // a default if none is set, and multiple defaults break the switcher entirely.
            cmd += ["-disposition:a:\(outIdx)", outIdx == 0 ? "default" : "0"]
        }

        // Subtitle codec
        let hasAnySubs = !subIndices.isEmpty || !embedExternals.isEmpty
        if hasAnySubs {
            cmd += ["-c:s", "mov_text"]
            var subOutIdx = 0
            for i in subIndices {
                guard i < mediaInfo.subtitleStreams.count else { continue }
                let sub = mediaInfo.subtitleStreams[i]
                let lang = sub.language ?? "und"
                cmd += ["-metadata:s:s:\(subOutIdx)", "language=\(lang)"]
                subOutIdx += 1
            }
            for ext in embedExternals {
                cmd += ["-metadata:s:s:\(subOutIdx)", "language=\(ext.language)"]
                subOutIdx += 1
            }
        } else {
            cmd += ["-sn"]
        }

        // Output
        cmd += ["-movflags", "+faststart", "-f", "mp4", outputPath.path]
        return cmd
    }

    /// Run ffmpeg transcode with progress reporting.
    static func transcode(
        mediaInfo: MediaInfo,
        decision: TranscodeDecision,
        outputPath: URL,
        quality: QualityPreset = .balanced,
        hwAccel: Bool = true,
        maxResolution: ResolutionLimit = .original,
        selectedAudio: [Int]? = nil,
        selectedSubtitles: [Int]? = nil,
        externalSubs: [ExternalSubtitle] = [],
        burnIn: BurnInSubtitle? = nil,
        progress: ((Double) -> Void)? = nil
    ) async throws -> URL {
        guard let ffmpeg = FFmpegLocator.ffmpeg else { throw TranscodeError.ffmpegNotFound }

        let audioActions = classifyAllAudio(mediaInfo.audioStreams)
        let cmd = buildCommand(
            mediaInfo: mediaInfo,
            decision: decision,
            audioActions: audioActions,
            outputPath: outputPath,
            quality: quality,
            hwAccel: hwAccel,
            maxResolution: maxResolution,
            selectedAudio: selectedAudio,
            selectedSubtitles: selectedSubtitles,
            externalSubs: externalSubs,
            burnIn: burnIn
        )

        guard !cmd.isEmpty else { throw TranscodeError.ffmpegNotFound }

        let proc = Process()
        proc.executableURL = ffmpeg
        proc.arguments = Array(cmd.dropFirst()) // drop the ffmpeg path itself
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        // Detach stdin — ffmpeg reads keyboard commands (q to quit, etc.) from
        // the tty by default. When launched from a terminal, it inherits our
        // stdin, gets SIGTTIN in its background process group, and freezes in
        // state T with zero progress. /dev/null kills that dead.
        proc.standardInput = FileHandle.nullDevice

        // Drain stderr on a background queue into a rolling tail. Without this, ffmpeg's
        // stderr pipe fills its 64 KB OS buffer and blocks on write(2) mid-transcode.
        let tail = StderrTail()
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                tail.append(data)
            }
        }

        try proc.run()
        ActiveProcesses.shared.add(proc)
        defer {
            ActiveProcesses.shared.remove(proc)
            errPipe.fileHandleForReading.readabilityHandler = nil
        }

        let durationUs = mediaInfo.duration * 1_000_000
        let fileHandle = outPipe.fileHandleForReading

        // Parse progress on background thread
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                while true {
                    let data = fileHandle.availableData
                    if data.isEmpty { break }
                    guard let line = String(data: data, encoding: .utf8) else { continue }
                    for part in line.components(separatedBy: .newlines) {
                        if part.hasPrefix("out_time_ms="),
                           let us = Double(part.dropFirst("out_time_ms=".count)),
                           durationUs > 0 {
                            let pct = min(us / durationUs, 1.0)
                            DispatchQueue.main.async { progress?(pct) }
                        }
                    }
                }
                continuation.resume()
            }
        }

        proc.waitUntilExit()

        // The readabilityHandler runs asynchronously — by the time waitUntilExit
        // returns there can still be bytes in the pipe that haven't hit `tail`
        // yet. Detach the handler and do a final synchronous drain so we don't
        // throw "exit code 1" with no context when ffmpeg actually logged the
        // real cause (filter graph errors, missing libass, bad path, etc.).
        errPipe.fileHandleForReading.readabilityHandler = nil
        let remaining = errPipe.fileHandleForReading.readDataToEndOfFile()
        if !remaining.isEmpty { tail.append(remaining) }

        guard proc.terminationStatus == 0 else {
            let errOutput = tail.joined()
            let lastLines = errOutput.split(separator: "\n").suffix(8).joined(separator: "\n")
            let detail = lastLines.isEmpty ? "exit code \(proc.terminationStatus)"
                                           : "exit code \(proc.terminationStatus)\n\(lastLines)"
            throw TranscodeError.failed(detail)
        }
        guard FileManager.default.fileExists(atPath: outputPath.path) else {
            throw TranscodeError.outputMissing
        }

        return outputPath
    }
}
