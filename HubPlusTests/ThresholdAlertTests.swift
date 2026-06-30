import XCTest
@testable import HubPlus

final class ThresholdAlertTests: XCTestCase {
    func testCrossing() {
        XCTAssertTrue(AppStore.crossedLow(prev: 25, now: 18))
        XCTAssertFalse(AppStore.crossedLow(prev: 18, now: 15)) // already low
        XCTAssertFalse(AppStore.crossedLow(prev: 30, now: 22)) // still above
        XCTAssertTrue(AppStore.crossedLow(prev: nil, now: 10))
    }

    /// When percentLeft jumps from above-threshold straight to 0 (exhausted),
    /// crossedLow would return true — but check() guards on !exhausted before
    /// calling it, so only the "limit reached" notification fires, not "0% left".
    /// This test confirms the helper's return value for that scenario (the guard
    /// in check() is what prevents the double notification, not this helper).
    func testCrossedLowAtZeroWouldFire() {
        // crossedLow itself returns true when jumping from 100→0 (the guard in
        // check() suppresses the notification when exhausted is true).
        XCTAssertTrue(AppStore.crossedLow(prev: 100, now: 0))
        // Already exhausted on previous poll — stays exhausted, no low-cross.
        XCTAssertFalse(AppStore.crossedLow(prev: 0, now: 0))
    }
}
