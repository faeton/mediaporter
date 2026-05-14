// Launch-time precondition checks for external tools the pipeline depends on.
//
// Right now: ffmpeg + ffprobe. Two distribution variants ship: the
// "with-ffmpeg" DMG bundles them under Contents/Helpers/; the regular DMG
// expects them on PATH (typically `brew install ffmpeg`). The app is
// universal — same binary in both DMGs — and reports `FFmpegSource` to
// surface which path it picked plus a persistent banner if neither exists.

import Foundation

/// The state of ffmpeg/ffprobe availability. Drives:
///   • the persistent missing-ffmpeg banner in ContentView,
///   • the diagnostic-info block in BugReporter,
///   • per-pipeline-step error messaging.
public enum FFmpegSource: Equatable {
    /// Ships in MediaPorter.app/Contents/Helpers/ (with-ffmpeg DMG).
    case bundled(ffmpeg: URL, ffprobe: URL)
    /// User installed via Homebrew or otherwise put on PATH.
    case system(ffmpeg: URL, ffprobe: URL)
    /// Neither bundled nor on PATH. Pipeline will fail at analyze.
    case missing

    public var isAvailable: Bool {
        if case .missing = self { return false }
        return true
    }

    public var ffmpegPath: String? {
        switch self {
        case .bundled(let f, _), .system(let f, _): return f.path
        case .missing: return nil
        }
    }

    public var ffprobePath: String? {
        switch self {
        case .bundled(_, let p), .system(_, let p): return p.path
        case .missing: return nil
        }
    }

    /// Short human label. Used in the diagnostic-info block.
    public var label: String {
        switch self {
        case .bundled: return "bundled"
        case .system:  return "system"
        case .missing: return "missing"
        }
    }
}

public enum Prerequisites {
    /// Probe the current ffmpeg state. Cheap; FFmpegLocator caches the
    /// resolved path. Call `FFmpegLocator.invalidateCache()` first when
    /// re-checking after a possible install (e.g. on a recovery timer).
    public static var ffmpegSource: FFmpegSource {
        guard
            let ff = FFmpegLocator.ffmpegResolution,
            let pr = FFmpegLocator.ffprobeResolution
        else {
            return .missing
        }
        // Pipeline assumes ffmpeg + ffprobe come as a pair; if they came
        // from different origins (e.g. bundled ffmpeg but system ffprobe
        // because the bundled one was deleted), report system since that's
        // the path that fully exists.
        if ff.origin == .bundled && pr.origin == .bundled {
            return .bundled(ffmpeg: ff.url, ffprobe: pr.url)
        }
        return .system(ffmpeg: ff.url, ffprobe: pr.url)
    }

    /// True if both ffmpeg and ffprobe are findable. Convenience wrapper
    /// around `ffmpegSource.isAvailable`.
    public static var ffmpegAvailable: Bool {
        ffmpegSource.isAvailable
    }

    /// Resolved absolute path to ffmpeg, or nil if not findable.
    public static var ffmpegPath: String? { ffmpegSource.ffmpegPath }

    /// Resolved absolute path to ffprobe, or nil if not findable.
    public static var ffprobePath: String? { ffmpegSource.ffprobePath }
}
