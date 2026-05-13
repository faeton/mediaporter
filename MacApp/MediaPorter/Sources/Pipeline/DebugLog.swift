// Temporary file-based debug log for diagnosing sync issues.
// Writes append-mode to /tmp/mediaporter-debug.log so we can inspect the
// ffmpeg invocations and AFC paths after a run. Survives across launches
// (until macOS clears /tmp). Safe to remove once the JJK / Violet
// Evergarden playback bugs are root-caused.

import Foundation

public enum DebugLog {
    private static let url = URL(fileURLWithPath: "/tmp/mediaporter-debug.log")
    private static let queue = DispatchQueue(label: "mediaporter.debuglog")
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    public static func write(_ tag: String, _ msg: String) {
        let line = "[\(dateFormatter.string(from: Date()))] \(tag): \(msg)\n"
        queue.async {
            if let data = line.data(using: .utf8) {
                if let h = try? FileHandle(forWritingTo: url) {
                    h.seekToEndOfFile()
                    h.write(data)
                    try? h.close()
                } else {
                    try? data.write(to: url)
                }
            }
        }
    }

    public static func writeMultiline(_ tag: String, _ lines: [String]) {
        write(tag, lines.joined(separator: " "))
    }
}
