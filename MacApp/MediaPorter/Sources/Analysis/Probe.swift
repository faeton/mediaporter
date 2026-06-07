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

/// Thread-safe holder that lets `probeFile`'s cancellation handler terminate
/// the live ffprobe child from outside the detached task. `Process` isn't
/// `Sendable`; all access is gated behind the lock and the handler only ever
/// calls `terminate()`.
///
/// `launch()` runs `Process.run()` *while holding the lock* so there is no
/// window where a concurrent `terminate()` sees an un-launched process,
/// no-ops, and then `run()` starts an orphan that never gets killed: a
/// cancel either lands before launch (sets `cancelled`, `launch()` bails) or
/// after (process is running, `terminate()` reaches it). `run()` only forks —
/// it does no I/O — so holding the lock across it can't stall the canceller;
/// the long `readDataToEndOfFile`/`waitUntilExit` happen outside the lock.
private final class ProbeProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var proc: Process?
    private var cancelled = false

    /// Launch the process under the lock. Returns false (and does not launch)
    /// if a cancellation already arrived.
    func launch(_ p: Process) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        if cancelled { return false }
        proc = p
        try p.run()
        return true
    }

    func terminate() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        if let p = proc, p.isRunning { p.terminate() }
    }
}

/// Run ffprobe on a media file and parse the output into a MediaInfo struct.
public func probeFile(url: URL) async throws -> MediaInfo {
    guard let ffprobe = FFmpegLocator.ffprobe else { throw ProbeError.ffprobeNotFound }

    // Run ffprobe off the cooperative pool. The synchronous Process.run +
    // readDataToEndOfFile + waitUntilExit pins a cooperative-pool worker for
    // the whole probe; analyze fans out 4 probes at once, which on a quad-core
    // is the entire pool, starving other async work (TMDb fetches, file scan)
    // until the probes finish. Task.detached moves the blocking I/O onto a
    // fresh thread so the cooperative pool stays free. The process handle is
    // held in a lock-guarded box so a cancelled analyze actually terminates the
    // child — matching the Transcoder's "Cancel reaches the subprocess"
    // contract — instead of leaving ffprobe running to completion. See plan.md A5.
    let box = ProbeProcessBox()
    let data: Data = try await withTaskCancellationHandler {
        try await Task.detached(priority: .utility) { () throws -> Data in
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

            guard try box.launch(proc) else { throw CancellationError() }
            let out = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()

            guard proc.terminationStatus == 0 else {
                throw ProbeError.failed("exit code \(proc.terminationStatus)")
            }
            return out
        }.value
    } onCancel: {
        box.terminate()
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

        // Older AVI / re-encode files have no `TAG:language` — ffprobe returns
        // nil and the UI shows "Unknown" even though the title field carries
        // strong hints (Cyrillic dubber names → rus, Japanese title → jpn).
        // Infer from script when the explicit tag is missing.
        let inferredLang = tags["language"] ?? inferLanguageFromTitle(tags["title"])

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
            language: inferredLang,
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

/// Best-effort language inference from a stream title when ffprobe couldn't
/// extract an explicit `TAG:language`. AVI / older re-encodes carry no
/// language tag at all, but the title often contains script-specific
/// characters (Cyrillic dubber names → rus, Japanese title → jpn) that pin
/// the track's source language down well enough for cluster matching. Returns
/// ISO 639-2 codes so downstream lang normalization sees consistent values.
///
/// Conservative on purpose: only fires when the title contains characters
/// from a single, unambiguous script. A track titled "Russian dub" stays
/// "und" — the user can still pick by title in the UI.
func inferLanguageFromTitle(_ rawTitle: String?) -> String? {
    guard let title = rawTitle, !title.isEmpty else { return nil }
    var hasCyrillic = false
    var hasHiragana = false
    var hasKatakana = false
    var hasHangul = false
    var hasCJK = false
    for scalar in title.unicodeScalars {
        let v = scalar.value
        switch v {
        case 0x0400...0x04FF, 0x0500...0x052F: hasCyrillic = true
        case 0x3040...0x309F: hasHiragana = true
        case 0x30A0...0x30FF: hasKatakana = true
        case 0xAC00...0xD7AF, 0x1100...0x11FF, 0x3130...0x318F: hasHangul = true
        case 0x4E00...0x9FFF: hasCJK = true
        default: break
        }
    }
    if hasCyrillic { return "rus" }
    // Hiragana / Katakana are kana → Japanese. CJK alone could be Chinese,
    // but combined with kana confirms Japanese.
    if hasHiragana || hasKatakana { return "jpn" }
    if hasHangul { return "kor" }
    if hasCJK { return "chi" }
    return nil
}
