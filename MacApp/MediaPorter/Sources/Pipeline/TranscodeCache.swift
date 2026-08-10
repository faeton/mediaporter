// Reuse finished transcodes across runs instead of re-encoding them.
//
// A run that dies after encoding but before (or during) upload leaves its
// finished .m4v files in the tempdir. They are perfectly good output — often
// tens of gigabytes of it — but nothing could ever use them again: outputs are
// named by a fresh UUID every run, so re-adding the same source file produced
// a new job with no way to recognise that its transcode already existed on
// disk. The leftover banner's only offer was Discard, and "retaining
// transcodes" bought nothing.
//
// This index closes that loop. It maps source identity + encode settings to a
// finished output, so re-dropping a file after a crash, a restart, or a failed
// sync adopts the existing encode and jumps straight to .ready.
//
// Correctness rests on four independent guards, all of which must hold:
//   1. the source is byte-for-byte the same file (path + size + mtime),
//   2. every setting that affects ffmpeg's output is unchanged (fingerprint),
//   3. the output still exists,
//   4. the output is exactly the size it was when we recorded it.
// (4) is what rejects the truncated debris a killed ffmpeg leaves behind — the
// files with no `moov` atom that `OrphanRecovery` can't probe.
//
// Deliberately NOT keyed on content hash: hashing a 2.6 GB source to decide
// whether to skip a 30-second stream copy costs more than the work it saves.

import Foundation
import CryptoKit

public enum TranscodeCache {
    private static let defaultsKey = "transcodeCache"

    /// Same suite hop as `StuckAssetLedger` — the CLI and the GUI must share
    /// one index, and `UserDefaults(suiteName:)` returns nil for your own
    /// bundle id.
    private static var store: UserDefaults {
        guard Bundle.main.bundleIdentifier != Credentials.appDefaultsDomain else {
            return .standard
        }
        return UserDefaults(suiteName: Credentials.appDefaultsDomain) ?? .standard
    }

    struct Entry: Codable {
        let sourceSize: Int64
        let sourceModified: Double
        let fingerprint: String
        let outputPath: String
        let outputSize: Int64
    }

    private static func load() -> [String: Entry] {
        guard let data = store.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([String: Entry].self, from: data)
        else { return [:] }
        return decoded
    }

    private static func save(_ v: [String: Entry]) {
        guard let data = try? JSONEncoder().encode(v) else { return }
        store.set(data, forKey: defaultsKey)
    }

    /// (size, mtime) for a file, or nil if it's gone.
    private static func stat(_ url: URL) -> (size: Int64, modified: Double)? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = a[.size] as? Int64 else { return nil }
        let mod = (a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return (size, mod)
    }

    /// A finished output for this exact source + settings, or nil.
    public static func lookup(source: URL, fingerprint: String) -> URL? {
        let index = load()
        guard let entry = index[source.standardizedFileURL.path] else { return nil }
        guard entry.fingerprint == fingerprint else { return nil }

        // Source must be unchanged — re-encoding a file the user replaced in
        // place would otherwise be skipped silently.
        guard let src = stat(source),
              src.size == entry.sourceSize,
              abs(src.modified - entry.sourceModified) < 1.0 else { return nil }

        let output = URL(fileURLWithPath: entry.outputPath)
        guard let out = stat(output), out.size == entry.outputSize else { return nil }
        return output
    }

    /// Remember a finished output. Call AFTER tagging — `Tagger.tag` rewrites
    /// the file, so a size recorded before it would never match on lookup.
    public static func record(source: URL, fingerprint: String, output: URL) {
        guard let src = stat(source), let out = stat(output) else { return }
        var index = load()
        index[source.standardizedFileURL.path] = Entry(
            sourceSize: src.size,
            sourceModified: src.modified,
            fingerprint: fingerprint,
            outputPath: output.path,
            outputSize: out.size
        )
        save(index)
    }

    /// Drop entries whose output has vanished (temp cleared, user discarded).
    /// Cheap — a stat per entry — and keeps the index from growing without
    /// bound across sessions.
    public static func prune() {
        let index = load()
        let alive = index.filter { FileManager.default.fileExists(atPath: $0.value.outputPath) }
        if alive.count != index.count {
            save(alive)
            DebugLog.notice(
                "transcodeCache.prune",
                "dropped \(index.count - alive.count) stale entr(ies), \(alive.count) left"
            )
        }
    }

    /// Forget everything. Used by Discard — those outputs are about to be
    /// deleted, so the entries pointing at them are dead.
    public static func forgetAll() {
        store.removeObject(forKey: defaultsKey)
    }

    /// Stable digest of the inputs that change ffmpeg's output.
    ///
    /// Must be stable ACROSS PROCESSES, which rules out Swift's `hashValue` —
    /// `Hasher` is randomly seeded per launch, so a cache keyed on it would
    /// miss every time and silently do nothing.
    public static func fingerprint(_ parts: [String]) -> String {
        let joined = parts.joined(separator: "\u{1F}")
        let digest = SHA256.hash(data: Data(joined.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
