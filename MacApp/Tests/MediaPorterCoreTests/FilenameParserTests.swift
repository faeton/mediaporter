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
