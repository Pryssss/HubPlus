import XCTest
@testable import HubPlus

/// Verifies the HUBPLUS_DEMO fixtures stay coherent: the demo sessions exercise every
/// status the UI renders, and the numbers agree with each other (project shares sum to
/// the last daily bar, the seeded history ends where the usage snapshot says we are),
/// so a demo screenshot can never show self-contradicting data.
final class DemoModeTests: XCTestCase {
    func testSessionsCoverStatusesAndHaveFixtures() {
        let provider = DemoAgentProvider()
        let sessions = provider.liveSessions()
        XCTAssertGreaterThanOrEqual(sessions.count, 3)

        let kinds = Set(sessions.map(\.statusKind))
        XCTAssertTrue(kinds.isSuperset(of: [.waiting, .busy, .idle]))

        for s in sessions {
            let t = provider.transcriptSnapshot(cwd: s.cwd, sessionId: s.sessionId)
            XCTAssertNotNil(t, "\(s.cwd) has no transcript fixture")
            XCTAssertNotNil(t?.lastText)
            XCTAssertNotNil(t?.model)
            XCTAssertNotNil(DemoData.git(cwd: s.cwd), "\(s.cwd) has no git fixture")
            XCTAssertNotNil(s.statusUpdatedAt, "\(s.cwd) needs a status age for the capsule")
        }
    }

    func testStatsAreInternallyConsistent() {
        let stats = DemoData.stats(now: Date())
        XCTAssertEqual(stats.daily.count, 7)
        XCTAssertFalse(stats.partial)

        let today = stats.daily.last?.tokens.real ?? 0
        let projectSum = stats.projects.compactMap { $0.tokens?.real }.reduce(0, +)
        XCTAssertEqual(projectSum, today, "per-project shares must sum to today's bar")

        // Days are consecutive and end today.
        let cal = Calendar.current
        XCTAssertEqual(stats.daily.last.map { cal.startOfDay(for: $0.date) },
                       cal.startOfDay(for: Date()))
    }

    func testSeededHistoryEndsAtSnapshotUtilization() throws {
        let history = DemoData.seededHistory(now: Date())
        let five = history.fiveSeries()
        let seven = history.sevenSeries()
        XCTAssertGreaterThan(five.count, 100)

        // Spans ~48h, time-ordered.
        let span = (five.last?.t ?? 0) - (five.first?.t ?? 0)
        XCTAssertGreaterThan(span, 40 * 3600)
        XCTAssertTrue(zip(five, five.dropFirst()).allSatisfy { $0.t <= $1.t })

        // The sparkline endpoint must agree with the usage bars.
        let snapshot = DemoData.usageSnapshot(now: Date())
        XCTAssertEqual(five.last?.util ?? -1, snapshot.fiveHour?.utilization ?? -2, accuracy: 3)
        XCTAssertEqual(seven.last?.util ?? -1, snapshot.sevenDay?.utilization ?? -2, accuracy: 3)

        // Utilizations stay in range.
        XCTAssertTrue(five.allSatisfy { $0.util >= 0 && $0.util <= 100 })
        XCTAssertTrue(seven.allSatisfy { $0.util >= 0 && $0.util <= 100 })
    }
}
