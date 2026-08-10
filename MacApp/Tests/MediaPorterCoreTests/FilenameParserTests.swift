// Verifies filename parsing handles the common rip conventions plus the
// gnarly real-world cases that used to slip past the movie-year regex
// (year at end-of-string, parenthesized alt-titles, Cyrillic).

import XCTest
@testable import MediaPorterCore

final class FilenameParserTests: XCTestCase {

    // MARK: Movie patterns

    func testMovieDotSeparated() {
        let p = FilenameParser.parse("Inception.2010.BluRay.1080p.mkv")
        XCTAssertEqual(p.title, "Inception")
        XCTAssertEqual(p.year, 2010)
    }

    func testMovieSpaceSeparated() {
        let p = FilenameParser.parse("Inception 2010 BluRay.mkv")
        XCTAssertEqual(p.title, "Inception")
        XCTAssertEqual(p.year, 2010)
    }

    func testMovieWithParenYear() {
        let p = FilenameParser.parse("Inception (2010) BluRay.mkv")
        XCTAssertEqual(p.title, "Inception")
        XCTAssertEqual(p.year, 2010)
    }

    // The case that broke: year is the last token before the extension, no
    // trailing separator. Previously failed the regex and fell through to
    // using the whole stem as a title with year=nil.
    func testMovieYearAtEndOfStem() {
        let p = FilenameParser.parse("Godfather 1972.mkv")
        XCTAssertEqual(p.title, "Godfather")
        XCTAssertEqual(p.year, 1972)
    }

    func testMovieYearAtEndInParens() {
        let p = FilenameParser.parse("Godfather (1972).mkv")
        XCTAssertEqual(p.title, "Godfather")
        XCTAssertEqual(p.year, 1972)
    }

    // Real-world case: Cyrillic title with an English alt-title in parens.
    // Expected: year is recognized, alt-title stripped from the TMDb query
    // (keeping the original Russian title for a Cyrillic-aware TMDb search).
    func testCyrillicTitleWithParenthesizedAltTitle() {
        let p = FilenameParser.parse("Крестный отец (The Godfather) 1972.mkv")
        XCTAssertEqual(p.year, 1972)
        XCTAssertEqual(p.title, "Крестный отец")
    }

    func testTrailingBracketedNoiseStripped() {
        let p = FilenameParser.parse("The.Matrix.1999.[1080p].mkv")
        XCTAssertEqual(p.title, "The Matrix")
        XCTAssertEqual(p.year, 1999)
    }

    // MARK: TV patterns

    func testTVDotSeparated() {
        let p = FilenameParser.parse("Breaking.Bad.S01E02.720p.mkv")
        XCTAssertEqual(p.title, "Breaking Bad")
        XCTAssertEqual(p.season, 1)
        XCTAssertEqual(p.episode, 2)
    }

    func testTVDashSeparated() {
        let p = FilenameParser.parse("Breaking Bad - S01E02 - Cat's in the Bag.mkv")
        XCTAssertEqual(p.title, "Breaking Bad")
        XCTAssertEqual(p.season, 1)
        XCTAssertEqual(p.episode, 2)
    }

    // MARK: Fallback

    func testUnrecognizedPatternUsesFullStem() {
        let p = FilenameParser.parse("Some Random File.mkv")
        XCTAssertEqual(p.title, "Some Random File")
        XCTAssertNil(p.year)
    }
}

extension FilenameParserTests {
    func testTVAnimeReleaseSpaceDashSeparator() {
        let p = FilenameParser.parse(
            "[SOFCJ-Raws] Shingeki no Kyojin - S1 - E01 [WEB-DL KP 1080p].mkv"
        )
        XCTAssertEqual(p.mediaType, .tvShow)
        XCTAssertEqual(p.title, "Shingeki no Kyojin")
        XCTAssertEqual(p.season, 1)
        XCTAssertEqual(p.episode, 1)
    }

