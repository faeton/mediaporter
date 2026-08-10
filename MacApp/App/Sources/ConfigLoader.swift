// Config — resolve TMDb key the same way Python's src/mediaporter/config.py does.
// Order of precedence (first win):
//   1. process env TMDB_API_KEY
//   2. ~/.config/mediaporter/config.toml → [metadata] tmdb_api_key
//   3. .env walking up from cwd (Swift Package / dev)
//   4. ~/.env

import Foundation
import MediaPorterCore

enum ConfigLoader {
    /// UserDefaults key — set by the Settings window. Takes precedence over all other sources.
    static let tmdbDefaultsKey = "tmdbAPIKey"
    static let osApiKeyDefaultsKey = "openSubtitlesAPIKey"
    static let osUsernameDefaultsKey = "openSubtitlesUsername"
    static let osPasswordDefaultsKey = "openSubtitlesPassword"
    static let osLanguagesDefaultsKey = "openSubtitlesLanguages"
    static let hwAccelDefaultsKey = "transcodeHwAccel"
    static let airplayTo4KDefaultsKey = "outputAirplayTo4K"
    static let bugsinkDSNDefaultsKey = "bugsinkDSN"
    static let heartbeatOptInDefaultsKey = "heartbeatOptIn"

    /// Whether to use Apple VideoToolbox hardware encoding. Defaults to true
    /// (preserved unless the user has explicitly disabled it in Settings).
    static func hwAccelEnabled() -> Bool {
        if UserDefaults.standard.object(forKey: hwAccelDefaultsKey) == nil { return true }
        return UserDefaults.standard.bool(forKey: hwAccelDefaultsKey)
    }

    static func saveHwAccel(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: hwAccelDefaultsKey)
    }

    /// User AirPlay/HDMIs the device to a 4K display. Inverts the downscale
    /// recommendation: keep originals instead of dropping to the device's
    /// native panel resolution. Off by default.
    static func airplayTo4K() -> Bool {
        UserDefaults.standard.bool(forKey: airplayTo4KDefaultsKey)
    }

    static func saveAirplayTo4K(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: airplayTo4KDefaultsKey)
    }

    // MARK: - Diagnostics (Bugsink)

    /// Compile-time fallback DSN. Sentry DSNs are public-by-design (they
    /// identify a project's ingest endpoint, not a secret — the same way
    /// google-analytics IDs are public), so embedding the prod DSN here is
    /// fine. Points at the self-hosted Bugsink at bugs.porter.md. Users
    /// who want their reports to go somewhere else can override via
    /// Settings → Privacy, env var, or config.toml.
    private static let defaultBugsinkDSN: String? = "https://63593fd2486448fcb2aa22be891abd24@bugs.porter.md/1"

    /// Resolved diagnostic DSN, or nil if neither user-config nor build-baked
    /// value exists. The Send Diagnostic sheet shows "not configured" when nil.
    static func bugsinkDSN() -> String? {
        if let v = nonEmpty(UserDefaults.standard.string(forKey: bugsinkDSNDefaultsKey)) { return v }
        if let v = nonEmpty(ProcessInfo.processInfo.environment["BUGSINK_DSN"]) { return v }
        if let v = readFromConfigToml(key: "bugsink_dsn") { return v }
        if let v = readFromDotenvWalkUp(key: "BUGSINK_DSN") { return v }
        if let v = readFromHomeDotenv(key: "BUGSINK_DSN") { return v }
        return defaultBugsinkDSN
    }

    static func saveBugsinkDSN(_ dsn: String) {
        save(dsn, to: bugsinkDSNDefaultsKey)
    }

    /// Whether the user has opted in to a weekly anonymized heartbeat
    /// (version + OS + device class, no UDIDs / filenames). Default: false.
    static func heartbeatOptIn() -> Bool {
        UserDefaults.standard.bool(forKey: heartbeatOptInDefaultsKey)
    }

    static func saveHeartbeatOptIn(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: heartbeatOptInDefaultsKey)
        if !enabled {
            // Opt-out drops locally accumulated counters so the next opt-in
            // starts from zero rather than backfilling whatever ran while the
            // user wasn't sending. Also: nothing should linger in storage
            // once the user said no.
            MetricsCollector.reset()
        }
    }

    /// Best-effort TMDb API key discovery. Returns nil if nothing is found.
    /// Resolution lives in `Credentials` (core) so the CLI and the on-device
    /// test harnesses resolve the exact same key the GUI does.
    static func tmdbAPIKey() -> String? {
        Credentials.tmdbAPIKey()
    }

    /// Returns where the currently effective key came from — useful for the Settings UI.
    static func tmdbSource() -> TMDbKeySource {
        TMDbKeySource(Credentials.tmdbSource())
    }

    /// Persist a user-entered key to UserDefaults, or clear it if empty.
    static func saveTMDbKey(_ key: String) {
        save(key, to: tmdbDefaultsKey)
    }

    // MARK: - OpenSubtitles

    static func openSubtitlesAPIKey() -> String? { Credentials.openSubtitlesAPIKey() }
    static func openSubtitlesUsername() -> String? { Credentials.openSubtitlesUsername() }
    static func openSubtitlesPassword() -> String? { Credentials.openSubtitlesPassword() }
    /// Comma-separated ISO 639-1 or 639-2 codes (e.g. "en,ru"). Empty → feature off.
    static func openSubtitlesLanguages() -> String { Credentials.openSubtitlesLanguages() }

    /// Where the API key is currently coming from — used to show a provenance
    /// hint in Settings (e.g. "from project .env" vs "set in app").
    static func openSubtitlesSource() -> TMDbKeySource {
        TMDbKeySource(Credentials.openSubtitlesSource())
    }

    static func saveOpenSubtitlesCreds(apiKey: String, username: String, password: String, languages: String) {
        save(apiKey, to: osApiKeyDefaultsKey)
        save(username, to: osUsernameDefaultsKey)
        save(password, to: osPasswordDefaultsKey)
        save(languages, to: osLanguagesDefaultsKey)
    }

    static func openSubtitlesEnabled() -> Bool { Credentials.openSubtitlesEnabled() }

    private static func save(_ value: String, to key: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: key)
        } else {
            UserDefaults.standard.set(trimmed, forKey: key)
        }
    }
}

