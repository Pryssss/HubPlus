import XCTest
import Combine
@testable import HubPlus

/// Verifies the provider seam: AppStore can be constructed with fake providers and a
/// temp-file history store (so no test touches real ~/.claude or Application Support),
/// and a single refresh aggregates the fakes' data into `rows`/`usage` exactly as the
/// production path would — proving delegation, transcript merge, and provider stamping.
final class AppStoreProviderTests: XCTestCase {
    private var cancellables: Set<AnyCancellable> = []

    override func tearDown() {
        cancellables.removeAll()
        super.tearDown()
    }

    private func tempHistoryURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hubplus-history-\(UUID().uuidString).json")
    }

    @MainActor
    func testRefreshAggregatesFakeProviderSessionsAndUsage() throws {
        // Fake session, decoded from JSON like the real registry entry. The fake provider
        // returns it directly, bypassing SessionWatcher's file/isAlive filtering — so the
        // pid need not be a real live process.
        let sessionJSON = #"{"pid":424242,"sessionId":"fake-1","cwd":"/tmp/hubplus-fake","status":"busy","updatedAt":1000}"#
        let session = try JSONDecoder().decode(SessionInfo.self, from: Data(sessionJSON.utf8))

        var snap = TranscriptSnapshot()
        snap.lastText = "hello from fake"
        snap.model = "claude-fake"
        snap.contextTokens = 1234
        snap.cwd = "/tmp/hubplus-fake/effective"

        let agent = FakeAgentProvider(id: "fake", sessions: [session], snapshots: ["fake-1": snap])
        let usageSnapshot = UsageSnapshot(fiveHour: UsageWindow(utilization: 42, resetsAt: nil),
                                          sevenDay: UsageWindow(utilization: 10, resetsAt: nil),
                                          state: .ok)
        let usage = FakeUsageProvider(result: .ok(usageSnapshot))

        let historyURL = tempHistoryURL()
        defer { try? FileManager.default.removeItem(at: historyURL) }
        let history = UsageHistoryStore(fileURL: historyURL)

        let store = AppStore(agents: [agent], usage: usage, history: history)

        // Drive one refresh of each channel and wait for both to publish on the main actor.
        let rowsReady = expectation(description: "rows published")
        rowsReady.assertForOverFulfill = false
        store.$rows.dropFirst().sink { rows in if !rows.isEmpty { rowsReady.fulfill() } }
            .store(in: &cancellables)
        let usageReady = expectation(description: "usage published")
        usageReady.assertForOverFulfill = false
        store.$usage.dropFirst().sink { u in if u != nil { usageReady.fulfill() } }
            .store(in: &cancellables)

        store.refresh()
        store.refreshUsage()
        wait(for: [rowsReady, usageReady], timeout: 5)

        // rows reflect the fake's sessions, with the transcript snapshot merged in.
        XCTAssertEqual(store.rows.count, 1)
        let row = try XCTUnwrap(store.rows.first)
        XCTAssertEqual(row.info.sessionId, "fake-1")
        XCTAssertEqual(row.providerID, "fake", "row must be stamped with the producing provider's id")
        XCTAssertEqual(row.transcript?.lastText, "hello from fake",
                       "aggregation must merge the provider's transcript snapshot into the row")
        XCTAssertEqual(row.transcript?.model, "claude-fake")

        // usage reflects the fake provider's result.
        XCTAssertEqual(store.usage, usageSnapshot)

        history.waitForPendingIO()
    }
}

// MARK: - Fakes

// `@unchecked Sendable`: these hold only immutable value-type fixtures. The stored
// model types (SessionInfo/TranscriptSnapshot/UsageResult) are internal to HubPlus so
// their implicit Sendable conformance isn't visible from this test module; the unchecked
// annotation is safe here because nothing is mutated after construction.
private struct FakeAgentProvider: AgentProvider, @unchecked Sendable {
    let id: String
    let sessions: [SessionInfo]
    let snapshots: [String: TranscriptSnapshot]
    func liveSessions() -> [SessionInfo] { sessions }
    func transcriptSnapshot(cwd: String, sessionId: String) -> TranscriptSnapshot? { snapshots[sessionId] }
}

private struct FakeUsageProvider: UsageProvider, @unchecked Sendable {
    let result: UsageResult
    func fetch() async -> UsageResult { result }
}
