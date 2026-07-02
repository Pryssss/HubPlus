import XCTest
@testable import HubPlus

final class UsageClientParseTests: XCTestCase {
    private func data(_ json: String) -> Data { json.data(using: .utf8)! }

    // MARK: - utilization as Int and as Double; both windows present -> .ok

    func testBothWindowsPresentWithIntAndDoubleUtilizationReturnsOkWithCorrectPercents() {
        let json = """
        {
          "five_hour": {"utilization": 42, "resets_at": "2026-07-02T10:00:00Z"},
          "seven_day": {"utilization": 17.5, "resets_at": "2026-07-05T00:00:00Z"}
        }
        """
        let result = UsageClient.parse(statusCode: 200, data: data(json))
        guard case .ok(let snap) = result else { return XCTFail("expected .ok, got \(result)") }

        XCTAssertEqual(snap.fiveHour?.utilization, 42, "Int utilization must be read")
        XCTAssertEqual(snap.fiveHour?.percentLeft, 58)
        XCTAssertEqual(snap.sevenDay?.utilization, 17.5, "Double utilization must be read")
        XCTAssertEqual(snap.sevenDay?.percentLeft, 83, "100 - 17.5 rounds to 83")
        XCTAssertEqual(snap.state, .ok)
    }

    // MARK: - missing both windows -> .transient

    func testMissingBothWindowsReturnsTransient() {
        let result = UsageClient.parse(statusCode: 200, data: data("{}"))
        guard case .transient = result else { return XCTFail("expected .transient, got \(result)") }
    }

    func testWindowMissingUtilizationFieldIsTreatedAsAbsent() {
        // A window object with no usable "utilization" key must not count as present.
        let json = #"{"five_hour": {"resets_at": "2026-07-02T10:00:00Z"}}"#
        let result = UsageClient.parse(statusCode: 200, data: data(json))
        guard case .transient = result else { return XCTFail("expected .transient, got \(result)") }
    }

    // MARK: - HTTP status codes

    func test401And403ReturnAuthError() {
        for code in [401, 403] {
            let result = UsageClient.parse(statusCode: code, data: Data())
            guard case .authError = result else {
                XCTFail("status \(code) expected .authError, got \(result)")
                continue
            }
        }
    }

    func test429And500ReturnTransient() {
        for code in [429, 500] {
            let result = UsageClient.parse(statusCode: code, data: Data())
            guard case .transient = result else {
                XCTFail("status \(code) expected .transient, got \(result)")
                continue
            }
        }
    }

    func testUnparseableBodyOn200ReturnsTransient() {
        let result = UsageClient.parse(statusCode: 200, data: data("not json"))
        guard case .transient = result else { return XCTFail("expected .transient, got \(result)") }
    }

    // MARK: - resets_at in each supported format

    func testResetsAtISOWithFractionalSecondsParses() {
        let ts = "2026-07-02T10:00:00.500Z"
        let json = #"{"five_hour": {"utilization": 10, "resets_at": "\#(ts)"}}"#
        let result = UsageClient.parse(statusCode: 200, data: data(json))
        guard case .ok(let snap) = result else { return XCTFail("expected .ok, got \(result)") }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let expected = iso.date(from: ts)!
        XCTAssertEqual(snap.fiveHour?.resetsAt?.timeIntervalSince1970 ?? -1, expected.timeIntervalSince1970, accuracy: 0.001)
    }

    func testResetsAtPlainISOParses() {
        let ts = "2026-07-02T10:00:00Z"
        let json = #"{"five_hour": {"utilization": 10, "resets_at": "\#(ts)"}}"#
        let result = UsageClient.parse(statusCode: 200, data: data(json))
        guard case .ok(let snap) = result else { return XCTFail("expected .ok, got \(result)") }

        let expected = ISO8601DateFormatter().date(from: ts)!
        XCTAssertEqual(snap.fiveHour?.resetsAt?.timeIntervalSince1970 ?? -1, expected.timeIntervalSince1970, accuracy: 0.001)
    }

    func testResetsAtEpochSecondsParses() {
        // Below the 1e12 threshold, so used directly as seconds-since-epoch.
        let epochSeconds: Double = 1_793_000_000
        let json = #"{"five_hour": {"utilization": 10, "resets_at": \#(Int(epochSeconds))}}"#
        let result = UsageClient.parse(statusCode: 200, data: data(json))
        guard case .ok(let snap) = result else { return XCTFail("expected .ok, got \(result)") }

        XCTAssertEqual(snap.fiveHour?.resetsAt?.timeIntervalSince1970 ?? -1, epochSeconds, accuracy: 0.001)
    }

    func testResetsAtEpochMillisecondsParses() {
        // Above the 1e12 threshold, so divided by 1000 to get seconds-since-epoch.
        let epochMillis: Double = 1_793_000_000_000
        let json = #"{"five_hour": {"utilization": 10, "resets_at": \#(Int64(epochMillis))}}"#
        let result = UsageClient.parse(statusCode: 200, data: data(json))
        guard case .ok(let snap) = result else { return XCTFail("expected .ok, got \(result)") }

        XCTAssertEqual(snap.fiveHour?.resetsAt?.timeIntervalSince1970 ?? -1, epochMillis / 1000, accuracy: 0.001)
    }

    // Note: the code comment on parseDate's regex-strip branch calls out ".877499" as an
    // example of sub-second precision "the formatters reject". On this toolchain/SDK,
    // ISO8601DateFormatter(.withFractionalSeconds) is lenient enough to parse 6+ fractional
    // digits directly (verified empirically), so that fallback branch is not reachable via
    // any malformed-fraction string tried here — it appears to be defensive code for an
    // older Foundation behavior. Not tested separately since there's no way to force it on
    // this runtime without asserting on private formatter internals.
}
