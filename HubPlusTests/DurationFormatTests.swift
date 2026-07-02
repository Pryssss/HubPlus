import XCTest
@testable import HubPlus

final class DurationFormatTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func ms(secondsAgo: Double) -> Double { (1_000_000 - secondsAgo) * 1000 }

    func testNilInputAndUnderAMinuteAreHidden() {
        XCTAssertNil(DurationFormat.compactSince(nil, now: now))
        XCTAssertNil(DurationFormat.compactSince(ms(secondsAgo: 59), now: now))
    }

    func testMinutesHoursDays() {
        XCTAssertEqual(DurationFormat.compactSince(ms(secondsAgo: 60), now: now), "1m")
        XCTAssertEqual(DurationFormat.compactSince(ms(secondsAgo: 12 * 60), now: now), "12m")
        XCTAssertEqual(DurationFormat.compactSince(ms(secondsAgo: 3 * 3600 + 40), now: now), "3h")
        XCTAssertEqual(DurationFormat.compactSince(ms(secondsAgo: 2 * 86400 + 100), now: now), "2d")
    }

    func testFutureTimestampIsHidden() {
        XCTAssertNil(DurationFormat.compactSince(ms(secondsAgo: -30), now: now))
    }
}
