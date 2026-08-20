// Grouping / survivor choice for the collapsed-season detector.
//
// A "collapsed season" is the mirror image of a split: two or more seasons of
// one show sharing a SINGLE `item.album_order`, which makes TV.app draw ONE
// section holding every season with `episode_sort_id` repeating. It happens
// when medialibraryd stamped the order from the album's sort string — the old
// `sort_album = showName` behaviour — and both seasons arrived in one batch.
//
// `parseSeasonOrderSplits` is blind to this by construction: it groups by
// (album, season) and asks for >1 distinct order, and here every season has
// exactly one. Observed on AkmPad12 2026-08-20 — Attack on Titan seasons 2 and
// 3, both on order 751619276800 under key "attack on titan", which heal
// reported as clean.
//
// Row format is the shared SELECT, tab-separated:
//   album_pid, season_number, album_order, sync_id, episode_sort_id,
//   hex(album), hex(sort_map name), hex(title)

import XCTest
@testable import MediaPorterCore

final class SeasonOrderCollapseTests: XCTestCase {

    private func hex(_ s: String) -> String {
        s.utf8.map { String(format: "%02X", $0) }.joined()
    }

    private func row(albumPID: Int64, season: Int, order: Int64, syncID: Int64,
                     episode: Int, album: String, keyName: String,
                     title: String) -> String {
        [String(albumPID), String(season), String(order), String(syncID),
         String(episode), hex(album), hex(keyName), hex(title)]
            .joined(separator: "\t")
    }

    // MARK: - the bug this detector exists for

    /// The AkmPad12 shape: two seasons, one show-name key, one order.
    func testReportsTwoSeasonsSharingOneOrder() {
        let text = [
            row(albumPID: 1, season: 2, order: 751, syncID: 11, episode: 1,
                album: "Attack on Titan", keyName: "attack on titan", title: "S2E01"),
            row(albumPID: 1, season: 3, order: 751, syncID: 21, episode: 1,
                album: "Attack on Titan", keyName: "attack on titan", title: "S3E01"),
            row(albumPID: 1, season: 3, order: 751, syncID: 22, episode: 2,
                album: "Attack on Titan", keyName: "attack on titan", title: "S3E02"),
        ].joined(separator: "\n")

        let collapses = parseSeasonOrderCollapses(text)
        XCTAssertEqual(collapses.count, 1)
        XCTAssertEqual(collapses[0].album, "Attack on Titan")
        XCTAssertEqual(collapses[0].seasons, [2, 3])
        XCTAssertEqual(collapses[0].keyName, "attack on titan")
        // Season 3 has more rows, so keeping it means the fewest re-uploads.
        XCTAssertEqual(collapses[0].keptSeason, 3)
        XCTAssertEqual(collapses[0].minority.map(\.syncID), [11])
    }

    /// A season already sitting on its own season-number key must be the one
    /// kept even when it is the smaller side — its order IS the target, so
    /// re-syncing it would move it back to where it already is.
    func testKeepsTheCorrectlyKeyedSeasonOverTheLargerOne() {
        let text = [
            row(albumPID: 1, season: 2, order: 500, syncID: 11, episode: 1,
                album: "Show", keyName: "2", title: "S2E01"),
            row(albumPID: 1, season: 5, order: 500, syncID: 21, episode: 1,
                album: "Show", keyName: "2", title: "S5E01"),
            row(albumPID: 1, season: 5, order: 500, syncID: 22, episode: 2,
                album: "Show", keyName: "2", title: "S5E02"),
        ].joined(separator: "\n")

        let collapses = parseSeasonOrderCollapses(text)
        XCTAssertEqual(collapses.count, 1)
        XCTAssertEqual(collapses[0].keptSeason, 2, "season 2 is already on key \"2\"")
        XCTAssertEqual(collapses[0].minority.map(\.syncID), [21, 22])
    }

    // MARK: - what must NOT be reported

    /// The healthy multi-season shape: each season on its own order. This is
    /// what every correctly-synced show looks like, so a false positive here
    /// would tell users to re-upload a good library.
    func testSeasonsOnDistinctOrdersAreNotACollapse() {
        let text = [
            row(albumPID: 1, season: 1, order: 749, syncID: 11, episode: 1,
                album: "Twin Peaks", keyName: "1", title: "S1E01"),
            row(albumPID: 1, season: 2, order: 751, syncID: 21, episode: 1,
                album: "Twin Peaks", keyName: "2", title: "S2E01"),
        ].joined(separator: "\n")

        XCTAssertTrue(parseSeasonOrderCollapses(text).isEmpty)
    }

