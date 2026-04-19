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
