// Launch-time precondition checks for external tools the pipeline depends on.
//
// Right now: ffmpeg + ffprobe (planned to be bundled in a future release —
// see CLAUDE.md roadmap #1. Until then, the app shells out to whatever's on
// PATH or in a known Homebrew prefix, so we surface a clear "install this
// first" dialog at launch instead of letting analyze fail per-file with
// confusing error text).

import Foundation

public enum Prerequisites {
    /// True if both ffmpeg and ffprobe are findable. False means analyze and
    /// transcode will both throw per-file errors — App.swift uses this at
    /// launch to show a dependency-missing dialog before the user wastes
    /// time dropping files.
    ///
    /// Note: FFmpegLocator doesn't cache nil results, so if the user installs
    /// ffmpeg while the app is running, the next pipeline call will pick it
    /// up — no relaunch needed.
    public static var ffmpegAvailable: Bool {
        FFmpegLocator.ffmpeg != nil && FFmpegLocator.ffprobe != nil
    }

    /// Resolved absolute path to ffmpeg, or nil if not findable. Used by the
    /// Help → Copy Diagnostic Info / Report a Bug actions to surface where
    /// the binary came from (bundled / brew / not found).
    public static var ffmpegPath: String? { FFmpegLocator.ffmpeg?.path }

    /// Resolved absolute path to ffprobe, or nil if not findable.
    public static var ffprobePath: String? { FFmpegLocator.ffprobe?.path }
}
