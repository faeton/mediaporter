// Codec compatibility analysis for iPad — decide copy vs transcode per stream.

import Foundation

// MARK: - Compatible Codecs

public enum CodecSets {
    public static let compatibleVideo: Set<String> = ["h264", "hevc", "h265"]
    // NOTE: AC3 is intentionally excluded — the iPad TV app silently drops AC3 tracks
    // from the audio-language switcher. Force AC3 → AAC at transcode time.
    // See research/docs/AUDIO_SWITCHER_RULE.md.
    public static let compatibleAudio: Set<String> = ["aac", "eac3", "alac", "mp3"]
    public static let textSubtitles: Set<String> = ["subrip", "srt", "ass", "ssa", "mov_text", "webvtt"]
    public static let bitmapSubtitles: Set<String> = ["hdmv_pgs_subtitle", "dvd_subtitle", "dvb_subtitle", "pgssub"]
    public static let compatibleContainers: Set<String> = ["mov", "mp4", "m4v", "mov,mp4,m4a,3gp,3g2,mj2"]
}

// MARK: - Resolution Limit

public enum ResolutionLimit: String, CaseIterable, Identifiable, Comparable {
    case tiny = "360p"
    case sd = "480p"
    case hd = "720p"
    case fhd = "1080p"
    case uhd4k = "4K (2160p)"
    case original = "Original"

    public var id: String { rawValue }

    /// Max height for this limit, nil = no limit.
    public var maxHeight: Int? {
        switch self {
        case .tiny: return 360
        case .sd: return 480
        case .hd: return 720
        case .fhd: return 1080
        case .uhd4k: return 2160
        case .original: return nil
        }
    }

    private var sortOrder: Int {
        switch self {
        case .tiny: return 0
        case .sd: return 1
        case .hd: return 2
        case .fhd: return 3
        case .uhd4k: return 4
        case .original: return 5
        }
    }

    public static func < (lhs: ResolutionLimit, rhs: ResolutionLimit) -> Bool {
        lhs.sortOrder < rhs.sortOrder
    }

    /// Whether this limit would actually downscale from the given height.
    public func wouldDownscale(from sourceHeight: Int?) -> Bool {
        guard let max = maxHeight, let src = sourceHeight else { return false }
        return src > max
    }

    /// Options that make sense for a given source height (no options above source res).
    public static func availableOptions(sourceHeight: Int?) -> [ResolutionLimit] {
        guard let src = sourceHeight, src > 0 else { return [.original] }
        var options: [ResolutionLimit] = []
        // Add downscale options that are smaller than source
        for limit in [ResolutionLimit.tiny, .sd, .hd, .fhd, .uhd4k] {
            if let max = limit.maxHeight, max < src {
                options.append(limit)
            }
        }
        // "Original" means keep source resolution (always available as the top option)
        options.append(.original)
        return options
    }

    /// Label showing the actual source resolution for "Original".
    public func label(sourceHeight: Int?) -> String {
        if self == .original, let h = sourceHeight {
            return "Original (\(h)p)"
        }
        return rawValue
    }
}

// MARK: - Transcode Decision

public struct TranscodeDecision {
    /// Per stream index: "copy", "transcode", "convert_to_mov_text", "skip"
    public var streamActions: [Int: String] = [:]
    public var needsTranscode: Bool = false
    public var needsRemux: Bool = false
    public var resolutionLimit: ResolutionLimit = .original
    public var needsDownscale: Bool = false

    public init() {}
}

/// Evaluate what needs to happen to make a file iPad-compatible.
public func evaluateCompatibility(mediaInfo: MediaInfo) -> TranscodeDecision {
    var decision = TranscodeDecision()

    // Check container
    if !CodecSets.compatibleContainers.contains(mediaInfo.formatName) {
        decision.needsRemux = true
    }

    // Video streams
    for stream in mediaInfo.videoStreams {
        if CodecSets.compatibleVideo.contains(stream.codecName) {
            decision.streamActions[stream.index] = "copy"
        } else {
            decision.streamActions[stream.index] = "transcode"
            decision.needsTranscode = true
        }
    }

    // Audio streams
    for stream in mediaInfo.audioStreams {
        if CodecSets.compatibleAudio.contains(stream.codecName) {
            decision.streamActions[stream.index] = "copy"
        } else {
            decision.streamActions[stream.index] = "transcode"
            decision.needsTranscode = true
        }
    }

    // Subtitle streams
    for stream in mediaInfo.subtitleStreams {
        if stream.codecName == "mov_text" {
            decision.streamActions[stream.index] = "copy"
        } else if CodecSets.textSubtitles.contains(stream.codecName) {
            decision.streamActions[stream.index] = "convert_to_mov_text"
        } else {
            decision.streamActions[stream.index] = "skip"
        }
    }

    return decision
}

/// Get HD flag value for MP4 hdvd atom.
public func getHDFlag(width: Int?, height: Int?) -> Int {
    guard let h = height else { return 0 }
    if h >= 1080 { return 2 }
    if h >= 720 { return 1 }
    return 0
}
