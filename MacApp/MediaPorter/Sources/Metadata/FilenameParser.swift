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

    // Movie: "Movie.Name.2024", "Movie Name (2024)", "Movie Name 1972" at
    // end-of-string, or "Movie Name (1995)BDRip720p" with the release tag
    // jammed straight onto the closing paren.
    //
    // Two alternatives, because the two forms need different boundaries:
    //   group 2 — bracketed year. The bracket IS the boundary, so nothing is
    //     required after it. The old single-branch pattern demanded a trailing
    //     `[.\s_-]|$` even for `(1995)`, which is why "GoldenEye (1995)BDRip720p"
    //     failed the regex entirely and fell through to the whole-stem fallback.
    //   group 3 — bare year. Still needs a separator or end-of-string after it,
    //     otherwise "Blade2019" and part numbers would parse as years.
    private static let movieYearPattern = try! NSRegularExpression(
        pattern: #"^(.+?)(?:[.\s_-]*[\(\[](\d{4})[\)\]]|[.\s_-]+(\d{4})(?:[.\s_-]|$))"#
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

    /// Plain-numbered fallback for anime / torrent re-encodes that don't carry
    /// any S## / [Group] / year hints — files like "Jujutsu Kaisen 01.avi",
    /// "Show.Name.05.mkv". Gated on `knownPrefixes` containing the cleaned
    /// title (normalized lowercase, separator-collapsed) so a single
    /// "Apollo 13.mkv" sitting alone in a folder doesn't get misclassified.
    /// `PipelineController.addFiles(urls:)` computes the prefix set from
    /// ≥3 siblings sharing the same title prefix.
    static func parsePlainNumbered(
        filename: String,
        knownPrefixes: Set<String>
    ) -> ParsedFilename? {
        let stem: String
        if let dotIdx = filename.lastIndex(of: ".") {
            stem = String(filename[..<dotIdx])
        } else {
            stem = filename
        }
        let range = NSRange(stem.startIndex..., in: stem)
        guard let match = plainNumberedPattern.firstMatch(in: stem, range: range) else {
            return nil
        }
        let rawTitle = extractGroup(stem, match: match, group: 1)
        let cleaned = cleanTitle(rawTitle)
        guard knownPrefixes.contains(normalizePrefix(cleaned)) else { return nil }
        let episode = Int(extractGroup(stem, match: match, group: 2))
        return ParsedFilename(
            title: cleaned,
            year: nil,
            season: 1,
            episode: episode,
            mediaType: .tvShow
        )
    }

    /// Trailing 1-3 digit episode number with separator. Movie pattern would
    /// have matched first if a 4-digit year was present, so this only sees
    /// year-less stems.
    private static let plainNumberedPattern = try! NSRegularExpression(
        pattern: #"^(.+?)[\s._-]+(\d{1,3})$"#
    )

    /// Normalize a title for prefix-matching: lowercase + collapse
    /// dot/underscore/dash/space runs to single spaces. Lets the matcher treat
    /// "Jujutsu Kaisen", "Jujutsu.Kaisen", "Jujutsu_Kaisen" as the same prefix.
    static func normalizePrefix(_ s: String) -> String {
        let lowered = s.lowercased()
        var out = ""
        var prevSep = true
        for ch in lowered {
            if ch == "." || ch == "_" || ch == "-" || ch == " " {
                if !prevSep { out.append(" "); prevSep = true }
            } else {
                out.append(ch)
                prevSep = false
            }
        }
        return out.trimmingCharacters(in: .whitespaces)
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
            // Exactly one of the two year branches participated in the match.
            let bracketed = extractGroup(name, match: match, group: 2)
            let year = Int(bracketed.isEmpty
                           ? extractGroup(name, match: match, group: 3)
                           : bracketed)
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
    static func extractSeasonFromFolder(_ folder: String) -> Int? {
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

    // MARK: - Folder-titled episodes

    /// Episode marker at the head of a filename that carries no show name of
    /// its own: "E1 «Beast Titan».mkv", "EP07 - Whatever.mkv", "Episode 12.mkv".
    /// Releases shaped like this only make sense inside a season folder, so the
    /// show name has to come from the folder — see `showTitleFromFolder`.
    ///
    /// Anchored at the start on purpose. A *trailing* number is already
    /// `parsePlainNumbered`'s job, and an unanchored `E\d+` would fire on
    /// ordinary titles ("Terminator 2", "Se7en"). The `(?![0-9])` tail stops
    /// "E1" from swallowing the first digit of "E12".
    private static let leadingEpisodePattern = try! NSRegularExpression(
        pattern: #"^(?:[Ee][Pp]?|[Ee]pisode)[\s._-]*(\d{1,3})(?![0-9])"#
    )

    /// Episode number for a bare "E##"-style stem, or nil if it isn't one.
    static func matchLeadingEpisode(_ stem: String) -> Int? {
        let range = NSRange(stem.startIndex..., in: stem)
        guard let m = leadingEpisodePattern.firstMatch(in: stem, range: range),
              let r = Range(m.range(at: 1), in: stem) else { return nil }
        return Int(stem[r])
    }

    /// True when a parsed "movie title" is really just an episode marker with
    /// no show name — the residue of an "E5 «Historia».mkv" style filename.
    /// `lookupMovie` uses this to skip the TMDb query entirely.
    static func looksLikeBareEpisodeMarker(_ title: String) -> Bool {
        matchLeadingEpisode(title) != nil
    }

    /// Release / quality noise that shows up in season-folder names and must
    /// not end up in the TMDb query. Matched as whole tokens, case-insensitively.
    private static let folderNoiseTokens: Set<String> = [
        "1080p", "720p", "480p", "2160p", "4k", "uhd", "hd", "sd", "fullhd",
        "bdrip", "bluray", "blu-ray", "brrip", "webrip", "web-dl", "webdl", "web",
        "hdrip", "dvdrip", "dvd", "hdtv", "remux", "rip",
        "x264", "x265", "h264", "h265", "hevc", "avc", "xvid", "divx", "av1",
        "aac", "ac3", "eac3", "dts", "flac", "mp3", "opus", "ddp", "dd",
        "10bit", "8bit", "hdr", "hdr10", "dv", "sdr",
        "fps", "dub", "dubbed", "sub", "subbed", "subs", "multi", "dual",
        "complete", "season", "seasons", "series",
    ]

    /// Turn a season-folder name into a show title:
    /// "Shingeki no Kyojin S3 60 FPS" → "Shingeki no Kyojin".
    ///
    /// Strips bracketed groups, the season marker, and any trailing run of
    /// release-noise tokens. Only a *trailing* run is dropped — noise words
    /// are stripped from the tail inward and we stop at the first real word, so
    /// a show whose name legitimately contains one ("Band of Brothers Complete"
    /// vs. "The Web S1") keeps its own words.
    static func showTitleFromFolder(_ folder: String) -> String {
        // Drop bracketed release groups first: "[Erai-raws] Show S2 [1080p]".
        var s = folder.replacingOccurrences(
            of: #"\[[^\]]*\]"#, with: " ", options: .regularExpression
        )
        // Remove the season marker wherever it sits.
        s = s.replacingOccurrences(
            of: #"(?:^|[\s._-])(?:[Ss]eason[\s._-]*\d{1,2}|[Ss]\d{1,2})(?=[\s._-]|$)"#,
            with: " ", options: .regularExpression
        )
        s = s.replacingOccurrences(of: ".", with: " ")
             .replacingOccurrences(of: "_", with: " ")

        var tokens = s.split(separator: " ").map(String.init)
            .filter { !$0.isEmpty }
        // Peel release noise off the tail. A bare number is only noise once a
        // named noise token has already been peeled — that's what separates
        // the "60" of "Show 60 FPS" (dropped, it qualifies FPS) from the "7"
        // of "Blake's 7" (kept, it's the title). Same for "Show 1080p" vs
        // "Apollo 13": the former peels "1080p" but then stops at "Show".
        var peeledNoise = false
        while let last = tokens.last {
            let key = last.lowercased().trimmingCharacters(in: .punctuationCharacters)
            if folderNoiseTokens.contains(key) {
                tokens.removeLast()
                peeledNoise = true
            } else if peeledNoise, !key.isEmpty, key.allSatisfy(\.isNumber) {
                tokens.removeLast()
            } else {
                break
            }
        }
        return tokens.joined(separator: " ").trimmingCharacters(in: .whitespaces)
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

    // MARK: - Release-tail stripping

    /// Tokens that essentially never appear in a real film or show title, so
    /// hitting one means the title has ended and release metadata has begun.
    ///
    /// Deliberately narrower than `folderNoiseTokens`. Words like "complete",
    /// "extended", "web", "dual" and "series" are excluded on purpose — they
    /// are plausible release tags but they also maul real titles ("A Complete
    /// Unknown", "The Web", "Extended Family"). A folder name can afford the
    /// looser list because it is only ever a container; a filename cannot.
    private static let releaseNoiseTokens: Set<String> = [
        "bdrip", "bluray", "blu-ray", "brrip", "bdremux", "webrip", "web-dl",
        "webdl", "hdrip", "dvdrip", "dvdscr", "hdtv", "tvrip", "camrip", "remux",
        "x264", "x265", "h264", "h265", "hevc", "avc", "xvid", "divx", "av1",
        "aac", "ac3", "eac3", "dts", "truehd", "flac",
        "10bit", "8bit", "hdr10", "repack", "proper",
    ]

    /// True when a token is unambiguously release metadata rather than title.
    private static func isReleaseNoise(_ token: String) -> Bool {
        let t = token.lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "()[]{}.,-"))
        guard !t.isEmpty else { return false }
        if releaseNoiseTokens.contains(t) { return true }
        // Resolutions: 720p, 1080p, 2160p.
        if t.range(of: #"^\d{3,4}p$"#, options: .regularExpression) != nil { return true }
        // Hyphenated stacks: "WEB-DLRip-AVC", "DTS-HD". One known part is
        // enough — the whole compound is metadata.
        let parts = t.split(separator: "-").map(String.init)
        if parts.count > 1, parts.contains(where: { releaseNoiseTokens.contains($0) }) {
            return true
        }
        return false
    }

    /// Cut a title at the first release-metadata token.
    ///
    /// Scene releases separate the title from their tags with the *same*
    /// character they use inside the title — "Rambo.First.Blood.HDRip.Kubik.v.Kube"
    /// — so there is no syntactic boundary to find, only a vocabulary one.
    /// Truncating at "HDRip" yields "Rambo First Blood" and, as a bonus, sheds
    /// the release-group name trailing behind it ("Kubik v Kube"), which would
    /// otherwise poison the TMDb query just as badly as the tags do.
    ///
    /// `idx > 0` keeps a title that *opens* with a listed word intact rather
    /// than reducing it to the empty string.
    static func stripReleaseTail(_ title: String) -> String {
        let tokens = title.split(separator: " ").map(String.init)
        guard let idx = tokens.firstIndex(where: isReleaseNoise), idx > 0 else {
            return title
        }
        return tokens[..<idx].joined(separator: " ")
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
        // Collapse the separator runs the substitutions above leave behind, so
        // stripReleaseTail sees clean single-space tokens.
        let collapsed = bracketStripped.replacingOccurrences(
            of: #"\s+"#, with: " ", options: .regularExpression
        )
        return stripReleaseTail(collapsed.trimmingCharacters(in: .whitespaces))
    }
}
