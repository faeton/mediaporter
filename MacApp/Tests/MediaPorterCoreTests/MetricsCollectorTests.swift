// Verifies the counter store the weekly heartbeat drains from. Each test
// resets first because UserDefaults is process-wide and persists between
// invocations.

import XCTest
@testable import MediaPorterCore

final class MetricsCollectorTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MetricsCollector.reset()
    }

    func testBumpAccumulates() {
        MetricsCollector.bump("launches")
        MetricsCollector.bump("files_added", by: 7)
        MetricsCollector.bump("files_added", by: 3)
        let s = MetricsCollector.snapshot()
        XCTAssertEqual(s["launches"], 1)
        XCTAssertEqual(s["files_added"], 10)
    }

    func testResetClearsBoth() {
        MetricsCollector.bump("syncs_ok", by: 5)
        XCTAssertEqual(MetricsCollector.snapshot()["syncs_ok"], 5)
        MetricsCollector.reset()
        XCTAssertTrue(MetricsCollector.snapshot().isEmpty)
        // Survives a fresh read — proves UserDefaults was wiped, not just the cache.
        XCTAssertNil(UserDefaults.standard.dictionary(forKey: "metricsCounters"))
    }

    func testPersistsAcrossSnapshots() {
        MetricsCollector.bump("transcodes_ok", by: 4)
        XCTAssertEqual(MetricsCollector.snapshot()["transcodes_ok"], 4)
        // The same in-memory cache should keep returning the value.
        XCTAssertEqual(MetricsCollector.snapshot()["transcodes_ok"], 4)
    }

    func testBucketBoundaries() {
        XCTAssertEqual(MetricsCollector.bucket(-1), "0")
        XCTAssertEqual(MetricsCollector.bucket(0), "0")
        XCTAssertEqual(MetricsCollector.bucket(1), "1")
        XCTAssertEqual(MetricsCollector.bucket(2), "2-5")
        XCTAssertEqual(MetricsCollector.bucket(5), "2-5")
        XCTAssertEqual(MetricsCollector.bucket(6), "6-20")
        XCTAssertEqual(MetricsCollector.bucket(20), "6-20")
        XCTAssertEqual(MetricsCollector.bucket(21), "21-100")
        XCTAssertEqual(MetricsCollector.bucket(100), "21-100")
        XCTAssertEqual(MetricsCollector.bucket(101), "101-500")
        XCTAssertEqual(MetricsCollector.bucket(287), "101-500")
        XCTAssertEqual(MetricsCollector.bucket(500), "101-500")
        XCTAssertEqual(MetricsCollector.bucket(501), "500+")
        XCTAssertEqual(MetricsCollector.bucket(9999), "500+")
    }
}
