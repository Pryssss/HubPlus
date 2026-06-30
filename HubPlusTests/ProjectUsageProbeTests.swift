import XCTest
@testable import HubPlus

final class ProjectUsageProbeTests: XCTestCase {
    func testSumTokensRespectsTimestampAndFields() {
        let lines = [
            #"{"timestamp":"2026-06-30T10:00:00Z","message":{"usage":{"input_tokens":10,"output_tokens":5,"cache_creation_input_tokens":2,"cache_read_input_tokens":3}}}"#,
            #"{"timestamp":"2026-06-29T10:00:00Z","message":{"usage":{"input_tokens":100,"output_tokens":100}}}"#,  // yesterday, ignored
            "garbage line",
        ]
        // since = 2026-06-30T00:00:00Z
        let since = ISO8601DateFormatter().date(from: "2026-06-30T00:00:00Z")!.timeIntervalSince1970
        XCTAssertEqual(ProjectUsageProbe.sumTokens(jsonlLines: lines, sinceEpoch: since), 20)
    }
}
