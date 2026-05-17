// Regression coverage for the apply-to-all cluster-extras preservation
// fix (PipelineController.captureClusterSelection, commit 87a9425).
//
// Bug being fenced off: ClusterSelection.capture(from:) rebuilds intent
// from a single job's per-row state and can't see cluster-wide fields
// (includedDubStudios / includedSubLabels / defaultAudioStudio /
// burnInSubLang when only resolvable via extras). Writing capture()'s
// output back into clusterSelections[cid] verbatim wipes those fields
// for every sibling — observed 2026-05-17 with Odd Taxi ep10 losing its
// external rus.srt after an apply-to-all from ep1.

import XCTest
@testable import MediaPorterCore

@MainActor
final class ClusterSelectionCaptureTests: XCTestCase {

    /// captureClusterSelection must preserve cluster-extras intent
    /// (includedDubStudios, includedSubLabels, defaultAudioStudio) that
    /// the per-job capture() cannot reconstruct from a single FileJob.
    func testCaptureClusterSelectionPreservesExternalTrackIntent() {
        let pc = PipelineController()

        let job = FileJob(url: URL(fileURLWithPath: "/tmp/nonexistent-show-s01e01.mkv"))
        job.clusterID = "test-show:2026"
        pc.jobs = [job]

        var existing = ClusterSelection()
        existing.includedDubStudios = ["AniDub", "AniLibria"]
        existing.includedSubLabels = ["AniLibria-rus"]
        existing.defaultAudioStudio = "AniDub"
        pc.clusterSelections["test-show:2026"] = existing

        pc.captureClusterSelection(from: job, propagate: false)

        let after = pc.clusterSelections["test-show:2026"]
        XCTAssertEqual(after?.includedDubStudios, ["AniDub", "AniLibria"],
            "includedDubStudios wiped — apply-to-all would drop every sibling's external dub")
        XCTAssertEqual(after?.includedSubLabels, ["AniLibria-rus"],
            "includedSubLabels wiped — apply-to-all would drop external subs (Odd Taxi ep10 case)")
        XCTAssertEqual(after?.defaultAudioStudio, "AniDub",
            "defaultAudioStudio wiped — the user's chosen default-audio mark would vanish on apply-to-all")
    }

    /// burnInSubLang can be cluster-extras-derived (a language only present
    /// in extras.subs, not in any job's embedded streams). When fresh capture
    /// can't resolve a burn-in from the current job, the previous cluster
    /// value must survive. When fresh capture DOES resolve one, it should win.
    func testCaptureClusterSelectionPreservesBurnInSubLangWhenFreshIsNil() {
        let pc = PipelineController()
        let job = FileJob(url: URL(fileURLWithPath: "/tmp/nonexistent-show-s01e02.mkv"))
        job.clusterID = "test-show:2026"
        // mediaInfo stays nil → capture() returns a blank ClusterSelection
        // with burnInSubLang == nil. Preservation must kick in.
        pc.jobs = [job]

        var existing = ClusterSelection()
        existing.burnInSubLang = "rus"
        pc.clusterSelections["test-show:2026"] = existing

        pc.captureClusterSelection(from: job, propagate: false)

        XCTAssertEqual(pc.clusterSelections["test-show:2026"]?.burnInSubLang, "rus",
            "burnInSubLang dropped to nil — a working cluster-extras burn-in would be silently lost on apply-to-all")
    }

    /// Sanity: an empty pre-existing entry doesn't generate ghost values.
    /// (No regression target — just confirms preservation isn't injecting
    /// garbage when there's nothing to preserve.)
    func testCaptureClusterSelectionWithNoPriorEntryYieldsEmptyExtras() {
        let pc = PipelineController()
        let job = FileJob(url: URL(fileURLWithPath: "/tmp/nonexistent-show-s01e03.mkv"))
        job.clusterID = "test-show:2026"
        pc.jobs = [job]
        // No prior clusterSelections entry.

        pc.captureClusterSelection(from: job, propagate: false)

        let after = pc.clusterSelections["test-show:2026"]
        XCTAssertNotNil(after)
        XCTAssertTrue(after?.includedDubStudios.isEmpty ?? false)
        XCTAssertTrue(after?.includedSubLabels.isEmpty ?? false)
        XCTAssertNil(after?.defaultAudioStudio)
        XCTAssertNil(after?.burnInSubLang)
    }
}
