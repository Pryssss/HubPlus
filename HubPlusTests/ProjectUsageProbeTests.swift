import XCTest
@testable import HubPlus

final class ProjectUsageProbeTests: XCTestCase {
    override func setUp() {
        super.setUp()
        // The probe's cache is process-global and merge-forward (entries survive runs
        // that never revisit their directory), so every test must start cold to stay
        // order-independent.
        ProjectUsageProbe._resetCacheForTesting()
    }

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

    /// A file whose mtime predates the 7-day window cannot contain in-window
    /// lines that matter — it must be skipped before ever being opened.
    /// (A second fresh file keeps the directory-level filter true; the point
    /// is the per-file mtime check.)
    func testFileOlderThanWindowIsSkippedByMtime() throws {
        let tmpRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("probe-\(UUID().uuidString)", isDirectory: true)
        let projectDir = tmpRoot.appendingPathComponent("proj1", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpRoot) }

        let now = Date()
        let ts = ISO8601DateFormatter().string(from: now)
        let todayLine = #"{"timestamp":"\#(ts)","message":{"usage":{"input_tokens":10,"output_tokens":5}}}"#

        let freshFile = projectDir.appendingPathComponent("fresh.jsonl")
        try todayLine.write(to: freshFile, atomically: true, encoding: .utf8)

        // Ancient file: today-timestamped content, but mtime 8 days back — outside the window.
        let ancientFile = projectDir.appendingPathComponent("ancient.jsonl")
        try todayLine.write(to: ancientFile, atomically: true, encoding: .utf8)
        let eightDaysAgo = Calendar.current.date(byAdding: .day, value: -8, to: now)!
        try FileManager.default.setAttributes([.modificationDate: eightDaysAgo], ofItemAtPath: ancientFile.path)

        let result = ProjectUsageProbe.compute(now: now, root: tmpRoot)
        XCTAssertEqual(result.projects.first?.tokens?.real, 15,
                        "ancient.jsonl must be skipped by mtime; only fresh.jsonl counts")
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
        XCTAssertEqual(first.projects.first?.tokens?.real, 15)

        let line2 = #"{"timestamp":"\#(ts)","message":{"usage":{"input_tokens":7,"output_tokens":3}}}"#
        let handle = try FileHandle(forWritingTo: file)
        handle.seekToEndOfFile()
        handle.write((line2 + "\n").data(using: .utf8)!)
        try handle.close()

        let second = ProjectUsageProbe.compute(now: now, root: tmpRoot)
        XCTAssertEqual(second.projects.first?.tokens?.real, 25,
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
        XCTAssertEqual(result.projects.first?.tokens?.real, 50,
                        "a line split across chunk boundaries must still be reassembled and parsed correctly")
    }

