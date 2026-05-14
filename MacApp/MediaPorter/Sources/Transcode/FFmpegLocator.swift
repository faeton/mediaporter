// Locate ffmpeg and ffprobe binaries on the system.

import Foundation

enum FFmpegLocator {
    private static let searchPaths = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
    ]

    /// Where the resolved binary came from. Surfaced to the UI (banner +
    /// diagnostic info) so users can tell which build they're running and
    /// debug "wrong ffmpeg picked up" issues without spelunking otool.
    public enum Origin: Equatable {
        case bundled  // MediaPorter.app/Contents/Helpers/ — ships in the with-ffmpeg DMG
        case system   // PATH/Homebrew — user-installed
    }

    private static var _ffmpeg: (url: URL, origin: Origin)?
    private static var _ffprobe: (url: URL, origin: Origin)?

    /// Find ffmpeg binary, searching common Homebrew/system paths then PATH.
    static var ffmpeg: URL? { ffmpegResolution?.url }
    static var ffmpegOrigin: Origin? { ffmpegResolution?.origin }
    static var ffmpegResolution: (url: URL, origin: Origin)? {
        if let cached = _ffmpeg { return cached }
        _ffmpeg = findBinary("ffmpeg")
        return _ffmpeg
    }

    /// Find ffprobe binary.
    static var ffprobe: URL? { ffprobeResolution?.url }
    static var ffprobeOrigin: Origin? { ffprobeResolution?.origin }
    static var ffprobeResolution: (url: URL, origin: Origin)? {
        if let cached = _ffprobe { return cached }
        _ffprobe = findBinary("ffprobe")
        return _ffprobe
    }

    /// Drop cached lookups so a re-check reflects a freshly installed
    /// ffmpeg (e.g. user just ran `brew install ffmpeg` while the app's
    /// missing-ffmpeg banner is up). Cheap to call on a Timer.
    static func invalidateCache() {
        _ffmpeg = nil
        _ffprobe = nil
    }

    /// Bundled-ffmpeg variant ships ffmpeg + ffprobe in
    /// MediaPorter.app/Contents/Helpers/ (placed there by build-app.sh
    /// --bundle-ffmpeg). The system-ffmpeg variant simply doesn't have
    /// that directory, so this returns nil and we fall through to the
    /// PATH/Homebrew search. Same code path serves both builds.
    private static var bundledHelpersDir: URL? {
        // .bundleURL on a regular .app points at MediaPorter.app itself;
        // helpers go under Contents/Helpers/. In `swift run` (dev mode)
        // bundleURL points at a CLI binary inside .build/, and Helpers/
        // won't exist there — the nil-return path is correct.
        Bundle.main.bundleURL
            .appendingPathComponent("Contents")
            .appendingPathComponent("Helpers")
    }

    private static func findBinary(_ name: String) -> (url: URL, origin: Origin)? {
        let fm = FileManager.default
        // Bundled binary takes precedence — when shipping the with-ffmpeg
        // DMG we want exactly the codec set we built, not whatever the
        // user happens to have on PATH.
        if let helpers = bundledHelpersDir {
            let bundled = helpers.appendingPathComponent(name)
            if fm.isExecutableFile(atPath: bundled.path) {
                return (bundled, .bundled)
            }
        }
        // Check well-known paths first
        for dir in searchPaths {
            let path = "\(dir)/\(name)"
            if fm.isExecutableFile(atPath: path) {
                return (URL(fileURLWithPath: path), .system)
            }
        }
        // Fall back to `which`
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        proc.arguments = [name]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !path.isEmpty, fm.isExecutableFile(atPath: path) else { return nil }
            return (URL(fileURLWithPath: path), .system)
        } catch {
            return nil
        }
    }
}