    func testTVDottedSeasonEpisodeSeparator() {
        let p = FilenameParser.parse("Show.Name.S01.E02.mkv")
        XCTAssertEqual(p.mediaType, .tvShow)
        XCTAssertEqual(p.title, "Show Name")
        XCTAssertEqual(p.season, 1)
        XCTAssertEqual(p.episode, 2)
    }

    // Erai-raws / SubsPlease anime convention: "[Group] Show - NN [tags]".
    // No S##E## marker; season defaults to 1.
    func testAnimeEraiRawsEpisode() {
        let p = FilenameParser.parse(
            "[Erai-raws] Odd Taxi - 01 [720p][Multiple Subtitle].mkv"
        )
        XCTAssertEqual(p.mediaType, .tvShow)
        XCTAssertEqual(p.title, "Odd Taxi")
        XCTAssertEqual(p.season, 1)
        XCTAssertEqual(p.episode, 1)
    }

    func testAnimeWithVersionSuffix() {
        let p = FilenameParser.parse("[SubsPlease] Frieren - 12v2 [1080p].mkv")
        XCTAssertEqual(p.mediaType, .tvShow)
        XCTAssertEqual(p.title, "Frieren")
        XCTAssertEqual(p.episode, 12)
    }

    // Negative case: bracket-less "Title - NN" must not be falsely typed as TV.
    func testDashNumberWithoutBracketsStaysMovie() {
        let p = FilenameParser.parse("Apollo - 13.mkv")
        XCTAssertEqual(p.mediaType, .movie)
    }

    // Anime rip carries season in the show name itself ("Show S3 - 05").
    // Must lift the trailing S## off into `season` and out of `title`,
    // otherwise the TMDb query is polluted and season silently stays at 1.
    func testAnimeTrailingSeasonMarkerSAbbrev() {
        let p = FilenameParser.parse(
            "[BudLightSubs] Jujutsu Kaisen S3 - 05 [1080p].mkv"
        )
        XCTAssertEqual(p.mediaType, .tvShow)
        XCTAssertEqual(p.title, "Jujutsu Kaisen")
        XCTAssertEqual(p.season, 3)
        XCTAssertEqual(p.episode, 5)
    }

    // Parent folder encodes the season ("Jujutsu.Kaisen.Season3.WEB-DL"),
    // filename itself doesn't. Folder is consulted only when the filename
    // gave no explicit season — explicit S##E## must still win.
    func testParentDirSeasonFallback() {
        let p = FilenameParser.parse(
            "[Erai-raws] Odd Taxi - 01 [720p].mkv",
            parentDir: "Odd.Taxi.Season2.WEB-DL.1080p"
        )
        XCTAssertEqual(p.season, 2)
        XCTAssertEqual(p.episode, 1)
    }

    func testParentDirIgnoredWhenFilenameExplicit() {
        let p = FilenameParser.parse(
            "Breaking.Bad.S01E02.720p.mkv",
            parentDir: "Breaking.Bad.Season5"
        )
        XCTAssertEqual(p.season, 1)
        XCTAssertEqual(p.episode, 2)
    }

    func testAnimeTrailingSeasonMarkerSpelledOut() {
        let p = FilenameParser.parse(
            "[SubsPlease] Mushoku Tensei Season 2 - 12 [1080p].mkv"
        )
        XCTAssertEqual(p.mediaType, .tvShow)
        XCTAssertEqual(p.title, "Mushoku Tensei")
        XCTAssertEqual(p.season, 2)
        XCTAssertEqual(p.episode, 12)
    }
}

// MARK: - Folder-titled episodes
//
// Real-world shape that used to fall all the way through to "movie": the
// episode number leads the filename and the show name exists only in the
// parent directory — `Shingeki no Kyojin S2 60 FPS/E1 «Beast Titan».mkv`.

final class FolderTitledEpisodeTests: XCTestCase {

    // MARK: matchLeadingEpisode

    func testLeadingEpisodeBareE() {
        XCTAssertEqual(FilenameParser.matchLeadingEpisode("E1 «Beast Titan»"), 1)
        XCTAssertEqual(FilenameParser.matchLeadingEpisode("E12 «Scream»"), 12)
    }

