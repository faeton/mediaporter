// Shared credential resolution for TMDb + OpenSubtitles.
//
// Lives in the core library rather than the app target so the CLI
// (`mediaporterctl sync`, `smoke-test`, `idle-test`) resolves the same keys
// the GUI uses. Before this, ConfigLoader was app-only and read
// `UserDefaults.standard` — which for the CLI is the `mediaporterctl`
// domain, not the app's — so CLI runs silently had no TMDb enrichment and
// no subtitle fetch, and test syncs didn't exercise the metadata path at all.
//
// Precedence (first win), matching Python's src/mediaporter/config.py plus
// the app-domain hop:
//   1. this process's UserDefaults          (the GUI writes here)
//   2. the MediaPorter app's UserDefaults   (so other binaries inherit them)
//   3. process environment
//   4. ~/.config/mediaporter/config.toml → [metadata]
//   5. .env walking up from cwd (Swift Package / dev)
//   6. ~/.env

import Foundation

public enum Credentials {
    /// Defaults domain the SwiftUI app writes to. Read as a fallback so a key
    /// typed into Settings is visible to the CLI and the test harnesses.
    public static let appDefaultsDomain = "md.porter.MediaPorter"

    // Defaults keys — shared with the app's ConfigLoader.
    public static let tmdbDefaultsKey = "tmdbAPIKey"
    public static let osApiKeyDefaultsKey = "openSubtitlesAPIKey"
    public static let osUsernameDefaultsKey = "openSubtitlesUsername"
    public static let osPasswordDefaultsKey = "openSubtitlesPassword"
    public static let osLanguagesDefaultsKey = "openSubtitlesLanguages"

    public enum Source {
        case none, userDefaults, appDefaults, env, configToml, dotenv, homeDotenv

        public var label: String {
            switch self {
            case .none:         return "not set"
            case .userDefaults: return "set in app"
            case .appDefaults:  return "from the MediaPorter app's settings"
            case .env:          return "from environment"
            case .configToml:   return "from ~/.config/mediaporter/config.toml"
            case .dotenv:       return "from project .env"
            case .homeDotenv:   return "from ~/.env"
            }
        }
    }

    // MARK: - Resolution

    public static func tmdbAPIKey() -> String? {
        resolve(defaultsKey: tmdbDefaultsKey, env: "TMDB_API_KEY", toml: "tmdb_api_key")
    }

    public static func openSubtitlesAPIKey() -> String? {
        resolve(defaultsKey: osApiKeyDefaultsKey,
                env: "OPENSUBTITLES_API_KEY", toml: "opensubtitles_api_key")
    }

    public static func openSubtitlesUsername() -> String? {
        resolve(defaultsKey: osUsernameDefaultsKey,
                env: "OPENSUBTITLES_USERNAME", toml: "opensubtitles_username")
    }

    public static func openSubtitlesPassword() -> String? {
        resolve(defaultsKey: osPasswordDefaultsKey,
                env: "OPENSUBTITLES_PASSWORD", toml: "opensubtitles_password")
    }

    /// Comma-separated ISO 639-1/639-2 codes (e.g. "en,ru"). Empty → feature off.
    public static func openSubtitlesLanguages() -> String {
        resolve(defaultsKey: osLanguagesDefaultsKey,
                env: "OPENSUBTITLES_LANGUAGES", toml: "opensubtitles_languages") ?? ""
    }

    /// Where the effective value comes from — drives the Settings provenance
    /// hint and the CLI's one-line "using TMDb key (…)" note.
    public static func source(defaultsKey: String, env: String, toml: String) -> Source {
        if nonEmpty(UserDefaults.standard.string(forKey: defaultsKey)) != nil { return .userDefaults }
        if nonEmpty(appDefaults()?.string(forKey: defaultsKey)) != nil { return .appDefaults }
        if nonEmpty(ProcessInfo.processInfo.environment[env]) != nil { return .env }
        if readFromConfigToml(key: toml) != nil { return .configToml }
        if readFromDotenvWalkUp(key: env) != nil { return .dotenv }
        if readFromHomeDotenv(key: env) != nil { return .homeDotenv }
        return .none
    }

    public static func tmdbSource() -> Source {
        source(defaultsKey: tmdbDefaultsKey, env: "TMDB_API_KEY", toml: "tmdb_api_key")
    }

    public static func openSubtitlesSource() -> Source {
        source(defaultsKey: osApiKeyDefaultsKey,
               env: "OPENSUBTITLES_API_KEY", toml: "opensubtitles_api_key")
    }

    public static func openSubtitlesEnabled() -> Bool {
        guard let k = openSubtitlesAPIKey(), !k.isEmpty,
              let u = openSubtitlesUsername(), !u.isEmpty,
              let p = openSubtitlesPassword(), !p.isEmpty else { return false }
        return !openSubtitlesLanguages().trimmingCharacters(in: .whitespaces).isEmpty
    }

    private static func resolve(defaultsKey: String, env: String, toml: String) -> String? {
        if let v = nonEmpty(UserDefaults.standard.string(forKey: defaultsKey)) { return v }
        if let v = nonEmpty(appDefaults()?.string(forKey: defaultsKey)) { return v }
        if let v = nonEmpty(ProcessInfo.processInfo.environment[env]) { return v }
        if let v = readFromConfigToml(key: toml) { return v }
        if let v = readFromDotenvWalkUp(key: env) { return v }
        if let v = readFromHomeDotenv(key: env) { return v }
        return nil
    }

    /// nil when we already ARE the app (its keys are in `.standard`), so the
    /// GUI's own lookups don't pay for a second suite.
    private static func appDefaults() -> UserDefaults? {
        guard Bundle.main.bundleIdentifier != appDefaultsDomain else { return nil }
        return UserDefaults(suiteName: appDefaultsDomain)
    }

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
