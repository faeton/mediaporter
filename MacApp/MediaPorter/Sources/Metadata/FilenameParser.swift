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

    /// Parse a video filename into structured metadata.
    static func parse(_ filename: String) -> ParsedFilename {
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
            return ParsedFilename(
                title: cleanTitle(title),
                year: nil,
                season: season,
                episode: episode,
                mediaType: .tvShow
            )
        }

        // Anime episode pattern — only attempted when the stem has a release-group
        // bracket, so plain titles with " - NN" tails (e.g. "Apollo - 13") aren't
        // falsely typed as TV.
        if name.contains("[") {
            if let match = animePattern.firstMatch(in: name, range: range) {
                let title = extractGroup(name, match: match, group: 1)
                let episode = Int(extractGroup(name, match: match, group: 2))
                return ParsedFilename(
                    title: cleanTitle(title),
                    year: nil,
                    season: 1,
                    episode: episode,
                    mediaType: .tvShow
                )
            }
        }

        // Try movie with year
        if let match = movieYearPattern.firstMatch(in: name, range: range) {
            let title = extractGroup(name, match: match, group: 1)
            let year = Int(extractGroup(name, match: match, group: 2))
            return ParsedFilename(
                title: cleanTitle(title),
                year: year,
                season: nil,
                episode: nil,
                mediaType: .movie
            )
        }

        // Fallback — treat entire stem as title
        return ParsedFilename(
            title: cleanTitle(name),
            year: nil,
            season: nil,
            episode: nil,
            mediaType: .movie
        )
    }

    private static func extractGroup(_ string: String, match: NSTextCheckingResult, group: Int) -> String {
        guard group < match.numberOfRanges,
              let range = Range(match.range(at: group), in: string) else { return "" }
        return String(string[range])
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
