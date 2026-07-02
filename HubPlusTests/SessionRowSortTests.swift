import XCTest
@testable import HubPlus

final class SessionRowSortTests: XCTestCase {
    private func row(_ id: String, status: String?, cwd: String) -> SessionRow {
        SessionRow(info: SessionInfo(
            pid: 1, sessionId: id, cwd: cwd, name: nil, status: status,
            kind: nil, entrypoint: nil, version: nil, peerProtocol: nil,
            startedAt: nil, updatedAt: nil, statusUpdatedAt: nil))
    }

    func testUrgencyRankOrdering() {
        XCTAssertLessThan(SessionStatusKind.waiting.urgencyRank, SessionStatusKind.error.urgencyRank)
        XCTAssertLessThan(SessionStatusKind.error.urgencyRank, SessionStatusKind.busy.urgencyRank)
        XCTAssertLessThan(SessionStatusKind.busy.urgencyRank, SessionStatusKind.idle.urgencyRank)
        XCTAssertLessThan(SessionStatusKind.idle.urgencyRank, SessionStatusKind.unknown.urgencyRank)
    }

    func testWaitingBubblesAboveBusyAndIdle() {
        let rows = [
            row("a", status: "idle", cwd: "/tmp/alpha"),
            row("b", status: "busy", cwd: "/tmp/bravo"),
            row("c", status: "waiting", cwd: "/tmp/charlie"),
        ]
        XCTAssertEqual(SessionRow.urgencySorted(rows).map(\.id), ["c", "b", "a"])
    }

    func testSameRankOrdersByTitle() {
        let rows = [
            row("z", status: "idle", cwd: "/tmp/zulu"),
            row("a", status: "idle", cwd: "/tmp/alpha"),
        ]
        XCTAssertEqual(SessionRow.urgencySorted(rows).map(\.id), ["a", "z"])
    }
}
