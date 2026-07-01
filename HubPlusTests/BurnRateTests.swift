import XCTest
@testable import HubPlus

final class BurnRateTests: XCTestCase {
    func testProjectsTimeToLimit() {
        // 10%/hour: util 70 now, 60 thirty min ago -> 20%/h -> (100-70)/20 = 1.5h
        let now = 10_000.0
        let s = [(t: now - 1800, util: 60.0), (t: now, util: 70.0)]
        let p = BurnRate.project(s, now: now)
        XCTAssertNotNil(p)
        XCTAssertEqual(p!.hoursLeft, 1.5, accuracy: 0.05)
        XCTAssertEqual(p!.label, "~1h")
    }
    func testNoProjectionWhenFlat() {
        let now = 10_000.0
        XCTAssertNil(BurnRate.project([(now-1800, 50), (now, 50)], now: now))
    }
    func testNoProjectionOnReset() {
        let now = 10_000.0
        // util dropped (window reset) -> nil
        XCTAssertNil(BurnRate.project([(now-1800, 90), (now, 10)], now: now))
    }
    func testMinutesLabel() {
        let now = 10_000.0
        // 90%/h burn, util 70 -> 0.33h -> ~20m
        let s = [(now-600, 60.0), (now, 70.0)]  // 10% in 10min = 60%/h; (100-70)/60=0.5h -> ~30m
        XCTAssertEqual(BurnRate.project(s, now: now)?.label, "~30m")
    }
    func testInsufficientSamples() {
        XCTAssertNil(BurnRate.project([(10_000, 50)], now: 10_000))
    }
    func testLeastSquaresWithLargeEpochTimestamps() {
        // 3-sample least-squares on realistic epoch values exercises the timestamp
        // centering that prevents catastrophic cancellation. Perfect 12%/h line → 4h.
        let now = 1_750_000_000.0
        let s = [(t: now - 3600, util: 40.0), (t: now - 1800, util: 46.0), (t: now, util: 52.0)]
        let p = BurnRate.project(s, now: now)
        XCTAssertNotNil(p)
        XCTAssertEqual(p!.hoursLeft, 4.0, accuracy: 0.2)
    }
    func testProjectsFromPostResetClimb() {
        // A reset mid-window (util drops 90→10) must not suppress the projection:
        // it should use the post-reset climb (10→20).
        let now = 5_000.0
        let s = [(t: now - 1200, util: 90.0), (t: now - 600, util: 10.0), (t: now, util: 20.0)]
        XCTAssertNotNil(BurnRate.project(s, now: now))
    }
}