    /// Merge-forward retention: entries for directories a run never reaches must stay
    /// warm. Scanning an unrelated root must not wipe the cache built for another root —
    /// a wholesale cache replacement would fail this (the old entry vanishes because its
    /// directory wasn't "seen" by the second run).
    func testCacheRetainsEntriesForDirectoriesNotSeenThisRun() throws {
        let now = Date()
        let ts = ISO8601DateFormatter().string(from: now)
        let line = #"{"timestamp":"\#(ts)","message":{"usage":{"input_tokens":10,"output_tokens":5}}}"#

        func makeRoot() throws -> (root: URL, file: URL) {
            let root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("probe-\(UUID().uuidString)", isDirectory: true)
            let dir = root.appendingPathComponent("proj1", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent("session.jsonl")
            try (line + "\n").write(to: file, atomically: true, encoding: .utf8)
            return (root, file)
        }

        let a = try makeRoot()
        let b = try makeRoot()
        defer {
            try? FileManager.default.removeItem(at: a.root)
            try? FileManager.default.removeItem(at: b.root)
        }

        _ = ProjectUsageProbe.compute(now: now, root: a.root)
        XCTAssertTrue(ProjectUsageProbe._hasCacheEntryForTesting(path: a.file.path))

        _ = ProjectUsageProbe.compute(now: now, root: b.root)
        XCTAssertTrue(ProjectUsageProbe._hasCacheEntryForTesting(path: a.file.path),
                       "entries for directories not reached this run must be kept warm, not wiped")
    }

    /// Pruning: once a directory *was* enumerated and a cached file no longer exists in
    /// it, the entry (and its tokens) must be dropped rather than lingering forever.
    func testCacheEntryPrunedWhenFileDeletedFromScannedDirectory() throws {
        let tmpRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("probe-\(UUID().uuidString)", isDirectory: true)
        let projectDir = tmpRoot.appendingPathComponent("proj1", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpRoot) }

        let now = Date()
        let ts = ISO8601DateFormatter().string(from: now)
        // Two files so the directory stays "touched today" after one is deleted.
        let fileA = projectDir.appendingPathComponent("a.jsonl")
        try (#"{"timestamp":"\#(ts)","message":{"usage":{"input_tokens":10,"output_tokens":5}}}"# + "\n")
            .write(to: fileA, atomically: true, encoding: .utf8)
        let fileB = projectDir.appendingPathComponent("b.jsonl")
        try (#"{"timestamp":"\#(ts)","message":{"usage":{"input_tokens":7,"output_tokens":3}}}"# + "\n")
            .write(to: fileB, atomically: true, encoding: .utf8)

        let first = ProjectUsageProbe.compute(now: now, root: tmpRoot)
        XCTAssertEqual(first.projects.first?.tokens?.real, 25)
        XCTAssertTrue(ProjectUsageProbe._hasCacheEntryForTesting(path: fileA.path))

        try FileManager.default.removeItem(at: fileA)

        let second = ProjectUsageProbe.compute(now: now, root: tmpRoot)
        XCTAssertEqual(second.projects.first?.tokens?.real, 10,
                        "a deleted file's tokens must be gone from the total")
        XCTAssertFalse(ProjectUsageProbe._hasCacheEntryForTesting(path: fileA.path),
                        "the deleted file's cache entry must be pruned once its directory was scanned")
        XCTAssertTrue(ProjectUsageProbe._hasCacheEntryForTesting(path: fileB.path),
                       "the surviving file's entry must be retained")
    }

    /// When a file that appeared in the directory listing can no longer be opened by the
    /// time the scan reaches it (deleted or made unreadable between listing and open),
    /// the tick must fall back to the last cached total for that file instead of
    /// contributing 0 and dipping the displayed sum. Simulated deterministically via
    /// chmod 000 (no sleeps, no real dead mount): after priming the cache with a normal
    /// compute(), the file is appended to (so its size/mtime no longer match the cache,
    /// forcing a rescan attempt) and then made unreadable, so scanFile's open fails and
    /// the fallback path is exercised. This is a different case from
    /// testCacheEntryPrunedWhenFileDeletedFromScannedDirectory: there the file is *gone*
    /// at enumeration time (correctly drops to 0 via pruning); here it's still listed but
    /// fails to open (must NOT drop to 0).
    func testUnreadableFileFallsBackToCachedTotalInsteadOfZero() throws {
        let tmpRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("probe-\(UUID().uuidString)", isDirectory: true)
        let projectDir = tmpRoot.appendingPathComponent("proj1", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let file = projectDir.appendingPathComponent("session.jsonl")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
            try? FileManager.default.removeItem(at: tmpRoot)
        }

        let now = Date()
        let ts = ISO8601DateFormatter().string(from: now)
        let line1 = #"{"timestamp":"\#(ts)","message":{"usage":{"input_tokens":10,"output_tokens":5}}}"#
        try (line1 + "\n").write(to: file, atomically: true, encoding: .utf8)

        let first = ProjectUsageProbe.compute(now: now, root: tmpRoot)
        XCTAssertEqual(first.projects.first?.tokens?.real, 15)

        // Append (changes size/mtime, so the cache can no longer take the "unchanged
        // file, no read at all" fast path) then revoke read permission so the resulting
        // rescan attempt's open fails.
        let line2 = #"{"timestamp":"\#(ts)","message":{"usage":{"input_tokens":7,"output_tokens":3}}}"#
        let handle = try FileHandle(forWritingTo: file)
        handle.seekToEndOfFile()
        handle.write((line2 + "\n").data(using: .utf8)!)
        try handle.close()
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)

        // Some environments (e.g. a container running tests as root) ignore chmod 000;
        // skip rather than assert a false failure if this machine can't simulate it.
        guard (try? FileHandle(forReadingFrom: file)) == nil else {
            throw XCTSkip("this environment can still read a chmod 000 file; cannot simulate deterministically")
        }

        let second = ProjectUsageProbe.compute(now: now, root: tmpRoot)
        XCTAssertEqual(second.projects.first?.tokens?.real, 15,
                        "an unreadable file must fall back to its last cached total (15), not drop to 0")
    }

    /// Convergence: a scan interrupted by the deadline must resume from its stored byte
    /// offset on the next compute(), not restart from byte 0. The incomplete entry is
    /// seeded directly (a real mid-scan deadline expiry depends on wall-clock timing) with
    /// a sentinel boundaryTokens of 999 and bytesConsumed pointing just past line 1: if
    /// compute() resumes, the total is 999 (base) + 10 (line 2) = 1009; if it wrongly
    /// restarts from zero, it would report 15 + 10 = 25.
    func testInterruptedScanResumesFromStoredProgress() throws {
        let tmpRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("probe-\(UUID().uuidString)", isDirectory: true)
        let projectDir = tmpRoot.appendingPathComponent("proj1", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpRoot) }

        let now = Date()
        let ts = ISO8601DateFormatter().string(from: now)
        let line1 = #"{"timestamp":"\#(ts)","message":{"usage":{"input_tokens":10,"output_tokens":5}}}"#
        let line2 = #"{"timestamp":"\#(ts)","message":{"usage":{"input_tokens":7,"output_tokens":3}}}"#
        let file = projectDir.appendingPathComponent("session.jsonl")
        try (line1 + "\n" + line2 + "\n").write(to: file, atomically: true, encoding: .utf8)

        let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
        let size = (attrs[.size] as! NSNumber).int64Value
        let mtime = (attrs[.modificationDate] as! Date).timeIntervalSince1970
        ProjectUsageProbe._seedIncompleteEntryForTesting(
            path: file.path, day: now, size: size, mtime: mtime,
            bytesConsumed: Int64((line1 + "\n").utf8.count), boundaryTokens: 999)

        let result = ProjectUsageProbe.compute(now: now, root: tmpRoot)
        XCTAssertEqual(result.projects.first?.tokens?.real, 1009,
                        "an interrupted scan must resume from bytesConsumed with the stored base, not restart at 0")
        XCTAssertFalse(result.partial, "the resumed scan completed within budget, so the tick is not partial")

        // The entry is now complete: a further compute() must reuse it verbatim.
        let again = ProjectUsageProbe.compute(now: now, root: tmpRoot)
        XCTAssertEqual(again.projects.first?.tokens?.real, 1009)
    }

