// Counter store for the weekly anonymous heartbeat.
//
// Lives in UserDefaults under `metricsCounters` as a `[String: Int]`. Bump
// sites are scattered across pipeline / transcode / sync / metadata code.
// Once a week, App.swift's maybeSendHeartbeat takes a snapshot, buckets each
// value (so e.g. 287 → "101-500" — keeps individual counts from acting as a
// fingerprint across weeks), folds them into Sentry tags on the heartbeat
// event, and on a 200 OK calls `reset()` to start the next window clean.
//
// Bumps run unconditionally regardless of the opt-in. We could gate them
// here, but that would require MediaPorterCore to depend on the App target's
// ConfigLoader (Privacy toggle lives there). Instead the App layer owns the
// policy: it only *sends* if the toggle is on, and it calls `reset()` when
// the user flips the toggle off so opt-out drops accumulated state locally.

import Foundation

public enum MetricsCollector {
    private static let defaultsKey = "metricsCounters"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: [String: Int] = {
        (UserDefaults.standard.dictionary(forKey: "metricsCounters") as? [String: Int]) ?? [:]
    }()

    public static func bump(_ name: String, by amount: Int = 1) {
        lock.lock(); defer { lock.unlock() }
        cached[name, default: 0] += amount
        UserDefaults.standard.set(cached, forKey: defaultsKey)
    }

    public static func snapshot() -> [String: Int] {
        lock.lock(); defer { lock.unlock() }
        return cached
    }

    public static func reset() {
        lock.lock(); defer { lock.unlock() }
        cached.removeAll()
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }

    /// Coarse buckets — keep individual counts from being a stable fingerprint
    /// across weeks. Returned as a tag-friendly string. Negative is treated as 0.
    public static func bucket(_ n: Int) -> String {
        switch n {
        case ..<1:       return "0"
        case 1:          return "1"
        case 2...5:      return "2-5"
        case 6...20:     return "6-20"
        case 21...100:   return "21-100"
        case 101...500:  return "101-500"
        default:         return "500+"
        }
    }
}
