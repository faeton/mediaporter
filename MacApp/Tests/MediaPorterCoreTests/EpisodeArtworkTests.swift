// Regression coverage for the P0 episode-artwork fixes:
//   1. ResolvedMetadata.posterData returns the per-episode still first,
//      not the show portrait — otherwise TV.app squishes the 2:3 portrait
//      into the 16:9 episode tile (the visible "every episode shows the
//      same poster" bug).
//   2. PosterGenerator.generateLandscape produces a 16:9 JPEG so text-only
//      fallbacks for TV episodes don't get the same squish treatment.
//
// StillExtractor isn't covered here — it requires a real video fixture and
// belongs in the manual end-to-end test plan in plan.md / task #4.

import XCTest
import AppKit
@testable import MediaPorterCore

final class EpisodeArtworkTests: XCTestCase {

    // MARK: - ResolvedMetadata.posterData accessor

    func testEpisodePosterPrefersStillOverShowPortrait() {
        let still = Data([0xDE, 0xAD]) // sentinel — "episode still"
        let portrait = Data([0xBE, 0xEF]) // sentinel — "show portrait"
        let meta = EpisodeMetadata(
            showName: "Show", season: 1, episode: 1,
            episodeTitle: nil, episodeID: "S01E01",
            year: nil, genre: nil, overview: nil, longOverview: nil,
            network: nil,
            posterURL: nil, posterData: still,
            showPosterURL: nil, showPosterData: portrait,
            tmdbShowID: nil
        )
        let resolved = ResolvedMetadata.tvEpisode(meta)
        XCTAssertEqual(resolved.posterData, still,
            "Episode still must win over show portrait — otherwise the 2:3 show poster gets squished into TV.app's 16:9 episode tile.")
    }

    func testEpisodePosterFallsBackToShowPortrait() {
        // When there's no episode still, the show portrait is still better
        // than nothing — tile will be wrong-aspect but at least correctly
        // identifies the show.
        let portrait = Data([0xBE, 0xEF])
        let meta = EpisodeMetadata(
            showName: "Show", season: 1, episode: 1,
            episodeTitle: nil, episodeID: "S01E01",
            year: nil, genre: nil, overview: nil, longOverview: nil,
            network: nil,
            posterURL: nil, posterData: nil,
            showPosterURL: nil, showPosterData: portrait,
            tmdbShowID: nil
        )
        XCTAssertEqual(ResolvedMetadata.tvEpisode(meta).posterData, portrait)
    }

    func testEpisodePosterNilWhenBothAbsent() {
        let meta = EpisodeMetadata(
            showName: "Show", season: 1, episode: 1,
            episodeTitle: nil, episodeID: "S01E01",
            year: nil, genre: nil, overview: nil, longOverview: nil,
            network: nil,
            posterURL: nil, posterData: nil,
            showPosterURL: nil, showPosterData: nil,
            tmdbShowID: nil
        )
        XCTAssertNil(ResolvedMetadata.tvEpisode(meta).posterData)
    }

    // MARK: - PosterGenerator landscape variant

    func testLandscapePosterIs16x9() throws {
        let data = try XCTUnwrap(PosterGenerator.generateLandscape(title: "Attack on Titan S01E01"))
        let img = try XCTUnwrap(NSBitmapImageRep(data: data))
        XCTAssertEqual(img.pixelsWide, 1280)
        XCTAssertEqual(img.pixelsHigh, 720)
    }

    func testPortraitPosterUnchanged() throws {
        // Movies still want 2:3 portrait — make sure the refactor didn't
        // accidentally rescale the original code path.
        let data = try XCTUnwrap(PosterGenerator.generate(title: "Inception", year: 2010))
        let img = try XCTUnwrap(NSBitmapImageRep(data: data))
        XCTAssertEqual(img.pixelsWide, 500)
        XCTAssertEqual(img.pixelsHigh, 750)
    }

    func testLandscapePosterEncodesJPEG() throws {
        let data = try XCTUnwrap(PosterGenerator.generateLandscape(title: "Show"))
        // JPEG SOI marker — a sanity check that we're returning a real
        // image, not a TIFF or empty buffer.
        XCTAssertGreaterThanOrEqual(data.count, 2)
        XCTAssertEqual(data[0], 0xFF)
        XCTAssertEqual(data[1], 0xD8)
    }
}
