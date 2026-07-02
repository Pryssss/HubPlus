import XCTest
@testable import HubPlus

final class SessionInfoTests: XCTestCase {
    private func info(status: String?) -> SessionInfo {
        SessionInfo(pid: 1, sessionId: "s", cwd: "/tmp", status: status)
    }

    func testStatusKindStringTableMapping() {
        XCTAssertEqual(info(status: "idle").statusKind, .idle)
        XCTAssertEqual(info(status: "busy").statusKind, .busy)
        XCTAssertEqual(info(status: "running").statusKind, .busy)
        XCTAssertEqual(info(status: "active").statusKind, .busy)
        XCTAssertEqual(info(status: "waiting").statusKind, .waiting)
        XCTAssertEqual(info(status: "waiting-approval").statusKind, .waiting)
        XCTAssertEqual(info(status: "blocked").statusKind, .waiting)
        XCTAssertEqual(info(status: "needs-input").statusKind, .waiting)
        XCTAssertEqual(info(status: "error").statusKind, .error)
        XCTAssertEqual(info(status: "failed").statusKind, .error)
        XCTAssertEqual(info(status: "some-status-not-in-the-table").statusKind, .unknown)
        XCTAssertEqual(info(status: nil).statusKind, .unknown, "a missing status must map to .unknown, not crash")
    }

    func testStatusKindMatchingIsCaseInsensitive() {
        XCTAssertEqual(info(status: "BUSY").statusKind, .busy)
        XCTAssertEqual(info(status: "Waiting-Approval").statusKind, .waiting)
    }
}