    func testLeadingEpisodeEPAndWord() {
        XCTAssertEqual(FilenameParser.matchLeadingEpisode("EP07 - Something"), 7)
        XCTAssertEqual(FilenameParser.matchLeadingEpisode("Episode 3"), 3)
        XCTAssertEqual(FilenameParser.matchLeadingEpisode("E.05.Title"), 5)
    }

    /// The `(?![0-9])` tail must stop "E1" from claiming the leading digit of
    /// a two-digit number — otherwise E12 sorts as episode 1.
    func testLeadingEpisodeTakesAllDigits() {
        XCTAssertEqual(FilenameParser.matchLeadingEpisode("E105 «Late»"), 105)
    }

    /// Anchored at the start: an ordinary title that merely contains an E+digit
    /// run must not be mistaken for an episode.
    func testLeadingEpisodeRejectsOrdinaryTitles() {
        XCTAssertNil(FilenameParser.matchLeadingEpisode("Terminator 2"))
        XCTAssertNil(FilenameParser.matchLeadingEpisode("Se7en"))
        XCTAssertNil(FilenameParser.matchLeadingEpisode("GoldenEye"))
        XCTAssertNil(FilenameParser.matchLeadingEpisode("Casino Royale"))
        XCTAssertNil(FilenameParser.matchLeadingEpisode("Elysium"))
    }

    // MARK: showTitleFromFolder

    func testFolderTitleStripsSeasonAndFPS() {
        XCTAssertEqual(
            FilenameParser.showTitleFromFolder("Shingeki no Kyojin S3 60 FPS"),
            "Shingeki no Kyojin"
        )
        XCTAssertEqual(
            FilenameParser.showTitleFromFolder("Shingeki no Kyojin S2 60 FPS"),
            "Shingeki no Kyojin"
        )
    }

    func testFolderTitleStripsReleaseNoise() {
        XCTAssertEqual(
            FilenameParser.showTitleFromFolder("Jujutsu.Kaisen.Season2.WEB-DL.1080p"),
            "Jujutsu Kaisen"
        )
        XCTAssertEqual(
            FilenameParser.showTitleFromFolder("[Erai-raws] Frieren S1 [1080p]"),
            "Frieren"
        )
    }

    /// A bare trailing number is only noise once a named noise token has been
    /// peeled. Titles that legitimately end in a number keep it.
    func testFolderTitleKeepsTrailingNumberInTitle() {
        XCTAssertEqual(FilenameParser.showTitleFromFolder("Blake's 7"), "Blake's 7")
        XCTAssertEqual(FilenameParser.showTitleFromFolder("Apollo 13"), "Apollo 13")
        XCTAssertEqual(FilenameParser.showTitleFromFolder("Babylon 5 S3"), "Babylon 5")
    }

    /// A folder that cleans down to nothing must yield "" so the caller can
    /// decline to invent a show name.
    func testFolderTitleEmptyWhenAllNoise() {
        XCTAssertEqual(FilenameParser.showTitleFromFolder("S3"), "")
        XCTAssertEqual(FilenameParser.showTitleFromFolder("1080p WEB-DL"), "")
    }

    // MARK: season extraction from the same folders

    func testSeasonFromFolder() {
        XCTAssertEqual(FilenameParser.extractSeasonFromFolder("Shingeki no Kyojin S3 60 FPS"), 3)
        XCTAssertEqual(FilenameParser.extractSeasonFromFolder("Shingeki no Kyojin S2 60 FPS"), 2)
        XCTAssertEqual(FilenameParser.extractSeasonFromFolder("Jujutsu.Kaisen.Season2.WEB-DL"), 2)
        XCTAssertNil(FilenameParser.extractSeasonFromFolder("Shingeki no Kyojin"))
    }

    // MARK: the TMDb query guard

    func testBareEpisodeMarkerDetected() {
        XCTAssertTrue(FilenameParser.looksLikeBareEpisodeMarker("E5 «Historia»"))
        XCTAssertTrue(FilenameParser.looksLikeBareEpisodeMarker("E1 «Beast Titan»"))
    }

