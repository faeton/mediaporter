// Codec compatibility analysis for iPad — decide copy vs transcode per stream.

import Foundation

// MARK: - Compatible Codecs

enum CodecSets {
    static let compatibleVideo: Set<String> = ["h264", "hevc", "h265"]
    static let compatibleAudio: Set<String> = ["aac", "ac3", "eac3", "alac", "mp3"]
    static let textSubtitles: Set<String> = ["subrip", "srt", "ass", "ssa", "mov_text", "webvtt"]
    static let bitmapSubtitles: Set<String> = ["hdmv_pgs_subtitle", "dvd_subtitle", "dvb_subtitle", "pgssub"]
    static let compatibleContainers: Set<String> = ["mov", "mp4", "m4v", "mov,mp4,m4a,3gp,3g2,mj2"]
}

// MARK: - Resolution Limit

enum ResolutionLimit: String, CaseIterable, Identifiable, Comparable {
    case sd = "480p"
    case hd = "720p"
    case fhd = "1080p"
    case uhd4k = "4K (2160p)"
    case original = "Original"

    var id: String { rawValue }

    /// Max height for this limit, nil = no limit.
    var maxHeight: Int? {
        switch self {
        case .sd: return 480
        case .hd: return 720
        case .fhd: return 1080
        case .uhd4k: return 2160
        case .original: return nil
        }
    }

    private var sortOrder: Int {
        switch self {
        case .sd: return 0
        case .hd: return 1
        case .fhd: return 2
        case .uhd4k: return 3
        case .original: return 4
        }
    }

    static func < (lhs: ResolutionLimit, rhs: ResolutionLimit) -> Bool {
        lhs.sortOrder < rhs.sortOrder
    }

    /// Whether this limit would actually downscale from the given height.
    func wouldDownscale(from sourceHeight: Int?) -> Bool {
        guard let max = maxHeight, let src = sourceHeight else { return false }
        return src > max
    }

    /// Options that make sense for a given source height (no options above source res).
    static func availableOptions(sourceHeight: Int?) -> [ResolutionLimit] {
        guard let src = sourceHeight, src > 0 else { return [.original] }
        var options: [ResolutionLimit] = []
        // Add downscale options that are smaller than source
        for limit in [ResolutionLimit.sd, .hd, .fhd, .uhd4k] {
            if let max = limit.maxHeight, max < src {
                options.append(limit)
            }
        }
        // "Original" means keep source resolution (always available as the top option)
        options.append(.original)
        return options
    }

    /// Label showing the actual source resolution for "Original".
    func label(sourceHeight: Int?) -> String {
        if self == .original, let h = sourceHeight {
            return "Original (\(h)p)"
        }
        return rawValue
    }
}

// MARK: - Transcode Decision

struct TranscodeDecision {
    /// Per stream index: "copy", "transcode", "convert_to_mov_text", "skip"
    var streamActions: [Int: String] = [:]
    var needsTranscode: Bool = false
    var needsRemux: Bool = false
    var resolutionLimit: ResolutionLimit = .original
    var needsDownscale: Bool = false
}

/// Evaluate what needs to happen to make a file iPad-compatible.
func evaluateCompatibility(mediaInfo: MediaInfo) -> TranscodeDecision {
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
func getHDFlag(width: Int?, height: Int?) -> Int {
    guard let h = height else { return 0 }
    if h >= 1080 { return 2 }
    if h >= 720 { return 1 }
    return 0
}
