// The ledger decides when the app is allowed to delete a row from the user's
// library, so the escalation rule gets tested directly rather than only being
// exercised through a device. Each test uses its own synthetic UDID and resets
// in tearDown — UserDefaults is process-wide and persists between runs.
//
// The device-touching half (`healStuckAssets`) isn't covered here; it needs a
// real MediaLibrary.sqlitedb to classify rows as bound/unbound. Its gating is
// exercised by `mediaporterctl heal --dry-run`.

import XCTest
@testable import MediaPorterCore

final class StuckAssetLedgerTests: XCTestCase {

    private let udid = "TEST-LEDGER-UDID"

    override func setUp() {
        super.setUp()
        StuckAssetLedger.reset(udid: udid)
    }

    override func tearDown() {
        StuckAssetLedger.reset(udid: udid)
        super.tearDown()
    }

    func testFirstSightingIsNotEscalatable() {
        // One sighting means "seen, FileError(0) sent" — we don't yet know
        // whether it worked, so nothing may be deleted.
        let escalated = StuckAssetLedger.recordManifest(staleIDs: ["1001"], udid: udid)
        XCTAssertTrue(escalated.isEmpty)
        XCTAssertEqual(StuckAssetLedger.all(udid: udid), [1001: 1])
        XCTAssertTrue(StuckAssetLedger.escalatable(udid: udid).isEmpty)
    }

    func testSecondSightingEscalates() {
        // Reappearing after a FileError(0) is the expired-asset signature.
        StuckAssetLedger.recordManifest(staleIDs: ["1001"], udid: udid)
        let escalated = StuckAssetLedger.recordManifest(staleIDs: ["1001"], udid: udid)
        XCTAssertEqual(escalated, [1001])
        XCTAssertEqual(StuckAssetLedger.escalatable(udid: udid), [1001])
    }

    func testDisappearingIDIsRetiredNotEscalated() {
        // FileError(0) worked: the ID is gone from the next manifest. It must
        // NOT keep its history, or a later unrelated sighting would count as
        // a second one and make a healthy asset deletable.
        StuckAssetLedger.recordManifest(staleIDs: ["1001"], udid: udid)
        StuckAssetLedger.recordManifest(staleIDs: [], udid: udid)
        XCTAssertTrue(StuckAssetLedger.all(udid: udid).isEmpty)

        let escalated = StuckAssetLedger.recordManifest(staleIDs: ["1001"], udid: udid)
        XCTAssertTrue(escalated.isEmpty, "a re-sighting after a successful clear starts from zero")
    }

    func testCountsAreTrackedPerID() {
        StuckAssetLedger.recordManifest(staleIDs: ["1001", "1002"], udid: udid)
        let escalated = StuckAssetLedger.recordManifest(staleIDs: ["1002", "1003"], udid: udid)
        XCTAssertEqual(escalated, [1002])
        XCTAssertEqual(StuckAssetLedger.all(udid: udid), [1002: 2, 1003: 1],
                       "1001 cleared, 1002 survived a FileError(0), 1003 is new")
    }

    func testLedgersAreIsolatedPerDevice() {
        let other = "TEST-LEDGER-UDID-2"
        defer { StuckAssetLedger.reset(udid: other) }
        StuckAssetLedger.recordManifest(staleIDs: ["1001"], udid: udid)
        StuckAssetLedger.recordManifest(staleIDs: ["1001"], udid: other)
        // Same ID, different devices — neither should inherit the other's count.
        XCTAssertTrue(StuckAssetLedger.escalatable(udid: udid).isEmpty)
        XCTAssertTrue(StuckAssetLedger.escalatable(udid: other).isEmpty)
    }

    func testForgetDropsResolvedIDs() {
        StuckAssetLedger.recordManifest(staleIDs: ["1001", "1002"], udid: udid)
        StuckAssetLedger.recordManifest(staleIDs: ["1001", "1002"], udid: udid)
        StuckAssetLedger.forget([1001], udid: udid)
        XCTAssertEqual(StuckAssetLedger.escalatable(udid: udid), [1002])
    }
}
