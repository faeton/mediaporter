// Grouping / tie-breaking for the split-season detector.
//
// A "split season" is one album whose episodes carry more than one
// `item.album_order`, which makes TV.app draw a duplicate "Season N" header.
// `findSeasonOrderSplits` reads the rows off the device; everything after the
// query lives in `parseSeasonOrderSplits`, which is what these cover.
//
// The row format is the SELECT in `findSeasonOrderSplits`, tab-separated:
//   album_pid, season_number, album_order, sync_id, episode_sort_id,
//   hex(album), hex(sort_map name), hex(title)
// Text columns are hex-encoded precisely so that tabs and newlines in user
// text cannot shift the numeric fields — one of these tests pins that.

import XCTest
@testable import MediaPorterCore

final class SeasonOrderSplitTests: XCTestCase {

    private func hex(_ s: String) -> String {
        s.utf8.map { String(format: "%02X", $0) }.joined()
    }

    /// One row of the detector's SELECT.
    private func row(albumPID: Int64, season: Int, order: Int64, syncID: Int64,
                     episode: Int, album: String, keyName: String,
                     title: String) -> String {
        [String(albumPID), String(season), String(order), String(syncID),
         String(episode), hex(album), hex(keyName), hex(title)]
            .joined(separator: "\t")
    }

    // MARK: - the bug this detector exists for

    func testReportsSplitAndNamesTheNonSeasonKeyRows() {
        let text = [
            row(albumPID: 1, season: 1, order: 100, syncID: 11, episode: 1,
                album: "Order Test", keyName: "order test", title: "E01"),
            row(albumPID: 1, season: 1, order: 100, syncID: 12, episode: 2,
                album: "Order Test", keyName: "order test", title: "E02"),
            row(albumPID: 1, season: 1, order: 200, syncID: 13, episode: 3,
                album: "Order Test", keyName: "1", title: "E03"),
        ].joined(separator: "\n")

        let splits = parseSeasonOrderSplits(text)
        XCTAssertEqual(splits.count, 1)
        // Survivor is the season-number key ("1"), so the two rows sorting
        // under the show name are what needs re-syncing — even though they
        // are the numerical majority.
        XCTAssertEqual(splits[0].minority.map(\.syncID), [11, 12])
        XCTAssertEqual(splits[0].minority.map(\.title), ["E01", "E02"])
        XCTAssertEqual(splits[0].albumPID, 1)
        XCTAssertEqual(splits[0].seasonNumber, 1)
    }

    func testEvenSplitStillKeepsTheSeasonNumberKey() {
        // 2 vs 2. Raw majority would be a coin flip on Dictionary order and
        // could nominate the half that is already correct.
        let text = [
            row(albumPID: 7, season: 3, order: 100, syncID: 1, episode: 1,
                album: "Show", keyName: "show", title: "A"),
            row(albumPID: 7, season: 3, order: 100, syncID: 2, episode: 2,
                album: "Show", keyName: "show", title: "B"),
            row(albumPID: 7, season: 3, order: 200, syncID: 3, episode: 3,
                album: "Show", keyName: "3", title: "C"),
            row(albumPID: 7, season: 3, order: 200, syncID: 4, episode: 4,
                album: "Show", keyName: "3", title: "D"),
        ].joined(separator: "\n")

        XCTAssertEqual(parseSeasonOrderSplits(text)[0].minority.map(\.syncID), [1, 2])
    }

    // MARK: - grouping

    func testHealthyMultiSeasonShowInOneAlbumIsNotASplit() {
        // The real shape, measured 2026-08-14: because `item.album` is the
        // show name with no season suffix, EVERY season lands in ONE album
        // row. Seasons 1, 2 and 10 correctly carry album_order "1"/"2"/"10".
        // Grouping by album_pid alone reads that as a three-way split and
        // tells the user to delete and re-upload two perfectly good seasons.
        let text = [
            row(albumPID: 1, season: 1, order: 100, syncID: 1, episode: 1,
                album: "The Show", keyName: "1", title: "S1E1"),
            row(albumPID: 1, season: 2, order: 200, syncID: 2, episode: 1,
                album: "The Show", keyName: "2", title: "S2E1"),
            row(albumPID: 1, season: 10, order: 300, syncID: 3, episode: 1,
                album: "The Show", keyName: "10", title: "S10E1"),
        ].joined(separator: "\n")

        XCTAssertTrue(parseSeasonOrderSplits(text).isEmpty,
                      "distinct seasons in one album row are correct, not a split")
    }

    func testOnlyTheSplitSeasonIsReportedWhenAnotherSeasonIsHealthy() {
        // Same album row throughout. Season 1 is split across two keys;
        // season 2 is clean and must be left alone.
        let text = [
            row(albumPID: 1, season: 1, order: 100, syncID: 1, episode: 1,
                album: "The Show", keyName: "the show", title: "S1E1"),
            row(albumPID: 1, season: 1, order: 150, syncID: 2, episode: 2,
                album: "The Show", keyName: "1", title: "S1E2"),
            row(albumPID: 1, season: 2, order: 200, syncID: 3, episode: 1,
                album: "The Show", keyName: "2", title: "S2E1"),
            row(albumPID: 1, season: 2, order: 200, syncID: 4, episode: 2,
                album: "The Show", keyName: "2", title: "S2E2"),
        ].joined(separator: "\n")

        let splits = parseSeasonOrderSplits(text)
        XCTAssertEqual(splits.count, 1, "only the split season should be reported")
        XCTAssertEqual(splits[0].seasonNumber, 1)
        XCTAssertEqual(splits[0].minority.map(\.syncID), [1])
    }

