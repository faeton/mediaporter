// Regex-based filename parsing — extract title, year, season, episode.
// Replaces Python's guessit dependency.

import Foundation

enum MediaType {
    case movie
    case tvShow
}

struct ParsedFilename {
    let title: String
    let year: Int?
    let season: Int?
    let episode: Int?
    let mediaType: MediaType
}

/// Public seam for the App target — extract just (season, episode) from a
/// filename. Hides the internal `ParsedFilename` type.
public func parseSeasonEpisode(from filename: String) -> (season: Int?, episode: Int?) {
    let p = FilenameParser.parse(filename)
    return (p.season, p.episode)
}

/// Same as above but also consults the parent directory name — useful when
/// the filename itself omits the season (anime "[Group] Show - 05") but the
/// folder spells it out ("Show.Season3.WEB-DL.1080p"). Folder wins only
/// when the filename had no explicit season marker of its own.
public func parseSeasonEpisode(from url: URL) -> (season: Int?, episode: Int?) {
    let parentDir = url.deletingLastPathComponent().lastPathComponent
    let p = FilenameParser.parse(url.lastPathComponent, parentDir: parentDir)
    return (p.season, p.episode)
}

enum FilenameParser {
    // TV: "Show.Name.S01E02", "Show Name - S01E02", "Show - S1 - E01", "Show S01.E02".
    // The separators between S## and E## are optional + greedy because real-world
    // anime/scene rips use forms like "S1 - E01" with space-dash-space in between.
    private static let tvPattern = try! NSRegularExpression(
        pattern: #"^(.+?)[.\s_-]+[Ss](\d{1,2})[\s._-]*[Ee](\d{1,2})"#
    )

    // Anime: "[Group] Show - 01 [tags]", "[Group] Show - 12v2 [tags]". No S## prefix,
    // season defaults to 1 (Erai-raws / SubsPlease / HorribleSubs convention).
    // Gated on the stem containing a release-group bracket so a movie like
    // "Apollo - 13" doesn't get misclassified as TV.
    private static let animePattern = try! NSRegularExpression(
        pattern: #"^(?:\[[^\]]+\]\s*)?(.+?)\s+-\s+(\d{1,3})(?:v\d+)?(?:[\s\[]|$)"#
    )

    // Movie: "Movie.Name.2024", "Movie Name (2024)", or "Movie Name 1972" at end-of-string.
    // Trailing separator is optional so the year can be the last token in the stem.
    private static let movieYearPattern = try! NSRegularExpression(
        pattern: #"^(.+?)[.\s_-]+[\(]?(\d{4})[\)]?(?:[.\s_-]|$)"#
    )

    /// Parse a video filename, then consult `parentDir` for a season marker
    /// when the filename itself was ambiguous (anime "[Group] Show - 05"
    /// inside "Show.Season3.WEB-DL"). Filename-level evidence always wins
    /// over the folder — only the anime default-to-1 path defers to it.
    static func parse(_ filename: String, parentDir: String) -> ParsedFilename {
        let (parsed, seasonExplicit) = parseInternal(filename)
        guard parsed.mediaType == .tvShow, !seasonExplicit,
              let folderSeason = extractSeasonFromFolder(parentDir) else {
            return parsed
        }
        return ParsedFilename(
            title: parsed.title,
            year: parsed.year,
            season: folderSeason,
            episode: parsed.episode,
            mediaType: .tvShow
        )
    }

    /// Parse a video filename into structured metadata.
    static func parse(_ filename: String) -> ParsedFilename {
        parseInternal(filename).parsed
    }

