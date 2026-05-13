// External-track muxer (#11e).
//
// One ffmpeg pre-pass that combines a source video with extra audio dubs
// and/or extra subtitle tracks (`FileJob.externalTracksToMux`) into a
// single intermediate MKV in temp. The existing transcode stage then runs
// against that intermediate file unchanged — it sees the extra audio /
// subs as if they had been embedded in the source all along.
//
// Why a pre-pass instead of weaving extra inputs into `Transcoder`:
// `Transcoder.buildCommand` builds a single dense ffmpeg invocation that
// already juggles stream actions, burn-in, downscales, AC3 handling, and
// codec-specific tags. Threading additional `-i` inputs and remapped
// stream indices through that pipeline would multiply the surface area.
// A clean separation keeps each pass simple: mux step is codec-copy +
// metadata; the existing transcode step continues to take a MediaInfo +
// decision and produce the final .m4v.
//
// Subtitle pre-pass: `.ass/.ssa` are converted to `.srt` before muxing
// because TV.app on iOS has no ASS renderer; mov_text won't preserve the
// styling anyway. SRT passes through untouched.

import Foundation

public enum ExternalMuxError: LocalizedError {
    case ffmpegNotFound
    case failed(String)
    public var errorDescription: String? {
        switch self {
        case .ffmpegNotFound: return "ffmpeg not found"
        case .failed(let m): return "External-track mux failed: \(m)"
        }
    }
}