    func testUniformAlbumOrderIsNotASplit() {
        let text = [
            row(albumPID: 1, season: 1, order: 100, syncID: 1, episode: 1,
                album: "Show", keyName: "1", title: "A"),
            row(albumPID: 1, season: 1, order: 100, syncID: 2, episode: 2,
                album: "Show", keyName: "1", title: "B"),
        ].joined(separator: "\n")
        XCTAssertTrue(parseSeasonOrderSplits(text).isEmpty)
    }

    // MARK: - ownership

    func testAlbumWithNoRowsOfOursIsIgnored() {
        // sync_id 0 = not shipped by us. Apple's own split is not ours.
        let text = [
            row(albumPID: 1, season: 1, order: 100, syncID: 0, episode: 1,
                album: "Apple Show", keyName: "apple show", title: "A"),
            row(albumPID: 1, season: 1, order: 200, syncID: 0, episode: 2,
                album: "Apple Show", keyName: "1", title: "B"),
        ].joined(separator: "\n")
        XCTAssertTrue(parseSeasonOrderSplits(text).isEmpty)
    }

    func testMinorityNeverIncludesRowsWeDidNotShip() {
        let text = [
            row(albumPID: 1, season: 1, order: 100, syncID: 0, episode: 1,
                album: "Mixed", keyName: "mixed", title: "theirs"),
            row(albumPID: 1, season: 1, order: 100, syncID: 5, episode: 2,
                album: "Mixed", keyName: "mixed", title: "ours"),
            row(albumPID: 1, season: 1, order: 200, syncID: 6, episode: 3,
                album: "Mixed", keyName: "1", title: "ours too"),
        ].joined(separator: "\n")

        let split = parseSeasonOrderSplits(text)[0]
        XCTAssertEqual(split.minority.map(\.syncID), [5],
                       "sync_id 0 rows can't be delete_track'd, so never name them")
    }

    func testSplitWhoseLosingSideIsAllTheirsReportsNoEpisodes() {
        let text = [
            row(albumPID: 1, season: 1, order: 100, syncID: 0, episode: 1,
                album: "Mixed", keyName: "mixed", title: "theirs"),
            row(albumPID: 1, season: 1, order: 200, syncID: 9, episode: 2,
                album: "Mixed", keyName: "1", title: "ours"),
        ].joined(separator: "\n")

        let splits = parseSeasonOrderSplits(text)
        XCTAssertEqual(splits.count, 1)
        XCTAssertTrue(splits[0].minority.isEmpty)
    }

    // MARK: - text safety

    func testTabsAndNewlinesInTitlesCannotShiftFields() {
        // The whole reason text is hex-encoded. A raw tab here would push
        // album_order into a text field and silently drop the row.
        let nasty = "Ep\twith\ttabs\nand a newline"
        let text = [
            row(albumPID: 1, season: 1, order: 100, syncID: 1, episode: 1,
                album: "Sh\tow", keyName: "sh\tow", title: nasty),
            row(albumPID: 1, season: 1, order: 200, syncID: 2, episode: 2,
                album: "Sh\tow", keyName: "1", title: "clean"),
        ].joined(separator: "\n")

        let splits = parseSeasonOrderSplits(text)
        XCTAssertEqual(splits.count, 1)
        XCTAssertEqual(splits[0].album, "Sh\tow")
        XCTAssertEqual(splits[0].minority.map(\.title), [nasty])
    }

    func testNoSeasonNumberKeyPresentFallsBackToMajorityDeterministically() {
        // Neither key is String(season) — e.g. an album whose season_number
        // never landed. Falls back to row count, and the result must not
        // depend on Dictionary iteration order.
        let text = [
            row(albumPID: 1, season: 9, order: 300, syncID: 1, episode: 1,
                album: "S", keyName: "aaa", title: "A"),
            row(albumPID: 1, season: 9, order: 300, syncID: 2, episode: 2,
                album: "S", keyName: "aaa", title: "B"),
            row(albumPID: 1, season: 9, order: 100, syncID: 3, episode: 3,
                album: "S", keyName: "bbb", title: "C"),
        ].joined(separator: "\n")

        for _ in 0..<20 {
            XCTAssertEqual(parseSeasonOrderSplits(text)[0].minority.map(\.syncID), [3])
        }
    }

    func testMalformedLinesAreSkippedNotCrashed() {
        let text = [
            "garbage",
            "1\t2\t3",                       // too few fields
            row(albumPID: 1, season: 1, order: 100, syncID: 1, episode: 1,
                album: "Show", keyName: "show", title: "A"),
            row(albumPID: 1, season: 1, order: 200, syncID: 2, episode: 2,
                album: "Show", keyName: "1", title: "B"),
        ].joined(separator: "\n")

        XCTAssertEqual(parseSeasonOrderSplits(text).count, 1)
    }

    func testEmptyInput() {
        XCTAssertTrue(parseSeasonOrderSplits("").isEmpty)
    }
}