    func testRealMovieTitlesAreNotBareEpisodeMarkers() {
        for title in ["GoldenEye", "Casino Royale", "Rambo First Blood",
                      "Signal One", "The Death of Robin Hood", "Крестный отец"] {
            XCTAssertFalse(
                FilenameParser.looksLikeBareEpisodeMarker(title),
                "\(title) must still be queried as a movie"
            )
        }
    }
}

// MARK: - Release-tail handling
//
// Two real files that resolved to nothing on TMDb because the query still
// carried release metadata.

final class ReleaseTailTests: XCTestCase {

    /// "GoldenEye (1995)BDRip720p" — the release tag is jammed onto the closing
    /// paren with no separator, which used to fail the year regex outright and
    /// fall through to the whole stem as the title.
    func testYearInParensWithNoTrailingSeparator() {
        let p = FilenameParser.parse("GoldenEye (1995)BDRip720p.mkv")
        XCTAssertEqual(p.title, "GoldenEye")
        XCTAssertEqual(p.year, 1995)
        XCTAssertEqual(p.mediaType, .movie)
    }

    func testYearInBracketsWithNoTrailingSeparator() {
        let p = FilenameParser.parse("Heat [1995]BDRip.mkv")
        XCTAssertEqual(p.title, "Heat")
        XCTAssertEqual(p.year, 1995)
    }

    /// "Rambo.First.Blood.HDRip.Kubik.v.Kube" — no year anywhere, and the
    /// release group's name uses the same dot separator as the title, so only
    /// the "HDRip" token marks where the title ends.
    func testNoYearTitleTruncatesAtReleaseToken() {
        let p = FilenameParser.parse("Rambo.First.Blood.HDRip.Kubik.v.Kube.mkv")
        XCTAssertEqual(p.title, "Rambo First Blood")
        XCTAssertNil(p.year)
    }

    func testReleaseTailStrippedAfterYearToo() {
        let p = FilenameParser.parse("Signal One.2026.DUB.WEB-DLRip-AVC.x264.seleZen.mkv")
        XCTAssertEqual(p.title, "Signal One")
        XCTAssertEqual(p.year, 2026)
    }

    func testHyphenatedCodecStackCountsAsNoise() {
        XCTAssertEqual(FilenameParser.stripReleaseTail("Some Film WEB-DLRip-AVC x264"), "Some Film")
        XCTAssertEqual(FilenameParser.stripReleaseTail("Some Film DTS-HD"), "Some Film")
    }

    /// The narrow token list must leave real titles alone — these are the words
    /// deliberately kept out of `releaseNoiseTokens`.
    func testRealTitlesSurviveStripping() {
        for title in ["A Complete Unknown", "The Web", "Extended Family",
                      "Dual Survival", "The Complete Series Of Unfortunate Events",
                      "GoldenEye", "Casino Royale", "Крестный отец"] {
            XCTAssertEqual(
                FilenameParser.stripReleaseTail(title), title,
                "\(title) must not be truncated"
            )
        }
    }

    /// A title that opens with a listed token is left whole rather than emptied.
    func testTitleStartingWithNoiseTokenIsKept() {
        XCTAssertEqual(FilenameParser.stripReleaseTail("Proper Behaviour"), "Proper Behaviour")
    }

    /// Guard the boundary the bare-year branch still enforces.
    func testDigitsGluedToTitleAreNotAYear() {
        let p = FilenameParser.parse("Blade2019.mkv")
        XCTAssertNil(p.year)
    }
}

// MARK: - TMDb result re-ranking

final class TMDbBestMatchTests: XCTestCase {

    private func movie(_ title: String, _ year: Int, _ id: Int) -> MovieMetadata {
        MovieMetadata(title: title, year: year, genre: nil, overview: nil,
                      longOverview: nil, director: nil, posterURL: nil,
                      posterData: nil, tmdbID: id, originalLanguage: "en")
    }

