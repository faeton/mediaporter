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

    /// Best-effort TMDb API key discovery. Returns nil if nothing is found.
    /// Order: UserDefaults → env var → ~/.config/mediaporter/config.toml → .env walk-up → ~/.env.
    static func tmdbAPIKey() -> String? {
        if let v = nonEmpty(UserDefaults.standard.string(forKey: tmdbDefaultsKey)) {
            return v
        }
        if let v = nonEmpty(ProcessInfo.processInfo.environment["TMDB_API_KEY"]) {
            return v
        }
        if let v = readFromConfigToml() { return v }
        if let v = readFromDotenvWalkUp() { return v }
        if let v = readFromHomeDotenv() { return v }
        return nil
    }

    /// Returns where the currently effective key came from — useful for the Settings UI.
    static func tmdbSource() -> TMDbKeySource {
        if nonEmpty(UserDefaults.standard.string(forKey: tmdbDefaultsKey)) != nil { return .userDefaults }
        if nonEmpty(ProcessInfo.processInfo.environment["TMDB_API_KEY"]) != nil { return .env }
        if readFromConfigToml() != nil { return .configToml }
        if readFromDotenvWalkUp() != nil { return .dotenv }
        if readFromHomeDotenv() != nil { return .homeDotenv }
        return .none
    }

    /// Persist a user-entered key to UserDefaults, or clear it if empty.
    static func saveTMDbKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: tmdbDefaultsKey)
        } else {
            UserDefaults.standard.set(trimmed, forKey: tmdbDefaultsKey)
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

    private static func readFromConfigToml() -> String? {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/mediaporter/config.toml")
        guard let text = try? String(contentsOf: path, encoding: .utf8) else { return nil }
        // Minimal TOML parse: find `tmdb_api_key = "..."` under [metadata].
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
                  line[..<eq].trimmingCharacters(in: .whitespaces) == "tmdb_api_key"
            else { continue }
            let raw = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            return nonEmpty(stripQuotes(String(raw)))
        }
        return nil
    }

    private static func readFromDotenvWalkUp() -> String? {
        var dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        for _ in 0..<12 {
            let env = dir.appendingPathComponent(".env")
            if FileManager.default.fileExists(atPath: env.path) {
                if let v = readKeyFromDotenv(at: env, key: "TMDB_API_KEY") { return v }
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        return nil
    }

    private static func readFromHomeDotenv() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".env")
        guard FileManager.default.fileExists(atPath: home.path) else { return nil }
        return readKeyFromDotenv(at: home, key: "TMDB_API_KEY")
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
