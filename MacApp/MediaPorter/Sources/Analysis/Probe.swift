// FFprobe runner — analyze media files and return structured stream info.

import Foundation

// MARK: - Data Models

struct StreamInfo {
    let index: Int
    let codecType: String      // "video", "audio", "subtitle"
    let codecName: String
    // Video
    let width: Int?
    let height: Int?
    let pixFmt: String?
    let profile: String?
    // Audio
    let channels: Int?
    let channelLayout: String?
    let sampleRate: Int?
    let bitRate: Int?
    // Common
    let language: String?
    let title: String?
    let isDefault: Bool
    let isForced: Bool
}

struct ExternalSubtitle {
    let path: URL
    let language: String    // ISO 639-2
    let format: String      // srt, ass, ssa
}

struct MediaInfo {
    let path: URL
    let formatName: String
    let duration: Double       // seconds
    let bitRate: Int?
    let videoStreams: [StreamInfo]
    let audioStreams: [StreamInfo]
    let subtitleStreams: [StreamInfo]
    var externalSubtitles: [ExternalSubtitle] = []
}

enum ProbeError: LocalizedError {
    case ffprobeNotFound
    case failed(String)
    case parseError(String)

    var errorDescription: String? {
        switch self {
        case .ffprobeNotFound: return "ffprobe not found. Install ffmpeg: brew install ffmpeg"
        case .failed(let msg): return "ffprobe failed: \(msg)"
        case .parseError(let msg): return "Failed to parse ffprobe output: \(msg)"
        }
    }
}

// MARK: - Probe

/// Run ffprobe on a media file and parse the output into a MediaInfo struct.
func probeFile(url: URL) async throws -> MediaInfo {
    guard let ffprobe = FFmpegLocator.ffprobe else { throw ProbeError.ffprobeNotFound }

    let proc = Process()
    proc.executableURL = ffprobe
    proc.arguments = [
        "-v", "quiet",
        "-print_format", "json",
        "-show_format",
        "-show_streams",
        url.path,
    ]

    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = FileHandle.nullDevice

    try proc.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    proc.waitUntilExit()

    guard proc.terminationStatus == 0 else {
        throw ProbeError.failed("exit code \(proc.terminationStatus)")
    }

    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw ProbeError.parseError("invalid JSON")
    }

    // Parse format
    guard let format = json["format"] as? [String: Any] else {
        throw ProbeError.parseError("missing format section")
    }
    let formatName = format["format_name"] as? String ?? "unknown"
    let duration = Double(format["duration"] as? String ?? "0") ?? 0
    let fmtBitRate = Int(format["bit_rate"] as? String ?? "")

    // Parse streams
    let rawStreams = json["streams"] as? [[String: Any]] ?? []
    var video: [StreamInfo] = []
    var audio: [StreamInfo] = []
    var subtitle: [StreamInfo] = []

    for s in rawStreams {
        let codecType = s["codec_type"] as? String ?? ""
        // Skip attached pictures (album art, etc.)
        if codecType == "video",
           let disposition = s["disposition"] as? [String: Any],
           disposition["attached_pic"] as? Int == 1 {
            continue
        }

        let tags = s["tags"] as? [String: String] ?? [:]
        let disposition = s["disposition"] as? [String: Any] ?? [:]

        let stream = StreamInfo(
            index: s["index"] as? Int ?? 0,
            codecType: codecType,
            codecName: s["codec_name"] as? String ?? "unknown",
            width: s["width"] as? Int,
            height: s["height"] as? Int,
            pixFmt: s["pix_fmt"] as? String,
            profile: s["profile"] as? String,
            channels: s["channels"] as? Int,
            channelLayout: s["channel_layout"] as? String,
            sampleRate: Int(s["sample_rate"] as? String ?? ""),
            bitRate: Int(s["bit_rate"] as? String ?? ""),
            language: tags["language"],
            title: tags["title"],
            isDefault: disposition["default"] as? Int == 1,
            isForced: disposition["forced"] as? Int == 1
        )

        switch codecType {
        case "video": video.append(stream)
        case "audio": audio.append(stream)
        case "subtitle": subtitle.append(stream)
        default: break
        }
    }

    return MediaInfo(
        path: url,
        formatName: formatName,
        duration: duration,
        bitRate: fmtBitRate,
        videoStreams: video,
        audioStreams: audio,
        subtitleStreams: subtitle
    )
}