    /// The live ordering TMDb returns for "Rambo First Blood". Its top hit is
    /// the 1985 sequel; the film we want sits at index 3.
    func testPrefersFewestExtraWordsOverTMDbOrder() {
        let results = [
            movie("Rambo: First Blood Part II", 1985, 1),
            movie("Rambo III", 1988, 2),
            movie("Wild Blood", 1983, 3),
            movie("First Blood", 1982, 4),
            movie("Rambo", 2008, 5),
        ]
        let best = MetadataLookup.bestMatch(for: "Rambo First Blood", among: results)
        XCTAssertEqual(best?.title, "First Blood")
        XCTAssertEqual(best?.year, 1982)
    }

    /// Zero overlap everywhere must leave TMDb's own ranking alone — this is
    /// the cross-language path and it must never be re-ordered or dropped.
    func testCrossLanguageFallsBackToTMDbOrder() {
        let results = [
            movie("The Godfather", 1972, 238),
            movie("The Godfather Part II", 1974, 240),
        ]
        let best = MetadataLookup.bestMatch(for: "Крестный отец", among: results)
        XCTAssertEqual(best?.title, "The Godfather")
    }

    /// Equal scores keep TMDb's order, so the more popular entry still wins.
    func testTiesKeepTMDbOrder() {
        let results = [
            movie("Casino Royale", 2006, 36557),
            movie("Casino Royale", 1967, 646),
        ]
        let best = MetadataLookup.bestMatch(for: "Casino Royale", among: results)
        XCTAssertEqual(best?.year, 2006)
    }

    func testExactTitleWinsOverSupersetTitle() {
        let results = [
            movie("Heat 2", 2026, 1),
            movie("Heat", 1995, 2),
        ]
        XCTAssertEqual(MetadataLookup.bestMatch(for: "Heat", among: results)?.year, 1995)
    }

    func testEmptyResultsYieldNil() {
        XCTAssertNil(MetadataLookup.bestMatch(for: "Anything", among: []))
    }
}

// MARK: - Ambiguity detection (drives the in-row "N matches" picker)

final class AmbiguousMatchTests: XCTestCase {

    private func movie(_ title: String, _ year: Int, _ id: Int) -> MovieMetadata {
        MovieMetadata(title: title, year: year, genre: nil, overview: nil,
                      longOverview: nil, director: nil, posterURL: nil,
                      posterData: nil, tmdbID: id, originalLanguage: "en")
    }

    /// No candidate matches the query word-for-word, so our pick is a guess.
    func testPartialOverlapIsAmbiguous() {
        let results = [
            movie("Rambo: First Blood Part II", 1985, 1),
            movie("Rambo III", 1988, 2),
            movie("First Blood", 1982, 4),
        ]
        XCTAssertTrue(MetadataLookup.isAmbiguousMatch(query: "Rambo First Blood", results: results))
    }

    /// Exactly one exact title match — decisive, no badge.
    func testUniqueExactMatchIsNotAmbiguous() {
        let results = [
            movie("Signal One", 2026, 1),
            movie("Signal One Something Else", 1994, 2),
        ]
        XCTAssertFalse(MetadataLookup.isAmbiguousMatch(query: "Signal One", results: results))
    }

    /// Two candidates with the same title can't be told apart on title alone.
    func testTiedExactTitlesAreAmbiguous() {
        let results = [movie("Casino Royale", 2006, 1), movie("Casino Royale", 1967, 2)]
        XCTAssertTrue(MetadataLookup.isAmbiguousMatch(query: "Casino Royale", results: results))
    }

    /// A single result is taken at face value — there is nothing to choose between.
    func testSingleResultIsNeverAmbiguous() {
        XCTAssertFalse(
            MetadataLookup.isAmbiguousMatch(query: "Anything", results: [movie("Whatever", 2000, 1)])
        )
    }

    /// Cross-language: zero overlap everywhere, so we defer to TMDb but still
    /// let the user see the alternatives.
    func testZeroOverlapIsAmbiguous() {
        let results = [movie("The Godfather", 1972, 238), movie("The Godfather Part II", 1974, 240)]
        XCTAssertTrue(MetadataLookup.isAmbiguousMatch(query: "Крестный отец", results: results))
    }
}
