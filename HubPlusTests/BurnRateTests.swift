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
}
