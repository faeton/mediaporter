// External-track scanner (#11c).
//
// Walks a source directory looking for `.mka/.ac3/.eac3/.flac/.aac/.m4a/.opus`
// dub files and `.srt/.ass/.ssa/.vtt` sub files whose parsed (season,
// episode) numbers match one of the videos in the drop. Each external file
// is grouped by its parent folder name (= studio / fansub label). Result
// is a `ReleaseExtras` describing what's available; user picks which
// studios/labels to include via the cluster-header UI (11d), and the mux
// stage (11e) consumes the resulting per-episode track URLs.
//
// Scope:
// - Recursion is bounded (depth ≤ 4) — anime releases are 2-3 levels deep
//   in practice (e.g. `RUS Sound/AniLiberty/<files>`), 4 leaves headroom.
// - Files directly in `sourceDir` are skipped — sidecar SRTs are picked up
//   by `scanExternalSubtitles` already; flat-layout dubs are rare and
//   handled by a future enhancement if anyone asks.
// - Language inference walks path tokens (folder names) for ISO codes /
//   locale words; falls back to "und".
// - "Forced" is inferred from path tokens (`forced`, `signs`, `надписи`,
//   `songs`).

import Foundation

public struct EpisodeKey: Hashable, Sendable {
    public let season: Int
    public let episode: Int
    public init(season: Int, episode: Int) {
        self.season = season
        self.episode = episode
    }
}

public struct DubStudio: Sendable, Hashable, Identifiable {
    public let label: String                // immediate parent folder name
    public let lang: String                 // normalized lang code, "und" if unknown
    public let episodes: [EpisodeKey: URL]  // per-episode source path
    public var id: String { label }
}

public struct SubTrack: Sendable, Hashable, Identifiable {
    public let label: String
    public let lang: String
    public let forced: Bool
    public let episodes: [EpisodeKey: URL]
    public var id: String { label }
}

public struct ReleaseExtras: Sendable {
    public let dubs: [DubStudio]
    public let subs: [SubTrack]
    public var isEmpty: Bool { dubs.isEmpty && subs.isEmpty }
}

/// One concrete external track resolved for a specific episode. Produced by
/// the cluster-selection resolver (#11a) once the user has picked which
/// studios / sub labels to include for the cluster; consumed by the mux
/// stage (#11e). `kind` drives the ffmpeg map flags.
public struct ExternalTrackRef: Sendable, Hashable {
    public enum Kind: Sendable, Hashable { case dub, sub }
    public let kind: Kind
    public let path: URL
    public let label: String   // studio name (shown in audio switcher)
    public let lang: String    // ISO-639 normalized
    public let forced: Bool    // subs only; ignored for dubs
    public let isDefault: Bool // applied to the one audio track marked default
}

public enum ExternalTrackScanner {
    private static let dubExts: Set<String> = ["mka", "ac3", "eac3", "flac", "aac", "m4a", "opus"]
    private static let subExts: Set<String> = ["srt", "ass", "ssa", "vtt"]
    /// Folder/file-name tokens that mark a subtitle track as forced
    /// (signs + songs only, not full dialog). Lowercased Unicode.
    private static let forcedTokens: Set<String> = [
        "forced", "signs", "songs", "надписи", "форсированные"
    ]
    /// ISO-639-1 / -2 tokens → normalized -2-style key. Walk all path tokens
    /// in the file's relative folder; first hit wins.
    private static let langTokens: [String: String] = [
        "rus": "rus", "ru": "rus", "russian": "rus",
        "eng": "eng", "en": "eng", "english": "eng",
        "jpn": "jpn", "jp": "jpn", "ja": "jpn", "japanese": "jpn",
        "ger": "ger", "de": "ger", "deu": "ger", "german": "ger",
        "fre": "fre", "fra": "fre", "fr": "fre", "french": "fre",
        "spa": "spa", "es": "spa", "spanish": "spa",
        "ita": "ita", "it": "ita", "italian": "ita",
        "ukr": "ukr", "uk": "ukr", "ukrainian": "ukr",
        "pol": "pol", "pl": "pol", "polish": "pol",
        "por": "por", "pt": "por", "portuguese": "por",
        "chi": "chi", "zh": "chi", "chinese": "chi",
        "kor": "kor", "ko": "kor", "korean": "kor"
    ]