enum TMDbKeySource {
    case none, userDefaults, env, configToml, dotenv, homeDotenv

    /// Bridge from the core resolver's enum. `.appDefaults` can't occur in
    /// the app itself (its own defaults ARE the app domain), so it folds
    /// into `.userDefaults`.
    init(_ source: Credentials.Source) {
        switch source {
        case .none:         self = .none
        case .userDefaults: self = .userDefaults
        case .appDefaults:  self = .userDefaults
        case .env:          self = .env
        case .configToml:   self = .configToml
        case .dotenv:       self = .dotenv
        case .homeDotenv:   self = .homeDotenv
        }
    }

    var label: String {
        switch self {
        case .none:         return "not set"
        case .userDefaults: return "set in app"
        case .env:          return "from TMDB_API_KEY env var"
        case .configToml:   return "from ~/.config/mediaporter/config.toml"
        case .dotenv:       return "from project .env"
        case .homeDotenv:   return "from ~/.env"
        }
    }
}

extension ConfigLoader {

    // MARK: - Sources

    private static func readFromConfigToml(key: String) -> String? {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/mediaporter/config.toml")
        guard let text = try? String(contentsOf: path, encoding: .utf8) else { return nil }
        var inMetadata = false
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("[") {
                inMetadata = line.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                    .trimmingCharacters(in: .whitespaces) == "metadata"
                continue
            }
            guard inMetadata,
                  let eq = line.firstIndex(of: "="),
                  line[..<eq].trimmingCharacters(in: .whitespaces) == key
            else { continue }
            let raw = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            return nonEmpty(stripQuotes(String(raw)))
        }
        return nil
    }

    private static func readFromDotenvWalkUp(key: String) -> String? {
        var dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        for _ in 0..<12 {
            let env = dir.appendingPathComponent(".env")
            if FileManager.default.fileExists(atPath: env.path) {
                if let v = readKeyFromDotenv(at: env, key: key) { return v }
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        return nil
    }

    private static func readFromHomeDotenv(key: String) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".env")
        guard FileManager.default.fileExists(atPath: home.path) else { return nil }
        return readKeyFromDotenv(at: home, key: key)
    }

    // MARK: - Helpers

    private static func readKeyFromDotenv(at url: URL, key: String) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let k = line[..<eq].trimmingCharacters(in: .whitespaces)
            guard k == key else { continue }
            let raw = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            return nonEmpty(stripQuotes(String(raw)))
        }
        return nil
    }

    private static func stripQuotes(_ s: String) -> String {
        var v = s
        if v.hasPrefix("\"") && v.hasSuffix("\"") && v.count >= 2 {
            v = String(v.dropFirst().dropLast())
        } else if v.hasPrefix("'") && v.hasSuffix("'") && v.count >= 2 {
            v = String(v.dropFirst().dropLast())
        }
        return v
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }
}
