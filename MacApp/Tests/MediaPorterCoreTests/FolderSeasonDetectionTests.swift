// Folder-driven season/episode detection, exercised through `addFiles` rather
// than through the parser helpers alone.
//
// The helpers had unit tests; the pass that *uses* them did not, and that's
// where the interesting decisions live — which of the two detection passes wins,
// what the evidence floor is, and whether the folder's season number survives.

import XCTest
@testable import MediaPorterCore

@MainActor
final class FolderSeasonDetectionTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("folderseason-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Create `folder/names…` as empty files and run them through `addFiles`.
    /// Returns the resulting overrides keyed by filename.
    private func detect(folder: String, _ names: [String]) throws -> [String: ParsedFilename] {
        // Each call gets its own parent so two folders may share a name.
        let dir = root
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent(folder)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var urls: [URL] = []
        for name in names {
            let url = dir.appendingPathComponent(name)
            try Data().write(to: url)
            urls.append(url)
        }
        let pipeline = PipelineController()
        pipeline.addFiles(urls: urls)
        var out: [String: ParsedFilename] = [:]
        for job in pipeline.jobs {
            if let o = job.parsedOverride { out[job.inputURL.lastPathComponent] = o }
        }
        return out
    }

    // MARK: The case this all started from

    func testSingleEpisodeInCyrillicSeasonFolder() throws {
        let got = try detect(folder: "Фонари (Сезон 1)", ["Фонари 1.WEB-DLRip.avi"])
        let o = try XCTUnwrap(got["Фонари 1.WEB-DLRip.avi"])
        XCTAssertEqual(o.title, "Фонари")
        XCTAssertEqual(o.season, 1)
        XCTAssertEqual(o.episode, 1)
        XCTAssertEqual(o.mediaType, .tvShow)
    }

    func testSeasonNumberInFolderIsInverted() throws {
        let got = try detect(folder: "Фонари (1 сезон)", ["Фонари 1.WEB-DLRip.avi"])
        XCTAssertEqual(got["Фонари 1.WEB-DLRip.avi"]?.season, 1)
    }

    /// Russian trackers put the local title beside the original one.
    func testAltTitleParenthesesAreDropped() throws {
        let got = try detect(folder: "Фонари (The Lights) (Сезон 1)", ["Фонари 1.WEB-DLRip.avi"])
        XCTAssertEqual(got["Фонари 1.WEB-DLRip.avi"]?.title, "Фонари")
    }

    func testEpisodeCountAfterSeasonNumber() throws {
        let got = try detect(folder: "Фонари (Сезон 3, 8 серий)", ["Фонари 1.WEB-DLRip.avi"])
        XCTAssertEqual(got["Фонари 1.WEB-DLRip.avi"]?.season, 3)
    }

    // MARK: The floor

    /// "E5 Historia.mkv" names no show, so it can't corroborate the folder. A
    /// folder that merely contains the words "Season 1" must not rename a stray
    /// file after itself.
    func testUncorroboratedSingleFileIsLeftAlone() throws {
        let got = try detect(folder: "My Season 1 Rips", ["E5 Historia.mkv"])
        XCTAssertTrue(got.isEmpty, "got \(got)")
    }

    /// Same shape, but three of them — the original evidence bar.
    func testThreeUncorroboratedEpisodesStillDetected() throws {
        let got = try detect(
            folder: "Shingeki no Kyojin S2 60 FPS",
            ["E1 Beast Titan.mkv", "E2 I'm Home.mkv", "E3 Southwestward.mkv"]
        )
        XCTAssertEqual(got.count, 3)
        XCTAssertEqual(got["E1 Beast Titan.mkv"]?.title, "Shingeki no Kyojin")
        XCTAssertEqual(got["E1 Beast Titan.mkv"]?.season, 2)
    }

    /// A filename carrying its own year is a movie making a positive claim.
    func testYearBearingMovieSurvivesASeasonFolder() throws {
        let got = try detect(folder: "Dune (Season 1)", ["Dune 2.2024.1080p.mkv"])
        XCTAssertTrue(got.isEmpty, "got \(got)")
    }

    /// A resolution sits exactly where an episode number would.
    func testResolutionIsNotAnEpisodeNumber() throws {
        let got = try detect(folder: "Фонари (Сезон 1)", ["Фонари 720 WEB-DLRip.avi"])
        XCTAssertTrue(got.isEmpty, "got \(got)")
    }

    // MARK: Pass ordering

    /// The plain-numbered pass runs first and `detectFolderTitledSeason` skips
    /// anything it already claimed, so the season it writes has to be the
    /// folder's — not a hardcoded 1. A wrong season here splits a show across
    /// two "Season N" headers in TV.app (CLAUDE.md #6).
    func testPlainNumberedPassTakesSeasonFromFolder() throws {
        let got = try detect(
            folder: "Фонари (Сезон 2)",
            ["Фонари 1.mkv", "Фонари 2.mkv", "Фонари 3.mkv"]
        )
        XCTAssertEqual(got.count, 3)
        for name in ["Фонари 1.mkv", "Фонари 2.mkv", "Фонари 3.mkv"] {
            XCTAssertEqual(got[name]?.season, 2, "\(name) landed in the wrong season")
        }
        XCTAssertEqual(got["Фонари 2.mkv"]?.episode, 2)
    }

    /// Dropping one file vs three from the same folder must agree on the season.
    func testSingleAndBatchDropAgreeOnSeason() throws {
        let one = try detect(folder: "Фонари (Сезон 2)", ["Фонари 1.WEB-DLRip.avi"])
        let many = try detect(
            folder: "Фонари (Сезон 2)",
            ["Фонари 1.mkv", "Фонари 2.mkv", "Фонари 3.mkv"]
        )
        XCTAssertEqual(one["Фонари 1.WEB-DLRip.avi"]?.season, 2)
        XCTAssertEqual(many["Фонари 1.mkv"]?.season, 2)
    }
}