    private static func parseInternal(_ filename: String) -> (parsed: ParsedFilename, seasonExplicit: Bool) {
        // Strip extension
        let name: String
        if let dotIdx = filename.lastIndex(of: ".") {
            name = String(filename[..<dotIdx])
        } else {
            name = filename
        }

        let range = NSRange(name.startIndex..., in: name)

        // Try TV pattern first
        if let match = tvPattern.firstMatch(in: name, range: range) {
            let title = extractGroup(name, match: match, group: 1)
            let season = Int(extractGroup(name, match: match, group: 2))
            let episode = Int(extractGroup(name, match: match, group: 3))
            let p = ParsedFilename(
                title: cleanTitle(title),
                year: nil,
                season: season,
                episode: episode,
                mediaType: .tvShow
            )
            return (p, true)
        }

        // Anime episode pattern — only attempted when the stem has a release-group
        // bracket, so plain titles with " - NN" tails (e.g. "Apollo - 13") aren't
        // falsely typed as TV.
        if name.contains("[") {
            if let match = animePattern.firstMatch(in: name, range: range) {
                let rawTitle = extractGroup(name, match: match, group: 1)
                let episode = Int(extractGroup(name, match: match, group: 2))
                let (strippedTitle, trailingSeason) = extractTrailingSeason(rawTitle)
                let p = ParsedFilename(
                    title: cleanTitle(strippedTitle),
                    year: nil,
                    season: trailingSeason ?? 1,
                    episode: episode,
                    mediaType: .tvShow
                )
                return (p, trailingSeason != nil)
            }
        }

        // Try movie with year
        if let match = movieYearPattern.firstMatch(in: name, range: range) {
            let title = extractGroup(name, match: match, group: 1)
            let year = Int(extractGroup(name, match: match, group: 2))
            let p = ParsedFilename(
                title: cleanTitle(title),
                year: year,
                season: nil,
                episode: nil,
                mediaType: .movie
            )
            return (p, false)
        }

        // Fallback — treat entire stem as title
        let p = ParsedFilename(
            title: cleanTitle(name),
            year: nil,
            season: nil,
            episode: nil,
            mediaType: .movie
        )
        return (p, false)
    }

    // Pull a season number out of a directory name. Matches "Season 3",
    // "Season3", "Season.3", "S03" — common scene/WEB-DL folder layouts
    // ("Jujutsu.Kaisen.Season3.WEB-DL.1080p"). Word-boundary anchors
    // protect against accidental hits inside the show name itself.
    private static let folderSeasonPattern = try! NSRegularExpression(
        pattern: #"(?:^|[\s._-])(?:[Ss]eason[\s._-]*(\d{1,2})|[Ss](\d{1,2}))(?:[\s._-]|$)"#
    )
    private static func extractSeasonFromFolder(_ folder: String) -> Int? {
        let range = NSRange(folder.startIndex..., in: folder)
        guard let m = folderSeasonPattern.firstMatch(in: folder, range: range) else {
            return nil
        }
        for g in 1...2 {
            if let r = Range(m.range(at: g), in: folder) {
                return Int(folder[r])
            }
        }
        return nil
    }

    private static func extractGroup(_ string: String, match: NSTextCheckingResult, group: Int) -> String {
        guard group < match.numberOfRanges,
              let range = Range(match.range(at: group), in: string) else { return "" }
        return String(string[range])
    }

    // Anime rips often put the season marker in the show name itself
    // ("Jujutsu Kaisen S3 - 05", "Mushoku Tensei Season 2 - 12") instead of
    // folding it into S##E##. Pull it off the tail so the TMDb query gets
    // the bare show name and `season` doesn't silently stay at 1.
    private static let trailingSeasonPattern = try! NSRegularExpression(
        pattern: #"[\s._-]+(?:[Ss](\d{1,2})|[Ss]eason[\s._-]+(\d{1,2}))\s*$"#
    )
    private static func extractTrailingSeason(_ title: String) -> (String, Int?) {
        let range = NSRange(title.startIndex..., in: title)
        guard let m = trailingSeasonPattern.firstMatch(in: title, range: range),
              let fullRange = Range(m.range, in: title) else {
            return (title, nil)
        }
        var season: Int?
        for g in 1...2 {
            if let r = Range(m.range(at: g), in: title) {
                season = Int(title[r])
                break
            }
        }
        var stripped = title
        stripped.removeSubrange(fullRange)
        return (stripped.trimmingCharacters(in: .whitespaces), season)
    }

    private static func cleanTitle(_ raw: String) -> String {
        // Replace dots/underscores with spaces, then drop parenthesized tails
        // ("Крестный отец (The Godfather)" → "Крестный отец") so TMDb queries
        // aren't polluted with alt-titles and noise like "(2022) [1080p]".
        let spaced = raw.replacingOccurrences(of: ".", with: " ")
                        .replacingOccurrences(of: "_", with: " ")
        let parenStripped = spaced.replacingOccurrences(
            of: #"\s*\([^)]*\)\s*"#, with: " ", options: .regularExpression
        )
        let bracketStripped = parenStripped.replacingOccurrences(
            of: #"\s*\[[^\]]*\]\s*"#, with: " ", options: .regularExpression
        )
        return bracketStripped.trimmingCharacters(in: .whitespaces)
    }
}
