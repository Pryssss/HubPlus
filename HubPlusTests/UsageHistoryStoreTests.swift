import XCTest
@testable import HubPlus

final class UsageHistoryStoreTests: XCTestCase {
    func tmp() -> URL { URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString + ".json") }

    func testRecordAndSeries() {
        var clock = 1000.0
        let s = UsageHistoryStore(fileURL: tmp(), now: { clock })
        s.record(five: 10, seven: 5); clock = 1060
        s.record(five: 12, seven: 6)
        XCTAssertEqual(s.fiveSeries().map { $0.util }, [10, 12])
        XCTAssertEqual(s.sevenSeries().last?.util, 6)
    }

    func testRingTrim() {
        var clock = 0.0
        let s = UsageHistoryStore(fileURL: tmp(), ringSeconds: 100, now: { clock })
        s.record(five: 1, seven: 1)           // t=0
        clock = 250
        s.record(five: 2, seven: 2)           // t=250, drops t=0 (>100s old)
        XCTAssertEqual(s.samples.count, 1)
        XCTAssertEqual(s.samples.first?.five, 2)
    }

    func testPersistAcrossInstances() {
        let url = tmp()
        var clock = 500.0
        let a = UsageHistoryStore(fileURL: url, now: { clock }); a.record(five: 7, seven: 3)
        a.waitForPendingIO()
        let b = UsageHistoryStore(fileURL: url, now: { clock })
        XCTAssertEqual(b.samples.first?.five, 7)
    }

    func testCorruptFileStartsEmpty() {
        let url = tmp()
        try? "not json".data(using: .utf8)!.write(to: url)
        let s = UsageHistoryStore(fileURL: url, now: { 0 })
        XCTAssertTrue(s.samples.isEmpty)
    }
}
