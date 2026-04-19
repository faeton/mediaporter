// OpenSubtitles REST API client — moviehash lookup, login, download.
//
// The API requires a free account: https://www.opensubtitles.com/consumers
//   - Api-Key header on every request
//   - POST /login once per ~24h with username/password → Bearer token
//   - POST /download with {file_id} → one-shot link → SRT bytes
//
// Moviehash algorithm matches the long-standing OpenSubtitles spec:
//   hash = file_size + sum(first 64 KB as uint64 LE) + sum(last 64 KB as uint64 LE)

import Foundation

public struct OpenSubtitlesSubtitle: Sendable {
    public let fileID: Int
    public let language: String      // ISO 639-1 like "en"
    public let release: String?      // release name (for display / debug)
    public let fromHash: Bool        // matched via moviehash (stronger than fuzzy)
}

public enum OpenSubtitlesError: LocalizedError {
    case missingCredentials
    case loginFailed(String)
    case requestFailed(String)
    case fileTooSmall

    public var errorDescription: String? {
        switch self {
        case .missingCredentials: return "OpenSubtitles: API key + username/password required"
        case .loginFailed(let m):  return "OpenSubtitles login failed: \(m)"
        case .requestFailed(let m): return "OpenSubtitles request failed: \(m)"
        case .fileTooSmall:        return "File too small for moviehash (< 128 KB)"
        }
    }
}

/// Compute the 64-bit moviehash for a video file. Returns nil if the file is
/// smaller than 128 KB (not enough for two 64 KB blocks).
public func openSubtitlesMovieHash(at url: URL) -> (hash: UInt64, size: UInt64)? {
    let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
    guard let rawSize = attrs?[.size] as? UInt64, rawSize >= 131072 else { return nil }
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }

    let block: UInt64 = 65536
    var hash: UInt64 = rawSize

    func accumulate(_ data: Data) {
        data.withUnsafeBytes { raw in
            let count = raw.count / 8
            let p = raw.bindMemory(to: UInt64.self).baseAddress!
            for i in 0..<count {
                hash = hash &+ UInt64(littleEndian: p[i])
            }
        }
    }

    try? handle.seek(toOffset: 0)
    if let first = try? handle.read(upToCount: Int(block)), first.count == Int(block) {
        accumulate(first)
    } else {
        return nil
    }

    try? handle.seek(toOffset: rawSize - block)
    if let last = try? handle.read(upToCount: Int(block)), last.count == Int(block) {
        accumulate(last)
    } else {
        return nil
    }

    return (hash, rawSize)
}

// MARK: - Language helpers

/// Map our ISO 639-2 codes (used throughout MediaPorter) to the 2-letter ISO
/// 639-1 codes OpenSubtitles expects in the `languages=` query.
private let iso2ByIso3: [String: String] = [
    "eng": "en", "rus": "ru", "ukr": "uk", "fre": "fr", "ger": "de",
    "spa": "es", "ita": "it", "por": "pt", "jpn": "ja", "kor": "ko",
    "chi": "zh", "ara": "ar", "hin": "hi", "pol": "pl", "dut": "nl",
    "swe": "sv", "nor": "no", "dan": "da", "fin": "fi", "cze": "cs",
    "tur": "tr", "tha": "th", "heb": "he", "gre": "el", "hun": "hu",
    "rum": "ro", "bul": "bg", "hrv": "hr", "srp": "sr", "slo": "sk",
    "vie": "vi", "ind": "id", "may": "ms",
]

/// Accept either "eng" or "en" and return the ISO 639-1 form OpenSubtitles wants.
public func openSubtitlesLangCode(_ any: String) -> String {
    let lower = any.lowercased()
    if lower.count == 2 { return lower }
    return iso2ByIso3[lower] ?? lower
}

/// Inverse of `openSubtitlesLangCode` — back to the 3-letter form we use
/// elsewhere (subtitle metadata, filename suffixes).
public func iso3FromIso2(_ s: String) -> String {
    let lower = s.lowercased()
    for (k, v) in iso2ByIso3 where v == lower { return k }
    return lower
}

// MARK: - Client