    /// Walk `sourceDir` for external dub / sub files matching any of the
    /// supplied episodes. Returns empty when no known (s, e) keys can be
    /// derived (e.g. all-movie drop).
    static func scanRelease(sourceDir: URL, episodes: [ParsedFilename]) -> ReleaseExtras {
        let known: Set<EpisodeKey> = Set(episodes.compactMap { e in
            guard let s = e.season, let n = e.episode else { return nil }
            return EpisodeKey(season: s, episode: n)
        })
        guard !known.isEmpty else { return ReleaseExtras(dubs: [], subs: []) }

        let sourceDirStd = sourceDir.standardizedFileURL
        let allFiles = walk(sourceDirStd, maxDepth: 4)

        // (label, lang, episodes) accumulators.
        var dubAcc: [String: (lang: String, episodes: [EpisodeKey: URL])] = [:]
        var subAcc: [String: (lang: String, forced: Bool, episodes: [EpisodeKey: URL])] = [:]

        for url in allFiles {
            let ext = url.pathExtension.lowercased()
            let isDub = dubExts.contains(ext)
            let isSub = subExts.contains(ext)
            guard isDub || isSub else { continue }

            // Skip files sitting directly in sourceDir — sidecar handling
            // covers those already.
            let parentURL = url.deletingLastPathComponent().standardizedFileURL
            guard parentURL != sourceDirStd else { continue }

            // Match to an episode key by parsing the file name.
            let parsed = FilenameParser.parse(url.lastPathComponent)
            guard let s = parsed.season, let n = parsed.episode else { continue }
            let key = EpisodeKey(season: s, episode: n)
            guard known.contains(key) else { continue }

            // Label = immediate parent folder name. Works for both nested
            // (`RUS Sound/AniLiberty/`) and flat-with-folder layouts.
            let label = parentURL.lastPathComponent.isEmpty ? "external" : parentURL.lastPathComponent

            // Token set for lang + forced inference: every folder name on
            // the path relative to sourceDir, plus the file's stem.
            let relTokens = tokenize(parentURL: parentURL, sourceDir: sourceDirStd)
            let stemTokens = tokenize(stem: (url.lastPathComponent as NSString).deletingPathExtension)
            let allTokens = relTokens.union(stemTokens)
            let lang = inferLang(from: allTokens)
            let forced = isSub && allTokens.contains(where: forcedTokens.contains)

            if isDub {
                var entry = dubAcc[label] ?? (lang: lang, episodes: [:])
                // Promote lang if previous entries were und but we now have one.
                if entry.lang == "und" && lang != "und" { entry.lang = lang }
                entry.episodes[key] = url
                dubAcc[label] = entry
            } else {
                var entry = subAcc[label] ?? (lang: lang, forced: forced, episodes: [:])
                if entry.lang == "und" && lang != "und" { entry.lang = lang }
                if forced { entry.forced = true }
                entry.episodes[key] = url
                subAcc[label] = entry
            }
        }

        let dubs = dubAcc.map { DubStudio(label: $0.key, lang: $0.value.lang, episodes: $0.value.episodes) }
            .sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
        let subs = subAcc.map { SubTrack(label: $0.key, lang: $0.value.lang, forced: $0.value.forced, episodes: $0.value.episodes) }
            .sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
        return ReleaseExtras(dubs: dubs, subs: subs)
    }

    /// Bounded recursive walk. Filesystem enumerators on macOS report depth
    /// via `enumerator.level` (1 = direct children of the root). Anything
    /// beyond `maxDepth` is skipped.
    private static func walk(_ dir: URL, maxDepth: Int) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: dir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var out: [URL] = []
        while let any = enumerator.nextObject() {
            guard let url = any as? URL else { continue }
            if enumerator.level > maxDepth { enumerator.skipDescendants(); continue }
            if let isFile = try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile, isFile {
                out.append(url)
            }
        }
        return out
    }

    /// Lowercased token set for every folder name on `parentURL`'s path
    /// relative to `sourceDir`. Splits on common separators inside folder
    /// names too — `RUS_Sound` yields {`rus`, `sound`}.
    private static func tokenize(parentURL: URL, sourceDir: URL) -> Set<String> {
        let baseComps = sourceDir.pathComponents
        let targetComps = parentURL.pathComponents
        guard targetComps.count >= baseComps.count,
              Array(targetComps.prefix(baseComps.count)) == baseComps else { return [] }
        let rel = targetComps.dropFirst(baseComps.count)
        var out = Set<String>()
        for c in rel {
            for t in splitTokens(c.lowercased()) { out.insert(t) }
        }
        return out
    }

    private static func tokenize(stem: String) -> Set<String> {
        Set(splitTokens(stem.lowercased()))
    }

    private static func splitTokens(_ s: String) -> [String] {
        s.split(whereSeparator: { c in
            c == "/" || c == "_" || c == "-" || c == " " || c == "." ||
            c == "(" || c == ")" || c == "[" || c == "]"
        }).map(String.init)
    }

    private static func inferLang(from tokens: Set<String>) -> String {
        for t in tokens {
            if let m = langTokens[t] { return m }
        }
        return "und"
    }
}