public enum ExternalMux {
    /// Combine `sourceVideo` with every reference in `extras` into a single
    /// MKV at `outputPath`. Throws on ffmpeg failure. Caller is responsible
    /// for deleting `outputPath` after consumption.
    public static func mux(
        sourceVideo: URL,
        extras: [ExternalTrackRef],
        outputPath: URL
    ) async throws {
        guard let ffmpeg = FFmpegLocator.ffmpeg else { throw ExternalMuxError.ffmpegNotFound }
        guard !extras.isEmpty else { return }

        // ASS / SSA pre-pass — convert to SRT alongside the original file.
        var inputs: [(URL, ExternalTrackRef)] = []
        var temps: [URL] = []
        defer { for u in temps { try? FileManager.default.removeItem(at: u) } }

        for ref in extras {
            if ref.kind == .sub {
                let ext = ref.path.pathExtension.lowercased()
                if ext == "ass" || ext == "ssa" {
                    let dst = FileManager.default.temporaryDirectory
                        .appendingPathComponent("mp-extsub-\(UUID().uuidString).srt")
                    try await convertAssToSrt(input: ref.path, output: dst, ffmpeg: ffmpeg)
                    temps.append(dst)
                    inputs.append((dst, ref))
                    continue
                }
            }
            inputs.append((ref.path, ref))
        }

        // Build ffmpeg command.
        // Index 0 = source video. inputs[i] starts at ffmpeg input index i+1.
        var cmd: [String] = ["-y", "-i", sourceVideo.path]
        for (url, _) in inputs { cmd.append("-i"); cmd.append(url.path) }

        // Keep only video/audio/sub from source. `-map 0` pulled attached_pic,
        // fonts, data streams and chapters into the intermediate mkv, which
        // then surfaced as `bin_data` text tracks in the final mp4 and broke
        // the iOS TV-app's audio/subtitle switchers. Explicit per-type maps
        // + `-map_chapters -1` keep the intermediate clean. `?` makes the
        // map optional so files without audio or subs don't fail.
        cmd.append("-map"); cmd.append("0:v:0")
        cmd.append("-map"); cmd.append("0:a?")
        cmd.append("-map"); cmd.append("0:s?")
        cmd.append("-map_chapters"); cmd.append("-1")
        cmd.append("-dn")

        // Map each external as a single audio or subtitle stream.
        for (i, (_, ref)) in inputs.enumerated() {
            let inputIdx = i + 1
            switch ref.kind {
            case .dub: cmd.append("-map"); cmd.append("\(inputIdx):a:0")
            case .sub: cmd.append("-map"); cmd.append("\(inputIdx):s:0")
            }
        }

        // Codec: copy everything. Subtitle conversion already happened in the
        // pre-pass; downstream transcode will retag containers as needed.
        cmd.append("-c"); cmd.append("copy")

        // Metadata + disposition. The audio streams from the source come
        // first; appended dubs are audio streams [orig_audio_count ...].
        // Subs similarly stack after the source's subtitle streams. We
        // don't know the source's audio/sub counts without probing, so use
        // ffmpeg's per-input metadata addressing: `-metadata:s:a:N` where
        // N is the OUTPUT index of the audio stream — i.e. originals first
        // then appended in order.
        //
        // For dub disposition: clear every original audio's default, then
        // set default on the chosen dub (if any). Outputs that don't end
        // up with a default audio fall back to ffmpeg's first-track default
        // which is fine. (CLAUDE.md #10.)
        var audioOutIdx = 0          // counter of audio streams added (post-source)
        var subOutIdx = 0
        for (_, ref) in inputs {
            // We can't know source audio count here so just describe the
            // tags by the appended index. The actual mapping happens via
            // -map order. ffmpeg interprets `-metadata:s:a:N` against the
            // output audio stream count. The originals occupy 0..M-1; the
            // first appended dub is at M. We don't know M without a probe,
            // so we set metadata on the LAST audio stream by counting from
            // the input order via per-input flag `-metadata:s:a` which is
            // actually NOT per-output but per-input audio stream. The
            // simplest correct path: probe the source for audio count once.
            _ = ref
        }

        // Probe source for original audio + sub stream counts (cheap, ~50 ms).
        let sourceInfo = try await probeFile(url: sourceVideo)
        let origAudioCount = sourceInfo.audioStreams.count
        let origSubCount = sourceInfo.subtitleStreams.count

        for (_, ref) in inputs {
            switch ref.kind {
            case .dub:
                let outIdx = origAudioCount + audioOutIdx
                cmd.append("-metadata:s:a:\(outIdx)"); cmd.append("title=\(ref.label)")
                cmd.append("-metadata:s:a:\(outIdx)"); cmd.append("language=\(ref.lang)")
                if ref.isDefault {
                    // Clear default on every other audio stream, set on this.
                    for j in 0..<(origAudioCount + audioOutIdx) {
                        cmd.append("-disposition:a:\(j)"); cmd.append("0")
                    }
                    cmd.append("-disposition:a:\(outIdx)"); cmd.append("default")
                } else {
                    cmd.append("-disposition:a:\(outIdx)"); cmd.append("0")
                }
                audioOutIdx += 1
            case .sub:
                let outIdx = origSubCount + subOutIdx
                cmd.append("-metadata:s:s:\(outIdx)"); cmd.append("title=\(ref.label)")
                cmd.append("-metadata:s:s:\(outIdx)"); cmd.append("language=\(ref.lang)")
                if ref.forced {
                    cmd.append("-disposition:s:\(outIdx)"); cmd.append("forced")
                }
                subOutIdx += 1
            }
        }

        cmd.append(outputPath.path)

        let proc = Process()
        proc.executableURL = ffmpeg
        proc.arguments = cmd
        let errPipe = Pipe()
        proc.standardError = errPipe
        proc.standardOutput = FileHandle.nullDevice
        proc.standardInput = FileHandle.nullDevice

        ActiveProcesses.shared.add(proc)
        defer { ActiveProcesses.shared.remove(proc) }
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            let data = errPipe.fileHandleForReading.readDataToEndOfFile()
            let tail = String(data: data, encoding: .utf8)?.suffix(800) ?? ""
            throw ExternalMuxError.failed(String(tail))
        }
    }

    private static func convertAssToSrt(input: URL, output: URL, ffmpeg: URL) async throws {
        let proc = Process()
        proc.executableURL = ffmpeg
        proc.arguments = ["-y", "-i", input.path, output.path]
        let errPipe = Pipe()
        proc.standardError = errPipe
        proc.standardOutput = FileHandle.nullDevice
        proc.standardInput = FileHandle.nullDevice
        ActiveProcesses.shared.add(proc)
        defer { ActiveProcesses.shared.remove(proc) }
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            let data = errPipe.fileHandleForReading.readDataToEndOfFile()
            let tail = String(data: data, encoding: .utf8)?.suffix(400) ?? ""
            throw ExternalMuxError.failed("ass→srt: \(tail)")
        }
    }
}
