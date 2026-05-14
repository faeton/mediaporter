// Diagnostic logging for MediaPorter.
//
// Every entry is mirrored to two sinks:
//   1. Apple Unified Logging under subsystem `md.porter.MediaPorter`. The
//      tag's prefix-before-first-dot becomes the OSLog category, so e.g.
//      `atc.MetadataSyncFinished` shows up under category `atc`. Inspect with:
//         log stream --predicate 'subsystem == "md.porter.MediaPorter"' --info
//         log show   --predicate 'subsystem == "md.porter.MediaPorter"' --info --last 1h
//   2. /tmp/mediaporter-debug.log — append-mode plaintext mirror. Persistent
//      until /tmp is cleared; convenient for `tail -f` while iterating and for
//      attaching to bug reports without needing `log show` privileges.
//
// Levels map onto OSLog's persistence model:
//   .debug, .info  → memory only by default (volatile; cheap, fine for trace).
//   .notice        → persisted to the unified-log archive (default for OSLog).
//   .error         → persisted with elevated visibility in Console / log show.
// Notice + error survive `log show --last 1h` without `--info`, so they're
// the right level for "interesting after the fact" events: recovery actions,
// timeouts, fetch failures.

import Foundation
import OSLog

public enum DebugLog {
    public static let subsystem = "md.porter.MediaPorter"

    /// Severity for a single log entry. Default for `write(_:_:)` is `.info`.
    /// Upgrade to `.notice` / `.error` for events you want to find in
    /// `log show` without `--info` (i.e. after a bug report comes in days later).
    public enum Level {
        case debug, info, notice, error
    }

    private static let fileURL = URL(fileURLWithPath: "/tmp/mediaporter-debug.log")
    private static let queue = DispatchQueue(label: "mediaporter.debuglog")
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private static let loggerLock = NSLock()
    private static var loggers: [String: Logger] = [:]

    private static func logger(for category: String) -> Logger {
        loggerLock.lock()
        defer { loggerLock.unlock() }
        if let existing = loggers[category] { return existing }
        let new = Logger(subsystem: subsystem, category: category)
        loggers[category] = new
        return new
    }

    private static func category(from tag: String) -> String {
        if let dot = tag.firstIndex(of: ".") {
            return String(tag[..<dot])
        }
        return tag
    }

    public static func write(_ tag: String, _ msg: String, level: Level = .info) {
        // Mark the interpolated values .public — these are diagnostic
        // events (file names, ATC message names, sizes), not user secrets,
        // and Logger redacts non-static interpolations to <private> by default.
        let lg = logger(for: category(from: tag))
        switch level {
        case .debug:  lg.debug ("\(tag, privacy: .public): \(msg, privacy: .public)")
        case .info:   lg.info  ("\(tag, privacy: .public): \(msg, privacy: .public)")
        case .notice: lg.notice("\(tag, privacy: .public): \(msg, privacy: .public)")
        case .error:  lg.error ("\(tag, privacy: .public): \(msg, privacy: .public)")
        }

        // Plaintext mirror — include level prefix only for non-info so the
        // common case stays identical to the legacy format (existing
        // tail -f / regex consumers keep working).
        let prefix: String = {
            switch level {
            case .info:   return ""
            case .debug:  return "DEBUG "
            case .notice: return "NOTICE "
            case .error:  return "ERROR "
            }
        }()
        let line = "[\(dateFormatter.string(from: Date()))] \(prefix)\(tag): \(msg)\n"
        queue.async {
            if let data = line.data(using: .utf8) {
                if let h = try? FileHandle(forWritingTo: fileURL) {
                    h.seekToEndOfFile()
                    h.write(data)
                    try? h.close()
                } else {
                    try? data.write(to: fileURL)
                }
            }
        }
    }

    /// Recovery actions, transient anomalies — anything worth finding in a
    /// post-mortem without `--info`. Persisted by OSLog.
    public static func notice(_ tag: String, _ msg: String) {
        write(tag, msg, level: .notice)
    }

    /// Failures: timeouts, fetch exceptions, abandoned assets. Persisted by
    /// OSLog at elevated visibility (shows in Console without filtering).
    public static func error(_ tag: String, _ msg: String) {
        write(tag, msg, level: .error)
    }

    /// Verbose trace. Off by default in `log show`; requires `--debug` or
    /// `log config --mode "level:debug"` to surface.
    public static func debug(_ tag: String, _ msg: String) {
        write(tag, msg, level: .debug)
    }

    public static func writeMultiline(_ tag: String, _ lines: [String]) {
        write(tag, lines.joined(separator: " "))
    }
}
