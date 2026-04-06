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
    // TV: "Show.Name.S01E02" or "Show Name - S01E02"
    private static let tvPattern = try! NSRegularExpression(
        pattern: #"^(.+?)[.\s_-]+[Ss](\d{1,2})[Ee](\d{1,2})"#
    )

    // Movie: "Movie.Name.2024" or "Movie Name (2024)"
    private static let movieYearPattern = try! NSRegularExpression(
        pattern: #"^(.+?)[.\s_-]+[\(]?(\d{4})[\)]?[.\s_-]"#
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
        // Replace dots/underscores with spaces, trim
        raw.replacingOccurrences(of: ".", with: " ")
           .replacingOccurrences(of: "_", with: " ")
           .trimmingCharacters(in: .whitespaces)
    }
}
