import XCTest
@testable import HubPlus

final class StatsCacheTests: XCTestCase {
    func testDailyTokensSumsModelsAndFillsGaps() {
        let json = #"{"dailyModelTokens":{"2026-06-30":{"opus":100,"sonnet":50},"2026-06-28":{"opus":7}}}"#.data(using: .utf8)!
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!
        let today = c.date(from: DateComponents(year: 2026, month: 6, day: 30))!
        let out = StatsCache.dailyTokens(days: 3, json: json, today: today, calendar: c)
        XCTAssertEqual(out.map { $0.tokens }, [7, 0, 150])   // 28th, 29th, 30th
    }
}