    /// One season on one order is the ordinary case, not a collapse.
    func testSingleSeasonIsNotACollapse() {
        let text = row(albumPID: 1, season: 1, order: 749, syncID: 11, episode: 1,
                       album: "Lanterns", keyName: "1", title: "Pilot")
        XCTAssertTrue(parseSeasonOrderCollapses(text).isEmpty)
    }

    /// Two different shows can share an order without interfering — the album
    /// is part of the grouping key. Grouping on order alone would report a
    /// cross-show collapse that TV.app never draws.
    func testDifferentAlbumsOnTheSameOrderAreIndependent() {
        let text = [
            row(albumPID: 1, season: 1, order: 749, syncID: 11, episode: 1,
                album: "Show A", keyName: "1", title: "A1"),
            row(albumPID: 2, season: 1, order: 749, syncID: 21, episode: 1,
                album: "Show B", keyName: "1", title: "B1"),
        ].joined(separator: "\n")

        XCTAssertTrue(parseSeasonOrderCollapses(text).isEmpty)
    }

    /// Apple's own content has sync_id 0 and is not ours to repair.
    func testCollapseWithNothingWeShippedIsIgnored() {
        let text = [
            row(albumPID: 1, season: 1, order: 749, syncID: 0, episode: 1,
                album: "Apple Show", keyName: "apple show", title: "E1"),
            row(albumPID: 1, season: 2, order: 749, syncID: 0, episode: 1,
                album: "Apple Show", keyName: "apple show", title: "E2"),
        ].joined(separator: "\n")

        XCTAssertTrue(parseSeasonOrderCollapses(text).isEmpty)
    }

    /// A collapse whose every re-syncable row belongs to the kept season leaves
    /// nothing to act on — reporting it would be advice the user cannot follow.
    func testCollapseIsIgnoredWhenOnlyTheKeptSeasonIsOurs() {
        let text = [
            row(albumPID: 1, season: 1, order: 749, syncID: 11, episode: 1,
                album: "Mixed", keyName: "1", title: "Ours"),
            row(albumPID: 1, season: 2, order: 749, syncID: 0, episode: 1,
                album: "Mixed", keyName: "1", title: "Apple's"),
        ].joined(separator: "\n")

        XCTAssertTrue(parseSeasonOrderCollapses(text).isEmpty)
    }

    // MARK: - parsing robustness

    /// Titles carrying tabs/newlines are why every text column is hex-encoded;
    /// a raw title would shift the numeric fields and corrupt the verdict.
    func testTitleWithTabsAndNewlinesDoesNotShiftFields() {
        let nasty = "Ep\t01\nwith\tcontrol chars"
        let text = [
            row(albumPID: 1, season: 2, order: 751, syncID: 11, episode: 1,
                album: "Show", keyName: "show", title: nasty),
            row(albumPID: 1, season: 3, order: 751, syncID: 21, episode: 1,
                album: "Show", keyName: "show", title: "S3E01"),
        ].joined(separator: "\n")

        let collapses = parseSeasonOrderCollapses(text)
        XCTAssertEqual(collapses.count, 1)
        XCTAssertEqual(collapses[0].seasons, [2, 3])
        XCTAssertTrue(collapses[0].minority.contains { $0.title == nasty }
                        || collapses[0].keptSeason == 2)
    }

    func testEmptyInputYieldsNothing() {
        XCTAssertTrue(parseSeasonOrderCollapses("").isEmpty)
    }

    /// Ties on row count resolve to the lowest season so two runs over the same
    /// library never disagree about what to re-sync.
    func testEqualCountsBreakTieOnLowestSeason() {
        let text = [
            row(albumPID: 1, season: 4, order: 751, syncID: 11, episode: 1,
                album: "Show", keyName: "show", title: "S4E01"),
            row(albumPID: 1, season: 2, order: 751, syncID: 21, episode: 1,
                album: "Show", keyName: "show", title: "S2E01"),
        ].joined(separator: "\n")

        XCTAssertEqual(parseSeasonOrderCollapses(text)[0].keptSeason, 2)
    }
}
