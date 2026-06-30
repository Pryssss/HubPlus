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

    /// Verifies that passing a `now` in the distant past makes the deadline
    /// (now + budget) immediately expired so the budget-exhaustion path sets
    /// partial = true — only possible because deadline is anchored to `now`.
    func testBudgetExhaustionViaTimeInjection() throws {
        // Build a temp projects root with one sub-directory + one .jsonl file
        // so the for-loop has at least one directory to enter and hit the deadline check.
        let tmpRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("probe-\(UUID().uuidString)", isDirectory: true)
        let projectDir = tmpRoot.appendingPathComponent("proj1", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let jsonlFile = projectDir.appendingPathComponent("session.jsonl")
        try Data().write(to: jsonlFile)

        // now = Unix epoch (1970-01-01): deadline = epoch + 1.5 s, long in the past.
        // The real Date() is far ahead of that deadline, so partial must be true.
        let ancientNow = Date(timeIntervalSince1970: 0)
        let result = ProjectUsageProbe.compute(now: ancientNow, budget: 1.5, root: tmpRoot)
        XCTAssertTrue(result.partial, "partial should be true when budget is exhausted via injected now")

        try? FileManager.default.removeItem(at: tmpRoot)
    }

    func testExtractCwdReadsRealPathForCorrectName() {
        // The display name must come from the transcript's real cwd, not the lossy
        // encoded dir name (which collapses "my-cool-app" → "app").
        let lines = [
            "no cwd here",
            #"{"type":"user","cwd":"/Users/me/my-cool-app","timestamp":"2026-06-30T10:00:00Z"}"#,
        ]
        let cwd = ProjectUsageProbe.extractCwd(jsonlLines: lines)
        XCTAssertEqual(cwd, "/Users/me/my-cool-app")
        XCTAssertEqual((cwd! as NSString).lastPathComponent, "my-cool-app")
    }
}
