// On-disk cache for TMDb responses.
//
// The URLSession backing TMDbClient is `.ephemeral`, which means it keeps no
// disk cache at all: every app launch re-fetched every search, every show,
// every episode list, every poster. That's invisible in normal use (a handful
// of files, once) and very visible during development — re-analysing the same
// 39-file batch across a dozen restarts replays hundreds of identical queries
// against a rate-limited public API.
//
// Rolled by hand rather than handing URLSession a URLCache because we want a
// TTL WE choose. TMDb's own cache headers are short, and the data we read
// (titles, air dates, poster paths for released material) is effectively
// immutable — a week-old search result is not meaningfully staler than a fresh
// one, and being wrong about it costs nothing a re-run can't fix.
//
// The cache key deliberately excludes `api_key`: it is a credential, it must
// not be written to disk in a filename, and rotating it should not throw away
// a valid cache.

import Foundation
import CryptoKit

public enum TMDbCache {
    /// Search/detail JSON. A week — long enough to cover a development
    /// session or a weekend of imports, short enough that newly-added TMDb
    /// entries (a 2026 release getting its poster) show up without a reset.
    static let jsonTTL: TimeInterval = 7 * 24 * 3600

    /// Poster images. TMDb poster paths are content-addressed — a given path
    /// never changes bytes — so this is bounded by disk hygiene, not staleness.
    static let posterTTL: TimeInterval = 30 * 24 * 3600

    private static let dir: URL? = {
        guard let base = FileManager.default.urls(
            for: .cachesDirectory, in: .userDomainMask
        ).first else { return nil }
        let d = base.appendingPathComponent("MediaPorter/tmdb", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    /// Strip the credential, keep everything else that identifies the request.
    /// Query items are sorted so parameter order can't split the cache.
    private static func key(for url: URL) -> String {
        var canonical = url.absoluteString
        if var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            comps.queryItems = comps.queryItems?
                .filter { $0.name != "api_key" }
                .sorted { $0.name < $1.name }
            canonical = comps.url?.absoluteString ?? canonical
        }
        let digest = SHA256.hash(data: Data(canonical.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func file(_ url: URL, ext: String) -> URL? {
        dir?.appendingPathComponent("\(key(for: url)).\(ext)")
    }

    static func read(_ url: URL, ext: String, ttl: TimeInterval) -> Data? {
        guard let f = file(url, ext: ext),
              let attrs = try? FileManager.default.attributesOfItem(atPath: f.path),
              let modified = attrs[.modificationDate] as? Date,
              Date().timeIntervalSince(modified) < ttl,
              let data = try? Data(contentsOf: f),
              !data.isEmpty
        else { return nil }
        return data
    }

    static func write(_ data: Data, for url: URL, ext: String) {
        guard !data.isEmpty, let f = file(url, ext: ext) else { return }
        try? data.write(to: f, options: .atomic)
    }

    /// Delete everything. Exposed so a user who suspects a bad cached match
    /// has a way out that doesn't involve finding the directory by hand.
    public static func clear() {
        guard let dir else { return }
        let items = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        )) ?? []
        for f in items { try? FileManager.default.removeItem(at: f) }
        DebugLog.notice("tmdb.cache", "cleared \(items.count) cached response(s)")
    }

    /// Drop entries past their TTL. Cheap; called once at startup.
    public static func prune() {
        guard let dir else { return }
        let items = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        var removed = 0
        for f in items {
            let ttl = f.pathExtension == "img" ? posterTTL : jsonTTL
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: f.path),
                  let modified = attrs[.modificationDate] as? Date,
                  Date().timeIntervalSince(modified) >= ttl else { continue }
            try? FileManager.default.removeItem(at: f)
            removed += 1
        }
        if removed > 0 {
            DebugLog.notice("tmdb.cache", "pruned \(removed) expired entr(ies)")
        }
    }
}
