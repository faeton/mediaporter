// Locate ffmpeg and ffprobe binaries on the system.

import Foundation

enum FFmpegLocator {
    private static let searchPaths = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
    ]

    private static var _ffmpeg: URL?
    private static var _ffprobe: URL?

    /// Find ffmpeg binary, searching common Homebrew/system paths then PATH.
    static var ffmpeg: URL? {
        if let cached = _ffmpeg { return cached }
        _ffmpeg = findBinary("ffmpeg")
        return _ffmpeg
    }

    /// Find ffprobe binary.
    static var ffprobe: URL? {
        if let cached = _ffprobe { return cached }
        _ffprobe = findBinary("ffprobe")
        return _ffprobe
    }

    private static func findBinary(_ name: String) -> URL? {
        let fm = FileManager.default
        // Check well-known paths first
        for dir in searchPaths {
            let path = "\(dir)/\(name)"
            if fm.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
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
            return URL(fileURLWithPath: path)
        } catch {
            return nil
        }
    }
}
