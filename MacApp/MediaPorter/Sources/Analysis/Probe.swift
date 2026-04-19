// FFprobe runner — analyze media files and return structured stream info.

import Foundation

// MARK: - Data Models

public struct StreamInfo {
    public let index: Int
    public let codecType: String      // "video", "audio", "subtitle"
    public let codecName: String
    // Video
    public let width: Int?
    public let height: Int?
    public let pixFmt: String?
    public let profile: String?
    // Audio
    public let channels: Int?
    public let channelLayout: String?
    public let sampleRate: Int?
    public let bitRate: Int?
    // Common
    public let language: String?
    public let title: String?
    public let isDefault: Bool
    public let isForced: Bool
    /// hearing_impaired disposition — SDH subs (captions describing sounds + dialog).
    public let isHearingImpaired: Bool

    public init(
        index: Int,
        codecType: String,
        codecName: String,
        width: Int? = nil,
        height: Int? = nil,
        pixFmt: String? = nil,
        profile: String? = nil,
        channels: Int? = nil,
        channelLayout: String? = nil,
        sampleRate: Int? = nil,
        bitRate: Int? = nil,
        language: String? = nil,
        title: String? = nil,
        isDefault: Bool = false,
        isForced: Bool = false,
        isHearingImpaired: Bool = false
    ) {
        self.index = index
        self.codecType = codecType
        self.codecName = codecName
        self.width = width
        self.height = height
        self.pixFmt = pixFmt
        self.profile = profile
        self.channels = channels
        self.channelLayout = channelLayout
        self.sampleRate = sampleRate
        self.bitRate = bitRate
        self.language = language
        self.title = title
        self.isDefault = isDefault
        self.isForced = isForced
        self.isHearingImpaired = isHearingImpaired
    }
}

public struct ExternalSubtitle {
    public let path: URL
    public let language: String    // ISO 639-2
    public let format: String      // srt, ass, ssa

    public init(path: URL, language: String, format: String) {
        self.path = path
        self.language = language
        self.format = format
    }
}

public struct MediaInfo {
    public let path: URL
    public let formatName: String
    public let duration: Double       // seconds
    public let bitRate: Int?
    public let videoStreams: [StreamInfo]
    public let audioStreams: [StreamInfo]
    public let subtitleStreams: [StreamInfo]
    public var externalSubtitles: [ExternalSubtitle] = []

    public init(
        path: URL,
        formatName: String,
        duration: Double,
        bitRate: Int? = nil,
        videoStreams: [StreamInfo] = [],
        audioStreams: [StreamInfo] = [],
        subtitleStreams: [StreamInfo] = [],
        externalSubtitles: [ExternalSubtitle] = []
    ) {
        self.path = path
        self.formatName = formatName
        self.duration = duration
        self.bitRate = bitRate
        self.videoStreams = videoStreams
        self.audioStreams = audioStreams
        self.subtitleStreams = subtitleStreams
        self.externalSubtitles = externalSubtitles
    }
}

public enum ProbeError: LocalizedError {
    case ffprobeNotFound
    case failed(String)
    case parseError(String)

    public var errorDescription: String? {
        switch self {
        case .ffprobeNotFound: return "ffprobe not found. Install ffmpeg: brew install ffmpeg"
        case .failed(let msg): return "ffprobe failed: \(msg)"
        case .parseError(let msg): return "Failed to parse ffprobe output: \(msg)"
        }
    }
}

// MARK: - Probe

/// Run ffprobe on a media file and parse the output into a MediaInfo struct.
public func probeFile(url: URL) async throws -> MediaInfo {
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
    proc.standardInput = FileHandle.nullDevice

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
            isForced: disposition["forced"] as? Int == 1,
            isHearingImpaired: disposition["hearing_impaired"] as? Int == 1
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
