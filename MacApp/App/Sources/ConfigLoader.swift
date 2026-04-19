// Config — resolve TMDb key the same way Python's src/mediaporter/config.py does.
// Order of precedence (first win):
//   1. process env TMDB_API_KEY
//   2. ~/.config/mediaporter/config.toml → [metadata] tmdb_api_key
//   3. .env walking up from cwd (Swift Package / dev)
//   4. ~/.env

import Foundation

enum ConfigLoader {
    /// UserDefaults key — set by the Settings window. Takes precedence over all other sources.
    static let tmdbDefaultsKey = "tmdbAPIKey"
    static let osApiKeyDefaultsKey = "openSubtitlesAPIKey"
    static let osUsernameDefaultsKey = "openSubtitlesUsername"
    static let osPasswordDefaultsKey = "openSubtitlesPassword"
    static let osLanguagesDefaultsKey = "openSubtitlesLanguages"
    static let hwAccelDefaultsKey = "transcodeHwAccel"

    /// Whether to use Apple VideoToolbox hardware encoding. Defaults to true
    /// (preserved unless the user has explicitly disabled it in Settings).
    static func hwAccelEnabled() -> Bool {
        if UserDefaults.standard.object(forKey: hwAccelDefaultsKey) == nil { return true }
        return UserDefaults.standard.bool(forKey: hwAccelDefaultsKey)
    }

    static func saveHwAccel(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: hwAccelDefaultsKey)
    }

    /// Best-effort TMDb API key discovery. Returns nil if nothing is found.
    /// Order: UserDefaults → env var → ~/.config/mediaporter/config.toml → .env walk-up → ~/.env.
    static func tmdbAPIKey() -> String? {
        if let v = nonEmpty(UserDefaults.standard.string(forKey: tmdbDefaultsKey)) {
            return v
        }
        if let v = nonEmpty(ProcessInfo.processInfo.environment["TMDB_API_KEY"]) {
            return v
        }
        if let v = readFromConfigToml(key: "tmdb_api_key") { return v }
        if let v = readFromDotenvWalkUp(key: "TMDB_API_KEY") { return v }
        if let v = readFromHomeDotenv(key: "TMDB_API_KEY") { return v }
        return nil
    }

    /// Returns where the currently effective key came from — useful for the Settings UI.
    static func tmdbSource() -> TMDbKeySource {
        if nonEmpty(UserDefaults.standard.string(forKey: tmdbDefaultsKey)) != nil { return .userDefaults }
        if nonEmpty(ProcessInfo.processInfo.environment["TMDB_API_KEY"]) != nil { return .env }
        if readFromConfigToml(key: "tmdb_api_key") != nil { return .configToml }
        if readFromDotenvWalkUp(key: "TMDB_API_KEY") != nil { return .dotenv }
        if readFromHomeDotenv(key: "TMDB_API_KEY") != nil { return .homeDotenv }
        return .none
    }

    /// Persist a user-entered key to UserDefaults, or clear it if empty.
    static func saveTMDbKey(_ key: String) {
        save(key, to: tmdbDefaultsKey)
    }

    // MARK: - OpenSubtitles

    static func openSubtitlesAPIKey() -> String? {
        if let v = nonEmpty(UserDefaults.standard.string(forKey: osApiKeyDefaultsKey)) { return v }
        if let v = nonEmpty(ProcessInfo.processInfo.environment["OPENSUBTITLES_API_KEY"]) { return v }
        if let v = readFromConfigToml(key: "opensubtitles_api_key") { return v }
        if let v = readFromDotenvWalkUp(key: "OPENSUBTITLES_API_KEY") { return v }
        if let v = readFromHomeDotenv(key: "OPENSUBTITLES_API_KEY") { return v }
        return nil
    }
    static func openSubtitlesUsername() -> String? {
        if let v = nonEmpty(UserDefaults.standard.string(forKey: osUsernameDefaultsKey)) { return v }
        if let v = nonEmpty(ProcessInfo.processInfo.environment["OPENSUBTITLES_USERNAME"]) { return v }
        if let v = readFromConfigToml(key: "opensubtitles_username") { return v }
        if let v = readFromDotenvWalkUp(key: "OPENSUBTITLES_USERNAME") { return v }
        if let v = readFromHomeDotenv(key: "OPENSUBTITLES_USERNAME") { return v }
        return nil
    }
    static func openSubtitlesPassword() -> String? {
        if let v = nonEmpty(UserDefaults.standard.string(forKey: osPasswordDefaultsKey)) { return v }
        if let v = nonEmpty(ProcessInfo.processInfo.environment["OPENSUBTITLES_PASSWORD"]) { return v }
        if let v = readFromConfigToml(key: "opensubtitles_password") { return v }
        if let v = readFromDotenvWalkUp(key: "OPENSUBTITLES_PASSWORD") { return v }
        if let v = readFromHomeDotenv(key: "OPENSUBTITLES_PASSWORD") { return v }
        return nil
    }
    /// Comma-separated ISO 639-1 or 639-2 codes (e.g. "en,ru"). Empty → feature off.
    static func openSubtitlesLanguages() -> String {
        if let v = nonEmpty(UserDefaults.standard.string(forKey: osLanguagesDefaultsKey)) { return v }
        if let v = nonEmpty(ProcessInfo.processInfo.environment["OPENSUBTITLES_LANGUAGES"]) { return v }
        if let v = readFromConfigToml(key: "opensubtitles_languages") { return v }
        if let v = readFromDotenvWalkUp(key: "OPENSUBTITLES_LANGUAGES") { return v }
        if let v = readFromHomeDotenv(key: "OPENSUBTITLES_LANGUAGES") { return v }
        return ""
    }

    /// Where the API key is currently coming from — used to show a provenance
    /// hint in Settings (e.g. "from project .env" vs "set in app").
    static func openSubtitlesSource() -> TMDbKeySource {
        if nonEmpty(UserDefaults.standard.string(forKey: osApiKeyDefaultsKey)) != nil { return .userDefaults }
        if nonEmpty(ProcessInfo.processInfo.environment["OPENSUBTITLES_API_KEY"]) != nil { return .env }
        if readFromConfigToml(key: "opensubtitles_api_key") != nil { return .configToml }
        if readFromDotenvWalkUp(key: "OPENSUBTITLES_API_KEY") != nil { return .dotenv }
        if readFromHomeDotenv(key: "OPENSUBTITLES_API_KEY") != nil { return .homeDotenv }
        return .none
    }

    static func saveOpenSubtitlesCreds(apiKey: String, username: String, password: String, languages: String) {
        save(apiKey, to: osApiKeyDefaultsKey)
        save(username, to: osUsernameDefaultsKey)
        save(password, to: osPasswordDefaultsKey)
        save(languages, to: osLanguagesDefaultsKey)
    }

    static func openSubtitlesEnabled() -> Bool {
        guard let k = openSubtitlesAPIKey(), !k.isEmpty,
              let u = openSubtitlesUsername(), !u.isEmpty,
              let p = openSubtitlesPassword(), !p.isEmpty else { return false }
        _ = p
        return !openSubtitlesLanguages().isEmpty
    }

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
