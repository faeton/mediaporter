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

enum Transcoder {
    /// Detect if VideoToolbox HEVC encoder is available.
    static func detectVideoToolbox() -> Bool {
        guard let ffmpeg = FFmpegLocator.ffmpeg else { return false }
        let proc = Process()
        proc.executableURL = ffmpeg
        proc.arguments = ["-hide_banner", "-encoders"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
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
        externalSubs: [ExternalSubtitle] = []
    ) -> [String] {
        guard let ffmpeg = FFmpegLocator.ffmpeg else { return [] }
        var cmd = [ffmpeg.path, "-hide_banner", "-y", "-progress", "pipe:1"]

        // Input file
        cmd += ["-i", mediaInfo.path.path]

        // External subtitle inputs
        for sub in externalSubs {
            cmd += ["-i", sub.path.path]
        }

        // Map video (first stream)
        cmd += ["-map", "0:v:0"]

        // Map selected audio streams
        let audioIndices = selectedAudio ?? Array(0..<mediaInfo.audioStreams.count)
        for i in audioIndices {
            guard i < mediaInfo.audioStreams.count else { continue }
            cmd += ["-map", "0:a:\(i)"]
        }

        // Map selected subtitle streams
        let subIndices = selectedSubtitles ?? []
        for i in subIndices {
            guard i < mediaInfo.subtitleStreams.count else { continue }
            let action = decision.streamActions[mediaInfo.subtitleStreams[i].index]
            if action != "skip" {
                cmd += ["-map", "0:s:\(i)"]
            }
        }

        // Map external subs
        for (idx, _) in externalSubs.enumerated() {
            cmd += ["-map", "\(idx + 1):0"]
        }

        // Video codec + resolution scaling
        if let videoStream = mediaInfo.videoStreams.first {
            let baseAction = decision.streamActions[videoStream.index] ?? "copy"
            let needsDownscale = maxResolution.wouldDownscale(from: videoStream.height)
            // If downscaling, must transcode (can't scale with copy)
            let action = needsDownscale ? "transcode" : baseAction

            if action == "copy" {
                cmd += ["-c:v", "copy"]
                if ["hevc", "h265"].contains(videoStream.codecName) {
                    cmd += ["-tag:v", "hvc1"]
                }
            } else {
                // Scale filter if downscaling (scale to maxHeight, keep aspect ratio, even dimensions)
                if needsDownscale, let maxH = maxResolution.maxHeight {
                    cmd += ["-vf", "scale=-2:\(maxH)"]
                }

                if hwAccel && detectVideoToolbox() {
                    cmd += ["-c:v", "hevc_videotoolbox", "-q:v", String(quality.vtQuality), "-tag:v", "hvc1"]
                } else {
                    cmd += ["-c:v", "libx265", "-crf", String(quality.crf),
                            "-preset", quality.preset, "-tag:v", "hvc1", "-pix_fmt", "yuv420p"]
                }
            }
        }

        // Audio codec — check if we need to normalize mixed codecs to AAC
        let selectedActions = audioIndices.compactMap { i -> AudioAction? in
            guard i < audioActions.count else { return nil }
            return audioActions[i]
        }
        let codecs = Set(selectedActions.map { $0.action == "copy" ? $0.stream.codecName : "aac" })
        let forceMixedToAAC = codecs.count > 1 && selectedActions.count > 1

        for (outIdx, audioIdx) in audioIndices.enumerated() {
            guard audioIdx < audioActions.count else { continue }
            let aa = audioActions[audioIdx]

            if forceMixedToAAC || aa.action == "transcode" {
                // Transcode to AAC
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
        }

        // Subtitle codec
        let hasAnySubs = !subIndices.isEmpty || !externalSubs.isEmpty
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
            for ext in externalSubs {
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
            externalSubs: externalSubs
        )

        guard !cmd.isEmpty else { throw TranscodeError.ffmpegNotFound }

        let proc = Process()
        proc.executableURL = ffmpeg
        proc.arguments = Array(cmd.dropFirst()) // drop the ffmpeg path itself
        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = FileHandle.nullDevice

        try proc.run()

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
        guard proc.terminationStatus == 0 else {
            throw TranscodeError.failed("exit code \(proc.terminationStatus)")
        }
        guard FileManager.default.fileExists(atPath: outputPath.path) else {
            throw TranscodeError.outputMissing
        }

        return outputPath
    }
}