    /// One file holding lines from three different days: today, two days ago, and
    /// eight days ago. The daily series must bucket the first two by local day,
    /// split real vs cache, zero-fill the rest, and drop the out-of-window line.
    func testDailyBucketsSplitRealAndCacheAcrossDays() throws {
        let tmpRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("probe-\(UUID().uuidString)", isDirectory: true)
        let projectDir = tmpRoot.appendingPathComponent("proj1", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpRoot) }

        let now = Date()
        let cal = Calendar.current
        let iso = ISO8601DateFormatter()
        let tToday = iso.string(from: now)
        let tTwoDays = iso.string(from: cal.date(byAdding: .day, value: -2, to: now)!)
        let tEightDays = iso.string(from: cal.date(byAdding: .day, value: -8, to: now)!)
        let lines = [
            #"{"timestamp":"\#(tToday)","message":{"usage":{"input_tokens":10,"output_tokens":5,"cache_creation_input_tokens":100,"cache_read_input_tokens":200}}}"#,
            #"{"timestamp":"\#(tTwoDays)","message":{"usage":{"input_tokens":7,"output_tokens":3}}}"#,
            #"{"timestamp":"\#(tEightDays)","message":{"usage":{"input_tokens":999,"output_tokens":999}}}"#,
        ].joined(separator: "\n") + "\n"
        try lines.write(to: projectDir.appendingPathComponent("session.jsonl"),
                        atomically: true, encoding: .utf8)

        let result = ProjectUsageProbe.compute(now: now, root: tmpRoot)

        XCTAssertEqual(result.daily.count, 7)
        XCTAssertEqual(result.daily.last?.tokens, TokenCount(real: 15, cache: 300), "today: real 10+5, cache 100+200")
        let dayMinus2 = result.daily[result.daily.count - 3]
        XCTAssertEqual(dayMinus2.tokens, TokenCount(real: 10, cache: 0), "two days ago: real 7+3")
        XCTAssertEqual(result.daily.filter { $0.tokens == TokenCount() }.count, 5, "other five days zero-filled")
        XCTAssertEqual(result.projects.first?.tokens, TokenCount(real: 15, cache: 300),
                        "the project list is today-only")
    }

    /// A project whose only in-window activity is on PAST days feeds the daily
    /// series but must not appear in the today-only project list.
    func testPastOnlyProjectFeedsDailyButIsOmittedFromProjects() throws {
        let tmpRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("probe-\(UUID().uuidString)", isDirectory: true)
        let projectDir = tmpRoot.appendingPathComponent("proj1", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpRoot) }

        let now = Date()
        let tThreeDays = ISO8601DateFormatter().string(from: Calendar.current.date(byAdding: .day, value: -3, to: now)!)
        let line = #"{"timestamp":"\#(tThreeDays)","message":{"usage":{"input_tokens":6,"output_tokens":4}}}"#
        try (line + "\n").write(to: projectDir.appendingPathComponent("session.jsonl"),
                                atomically: true, encoding: .utf8)

        let result = ProjectUsageProbe.compute(now: now, root: tmpRoot)
        XCTAssertTrue(result.projects.isEmpty, "no today-tokens → no project row")
        let dayMinus3 = result.daily[result.daily.count - 4]
        XCTAssertEqual(dayMinus3.tokens, TokenCount(real: 10, cache: 0))
    }
}
