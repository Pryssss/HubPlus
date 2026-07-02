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

    /// A file not written today cannot contain lines timestamped today in any way
    /// that matters — skip it by mtime before ever opening it. Uses a *second*,
    /// freshly-touched file in the same project dir so the pre-existing directory-level
    /// "touchedToday" filter still lets the project through; the point is the per-file
    /// mtime check, not the directory one.
    func testFileWithYesterdayMtimeIsSkippedEvenWithTodayTimestampedLines() throws {
        let tmpRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("probe-\(UUID().uuidString)", isDirectory: true)
        let projectDir = tmpRoot.appendingPathComponent("proj1", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpRoot) }

        let now = Date()
        let ts = ISO8601DateFormatter().string(from: now)
        let todayLine = #"{"timestamp":"\#(ts)","message":{"usage":{"input_tokens":10,"output_tokens":5}}}"#

        // Fresh file: mtime is "just now" (write time), keeps the directory-level filter true.
        let freshFile = projectDir.appendingPathComponent("fresh.jsonl")
        try todayLine.write(to: freshFile, atomically: true, encoding: .utf8)

        // Stale file: identical today-timestamped content, but mtime forced to yesterday.
        let staleFile = projectDir.appendingPathComponent("stale.jsonl")
        try todayLine.write(to: staleFile, atomically: true, encoding: .utf8)
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now)!
        try FileManager.default.setAttributes([.modificationDate: yesterday], ofItemAtPath: staleFile.path)

        let result = ProjectUsageProbe.compute(now: now, root: tmpRoot)
        XCTAssertEqual(result.projects.first?.tokensToday, 15,
                        "stale.jsonl's today-timestamped line must not be counted because its mtime is yesterday")
    }

    /// Black-box characterization of the incremental/caching behavior: an unchanged
    /// file must not lose data, and an appended line must be reflected on the next
    /// compute() — whether or not that second file is a cache hit is an implementation
    /// detail, but the observable total must be exactly right either way.
    func testIncrementalAppendIncreasesTotalByExactlyTheAppendedAmount() throws {
        let tmpRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("probe-\(UUID().uuidString)", isDirectory: true)
        let projectDir = tmpRoot.appendingPathComponent("proj1", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpRoot) }

        let now = Date()
        let ts = ISO8601DateFormatter().string(from: now)
        let file = projectDir.appendingPathComponent("session.jsonl")
        let line1 = #"{"timestamp":"\#(ts)","message":{"usage":{"input_tokens":10,"output_tokens":5}}}"#
        try (line1 + "\n").write(to: file, atomically: true, encoding: .utf8)

        let first = ProjectUsageProbe.compute(now: now, root: tmpRoot)
        XCTAssertEqual(first.projects.first?.tokensToday, 15)

        let line2 = #"{"timestamp":"\#(ts)","message":{"usage":{"input_tokens":7,"output_tokens":3}}}"#
        let handle = try FileHandle(forWritingTo: file)
        handle.seekToEndOfFile()
        handle.write((line2 + "\n").data(using: .utf8)!)
        try handle.close()

        let second = ProjectUsageProbe.compute(now: now, root: tmpRoot)
        XCTAssertEqual(second.projects.first?.tokensToday, 25,
                        "appending a 7+3=10 token line should raise the total from 15 to 25")
    }

    /// The streaming reader must reassemble a single JSONL line even when it straddles
    /// a chunk boundary. `chunkSize: 64` against a ~550-byte line forces at least one
    /// split mid-line, well inside the payload rather than conveniently at its edges.
    func testLineSplitAcrossChunkBoundaryIsParsedCorrectly() throws {
        let tmpRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("probe-\(UUID().uuidString)", isDirectory: true)
        let projectDir = tmpRoot.appendingPathComponent("proj1", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpRoot) }

        let now = Date()
        let ts = ISO8601DateFormatter().string(from: now)
        let padding = String(repeating: "x", count: 500)
        let line = #"{"timestamp":"\#(ts)","pad":"\#(padding)","message":{"usage":{"input_tokens":42,"output_tokens":8}}}"#
        let file = projectDir.appendingPathComponent("session.jsonl")
        try (line + "\n").write(to: file, atomically: true, encoding: .utf8)

        let result = ProjectUsageProbe.compute(now: now, root: tmpRoot, chunkSize: 64)
        XCTAssertEqual(result.projects.first?.tokensToday, 50,
                        "a line split across chunk boundaries must still be reassembled and parsed correctly")
    }
}
