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

    func testDailyTokensHandlesScalarIntShape() {
        // Stats-cache can store a plain Int or Double for a day instead of a model map.
        // The bar chart must show the correct value, not silently 0.
        let json = #"{"dailyModelTokens":{"2026-06-30":12345,"2026-06-29":999.0}}"#.data(using: .utf8)!
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!
        let today = c.date(from: DateComponents(year: 2026, month: 6, day: 30))!
        let out = StatsCache.dailyTokens(days: 2, json: json, today: today, calendar: c)
        XCTAssertEqual(out.map { $0.tokens }, [999, 12345])   // 29th, 30th
    }

    func testDailyTokensKeysAreGregorianRegardlessOfSystemCalendar() {
        // The cache always stores Gregorian ASCII keys. A non-Gregorian system
        // calendar must not make every lookup miss (chart silently 0).
        let json = #"{"dailyModelTokens":{"2026-06-30":{"opus":42}}}"#.data(using: .utf8)!
        var greg = Calendar(identifier: .gregorian); greg.timeZone = TimeZone(identifier: "UTC")!
        let today = greg.date(from: DateComponents(year: 2026, month: 6, day: 30))!
        var buddhist = Calendar(identifier: .buddhist); buddhist.timeZone = TimeZone(identifier: "UTC")!
        let out = StatsCache.dailyTokens(days: 1, json: json, today: today, calendar: buddhist)
        XCTAssertEqual(out.last?.tokens, 42)   // would be 0 if keyed with the Buddhist year 2569
    }
}
