import XCTest
@testable import HubPlus

final class TranscriptReaderTests: XCTestCase {
    private func makeRoot() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("transcript-\(UUID().uuidString)", isDirectory: true)
    }

    /// Mirrors the real layout TranscriptReader reads:
    /// `<root>/<encodedProjectDirName(cwd)>/<sessionId>.jsonl`.
    @discardableResult
    private func writeFixture(root: URL, cwd: String, sessionId: String, content: String) throws -> URL {
        let dir = root.appendingPathComponent(ClaudePaths.encodedProjectDirName(forCwd: cwd), isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("\(sessionId).jsonl")
        try content.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    // MARK: - Last assistant text / model / context tokens

    func testLastAssistantMessageWinsForTextModelAndContextTokens() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cwd = "/Users/me/project-a"
        let lines = [
            // user line: must not affect model/text/tokens, only cwd/timestamp.
            #"{"type":"user","timestamp":"2026-06-30T10:00:00Z","cwd":"\#(cwd)","message":{"content":[{"type":"text","text":"hello"}]}}"#,
            // first assistant reply
            #"{"type":"assistant","timestamp":"2026-06-30T10:00:01Z","message":{"model":"claude-first","usage":{"input_tokens":10,"cache_read_input_tokens":2,"cache_creation_input_tokens":1},"content":[{"type":"text","text":"first reply"}]}}"#,
            // tool line: must not affect model/text/tokens either.
            #"{"type":"tool_result","timestamp":"2026-06-30T10:00:02Z","content":"irrelevant"}"#,
            // second (later) assistant reply: this is the one that must win.
            #"{"type":"assistant","timestamp":"2026-06-30T10:00:03Z","message":{"model":"claude-second","usage":{"input_tokens":100,"cache_read_input_tokens":20,"cache_creation_input_tokens":5},"content":[{"type":"text","text":"second"},{"type":"text","text":"reply"}]}}"#,
        ]
        try writeFixture(root: root, cwd: cwd, sessionId: "sess1", content: lines.joined(separator: "\n"))

        let snap = TranscriptReader.snapshot(cwd: cwd, sessionId: "sess1", root: root)
        XCTAssertEqual(snap?.model, "claude-second", "the latest assistant message's model must win over the earlier one")
        XCTAssertEqual(snap?.lastText, "second reply", "text blocks of the latest assistant message must be joined with a space")
        XCTAssertEqual(snap?.contextTokens, 100 + 20 + 5, "contextTokens must be input + cache_read + cache_creation of the latest assistant message")
    }

    // MARK: - ISO timestamps: fractional and plain

    func testISOTimestampWithFractionalSecondsParses() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cwd = "/Users/me/project-fractional"
        let ts = "2026-06-30T10:00:00.123Z"
        try writeFixture(root: root, cwd: cwd, sessionId: "s1",
                          content: #"{"type":"user","timestamp":"\#(ts)"}"#)

        let snap = TranscriptReader.snapshot(cwd: cwd, sessionId: "s1", root: root)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let expected = iso.date(from: ts)!
        XCTAssertEqual(snap?.lastActivity?.timeIntervalSince1970 ?? -1, expected.timeIntervalSince1970, accuracy: 0.001)
    }

    func testISOTimestampPlainParses() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cwd = "/Users/me/project-plain"
        let ts = "2026-06-30T10:00:05Z"
        try writeFixture(root: root, cwd: cwd, sessionId: "s1",
                          content: #"{"type":"user","timestamp":"\#(ts)"}"#)

        let snap = TranscriptReader.snapshot(cwd: cwd, sessionId: "s1", root: root)
        let expected = ISO8601DateFormatter().date(from: ts)!
        XCTAssertEqual(snap?.lastActivity?.timeIntervalSince1970 ?? -1, expected.timeIntervalSince1970, accuracy: 0.001)
    }

    // MARK: - Latest cwd wins

    func testLatestNonEmptyCwdWins() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cwd = "/Users/me/project-cwd"
        let lines = [
            #"{"type":"user","cwd":"/Users/me/project-cwd/sub1"}"#,
            #"{"type":"user","cwd":"/Users/me/project-cwd/sub2"}"#,
            // Empty cwd LAST: this ordering is what makes the !c.isEmpty guard observable.
            // If that guard regressed, this trailing line would clobber sub2 with "" and the
            // assertion below would fail; an empty line in the middle would be masked by sub2.
            #"{"type":"user","cwd":""}"#,
        ]
        try writeFixture(root: root, cwd: cwd, sessionId: "s1", content: lines.joined(separator: "\n"))

        let snap = TranscriptReader.snapshot(cwd: cwd, sessionId: "s1", root: root)
        XCTAssertEqual(snap?.cwd, "/Users/me/project-cwd/sub2", "the latest non-empty cwd must win; a trailing empty cwd must not clobber it")
    }

    // MARK: - sanitize()

    func testSanitizeStripsControlCharsCapsLengthAndFlattensNewlines() {
        let esc = "\u{1B}" // ANSI escape byte
        let raw = esc + "[31m" + String(repeating: "a", count: 250) + "\n\tend"
        let out = TranscriptReader.sanitize(raw)

        XCTAssertFalse(out.unicodeScalars.contains { $0.value == 0x1B }, "the ESC control byte must be stripped")
        XCTAssertFalse(out.contains("\n"), "newlines must be flattened to spaces")
        XCTAssertFalse(out.contains("\t"), "tabs must be flattened to spaces")
        XCTAssertEqual(out.count, 241, "output must be capped at 240 chars plus a trailing ellipsis")
        XCTAssertTrue(out.hasSuffix("…"), "truncated output must end with an ellipsis")
    }

    func testSanitizeLeavesShortCleanTextUntouched() {
        XCTAssertEqual(TranscriptReader.sanitize("plain short text"), "plain short text")
    }

    // MARK: - Tolerant of a torn (truncated) final line

    func testToleratesATornFinalLineAndKeepsTheLastCompleteLinesData() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cwd = "/Users/me/project-torn"
        let completeLine = #"{"type":"assistant","timestamp":"2026-06-30T10:00:00Z","message":{"model":"claude-good","usage":{"input_tokens":5,"cache_read_input_tokens":0,"cache_creation_input_tokens":0},"content":[{"type":"text","text":"good reply"}]}}"#
        // Simulates a write caught mid-flush: valid JSON prefix, no closing braces, no trailing newline.
        let tornLine = #"{"type":"assistant","timestamp":"2026-06-30T10:00:01Z","message":{"model":"claude-torn","usage":{"input_tok"#
        try writeFixture(root: root, cwd: cwd, sessionId: "s1", content: completeLine + "\n" + tornLine)

        let snap = TranscriptReader.snapshot(cwd: cwd, sessionId: "s1", root: root)
        XCTAssertNotNil(snap, "a torn final line must not crash or nil out the whole snapshot")
        XCTAssertEqual(snap?.model, "claude-good", "the unparseable torn line must be skipped, leaving the last complete line's data")
        XCTAssertEqual(snap?.lastText, "good reply")
    }
}