public actor OpenSubtitlesClient {
    public let apiKey: String
    public let username: String
    public let password: String
    private var bearerToken: String?

    public init(apiKey: String, username: String, password: String) {
        self.apiKey = apiKey
        self.username = username
        self.password = password
    }

    /// Acquire (and cache) a bearer token. Called automatically before `download`.
    public func login() async throws {
        if bearerToken != nil { return }

        var req = URLRequest(url: URL(string: "https://api.opensubtitles.com/api/v1/login")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(apiKey, forHTTPHeaderField: "Api-Key")
        req.setValue("MediaPorter v0.4", forHTTPHeaderField: "User-Agent")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "username": username,
            "password": password,
        ])

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw OpenSubtitlesError.loginFailed(body.prefix(200).description)
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let token = json?["token"] as? String else {
            throw OpenSubtitlesError.loginFailed("no token in response")
        }
        bearerToken = token
    }

    /// Search by moviehash. No login required for search — just the Api-Key.
    public func searchByHash(
        hash: UInt64, size: UInt64, languages: [String]
    ) async throws -> [OpenSubtitlesSubtitle] {
        let langs = languages.map(openSubtitlesLangCode).joined(separator: ",")
        var comps = URLComponents(string: "https://api.opensubtitles.com/api/v1/subtitles")!
        comps.queryItems = [
            URLQueryItem(name: "moviehash", value: String(format: "%016x", hash)),
            URLQueryItem(name: "moviebytesize", value: String(size)),
            URLQueryItem(name: "languages", value: langs),
        ]
        return try await runSearch(url: comps.url!)
    }

    /// Search by TMDb ID (OpenSubtitles accepts it directly on the `tmdb_id` param).
    public func searchByTMDbID(
        tmdbID: Int, languages: [String], type: String = "movie"
    ) async throws -> [OpenSubtitlesSubtitle] {
        let langs = languages.map(openSubtitlesLangCode).joined(separator: ",")
        var comps = URLComponents(string: "https://api.opensubtitles.com/api/v1/subtitles")!
        comps.queryItems = [
            URLQueryItem(name: "tmdb_id", value: String(tmdbID)),
            URLQueryItem(name: "languages", value: langs),
            URLQueryItem(name: "type", value: type),
        ]
        return try await runSearch(url: comps.url!)
    }

    private func runSearch(url: URL) async throws -> [OpenSubtitlesSubtitle] {
        var req = URLRequest(url: url)
        req.setValue(apiKey, forHTTPHeaderField: "Api-Key")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("MediaPorter v0.4", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw OpenSubtitlesError.requestFailed(body.prefix(200).description)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["data"] as? [[String: Any]] else {
            return []
        }

        var out: [OpenSubtitlesSubtitle] = []
        for r in results {
            guard let attrs = r["attributes"] as? [String: Any] else { continue }
            // attributes.files[0].file_id is the download handle.
            guard let files = attrs["files"] as? [[String: Any]],
                  let fileID = files.first?["file_id"] as? Int else { continue }
            let lang = (attrs["language"] as? String) ?? ""
            let release = attrs["release"] as? String
            let fromHash = (attrs["moviehash_match"] as? Bool) ?? false
            out.append(OpenSubtitlesSubtitle(
                fileID: fileID, language: lang, release: release, fromHash: fromHash
            ))
        }
        return out
    }

    /// Download a subtitle by file_id. Logs in if we don't have a token yet.
    /// Returns the raw bytes of the subtitle file (typically SRT).
    public func download(fileID: Int) async throws -> Data {
        try await login()
        guard let token = bearerToken else {
            throw OpenSubtitlesError.loginFailed("no token after login")
        }

        var req = URLRequest(url: URL(string: "https://api.opensubtitles.com/api/v1/download")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(apiKey, forHTTPHeaderField: "Api-Key")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("MediaPorter v0.4", forHTTPHeaderField: "User-Agent")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["file_id": fileID])

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw OpenSubtitlesError.requestFailed(body.prefix(200).description)
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let link = json?["link"] as? String, let url = URL(string: link) else {
            throw OpenSubtitlesError.requestFailed("no download link")
        }

        let (body, _) = try await URLSession.shared.data(from: url)
        return body
    }
}

// MARK: - High-level helper

/// Search OpenSubtitles for the best match per preferred language, download
/// each to `cacheDir`, and return `ExternalSubtitle` entries suitable for
/// appending to `MediaInfo.externalSubtitles`. Best match = moviehash match
/// first, otherwise the first TMDb-matched result.
///
/// Skips languages that already exist in `existingLanguages` (embedded or
/// external) so we don't duplicate what the file already ships with.
public func fetchOpenSubtitles(
    for url: URL,
    tmdbID: Int?,
    languages: [String],
    existingLanguages: Set<String>,
    cacheDir: URL,
    client: OpenSubtitlesClient
) async -> [ExternalSubtitle] {
    let wanted = languages
        .map { openSubtitlesLangCode($0) }
        .filter { lang in
            let iso3 = iso3FromIso2(lang)
            return !existingLanguages.contains(iso3) && !existingLanguages.contains(lang)
        }
    guard !wanted.isEmpty else { return [] }

    try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

    // Prefer hash-matched results when available; fall back to TMDb ID.
    var pool: [OpenSubtitlesSubtitle] = []
    if let hashInfo = openSubtitlesMovieHash(at: url) {
        pool = (try? await client.searchByHash(
            hash: hashInfo.hash, size: hashInfo.size, languages: wanted
        )) ?? []
    }
    if pool.isEmpty, let tmdbID {
        pool = (try? await client.searchByTMDbID(
            tmdbID: tmdbID, languages: wanted
        )) ?? []
    }
    guard !pool.isEmpty else { return [] }

    var out: [ExternalSubtitle] = []
    for lang in wanted {
        // Hash matches first, then whatever comes back.
        let candidates = pool
            .filter { $0.language.lowercased() == lang }
            .sorted { a, b in (a.fromHash ? 1 : 0) > (b.fromHash ? 1 : 0) }
        guard let pick = candidates.first else { continue }

        // Cache filename: {videoStem}.{iso3}.srt so repeated analyses are free
        // and scanExternalSubtitles picks up the language suffix naturally.
        let iso3 = iso3FromIso2(lang)
        let stem = url.deletingPathExtension().lastPathComponent
        let destName = "\(stem).\(iso3).srt"
        let dest = cacheDir.appendingPathComponent(destName)

        if !FileManager.default.fileExists(atPath: dest.path) {
            guard let data = try? await client.download(fileID: pick.fileID) else { continue }
            do {
                try data.write(to: dest)
            } catch { continue }
        }
        out.append(ExternalSubtitle(path: dest, language: iso3, format: "srt"))
    }
    return out
}
