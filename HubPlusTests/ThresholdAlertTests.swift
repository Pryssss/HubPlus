import XCTest
@testable import HubPlus

final class ThresholdAlertTests: XCTestCase {
    func testCrossing() {
        XCTAssertTrue(AppStore.crossedLow(prev: 25, now: 18))
        XCTAssertFalse(AppStore.crossedLow(prev: 18, now: 15)) // already low
        XCTAssertFalse(AppStore.crossedLow(prev: 30, now: 22)) // still above
        XCTAssertTrue(AppStore.crossedLow(prev: nil, now: 10))
    }
}
