# Stats Tab Redesign & Agents Screen Upgrades — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the broken stats-cache-driven Stats tab with transcript-derived 7-day token analytics (real vs cache split), redesign the Stats layout, and surface urgency/duration/git-divergence on the Agents tab.

**Architecture:** Extend `ProjectUsageProbe`'s resumable bounded scan to bucket tokens per local day over a 7-day window and split real (input+output) from cache tokens; one scan feeds the daily chart, the per-project list, and the header counter. `StatsCache` (stale + wrong-shaped source) is deleted. UI: new `StatsView` layout (summary chips → limits sparklines → daily bars → project share rows), upgraded `Sparkline`, and Agents-tab sort/duration/divergence.

**Tech Stack:** Swift 5 / SwiftUI, macOS 14+, XCTest, xcodegen-generated Xcode project.

**Spec:** `docs/superpowers/specs/2026-07-02-stats-agents-redesign-design.md`

## Global Constraints

- Repo: `/Users/markiyanprysiazhniuk/projects/HubPlus`, branch `feat/stats-agents-redesign` (already checked out).
- After ADDING or DELETING any file, run `xcodegen generate` (at `/opt/homebrew/bin/xcodegen`) before building — the project is generated from `project.yml` (sources are folder-based, but regeneration keeps the .xcodeproj honest, and CI does the same).
- Test command (same as CI): `xcodebuild -project HubPlus.xcodeproj -scheme HubPlus -destination 'platform=macOS' test`. To run one class: append `-only-testing:HubPlusTests/<ClassName>`.
- All token numbers rendered in the UI go through `TokenFormat.compact` (Task 1). Primary numbers = **real** input+output tokens; cache only in `.help` tooltips.
- Commit after every task, conventional-commit style (`feat:`, `fix:`, `test:`, `refactor:`), each ending with the `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>` trailer.
- Fixed panel content width is 536 pt (560 − 2×12 padding); no view may hard-code widths that overflow it.

---

### Task 1: `TokenFormat.compact`

**Files:**
- Create: `HubPlus/Support/TokenFormat.swift`
- Test: `HubPlusTests/TokenFormatTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `enum TokenFormat { static func compact(_ n: Int) -> String }` — used by Tasks 5 and 6.

- [ ] **Step 1: Write the failing test**

Create `HubPlusTests/TokenFormatTests.swift`:

```swift
import XCTest
@testable import HubPlus

final class TokenFormatTests: XCTestCase {
    func testVerbatimBelowOneThousand() {
        XCTAssertEqual(TokenFormat.compact(0), "0")
        XCTAssertEqual(TokenFormat.compact(999), "999")
    }

    func testThousandsGetOneDecimalOnlyBelowTenK() {
        XCTAssertEqual(TokenFormat.compact(1_000), "1k")       // ".0" is trimmed
        XCTAssertEqual(TokenFormat.compact(9_400), "9.4k")
        XCTAssertEqual(TokenFormat.compact(9_960), "10k")      // rounds past 9.95 → integer form
        XCTAssertEqual(TokenFormat.compact(604_000), "604k")
    }

    func testRoundingPromotesToTheNextUnit() {
        // 999_950 / 1e3 = 999.95 → would print "1000k"; must promote to "1M".
        XCTAssertEqual(TokenFormat.compact(999_950), "1M")
    }

    func testMillionsAndBillions() {
        XCTAssertEqual(TokenFormat.compact(1_230_000), "1.2M")
        XCTAssertEqual(TokenFormat.compact(604_137_000), "604M")
        XCTAssertEqual(TokenFormat.compact(1_200_000_000), "1.2B")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/markiyanprysiazhniuk/projects/HubPlus && xcodebuild -project HubPlus.xcodeproj -scheme HubPlus -destination 'platform=macOS' test -only-testing:HubPlusTests/TokenFormatTests`
Expected: BUILD FAILURE — `cannot find 'TokenFormat' in scope`. (New test file may also require `xcodegen generate` first; run it before the build.)

- [ ] **Step 3: Write minimal implementation**

Create `HubPlus/Support/TokenFormat.swift`:

```swift
import Foundation

/// Compact human token counts: "512", "9.4k", "604k", "1.2M", "604M", "1.2B".
/// One decimal below 10× of each unit, integers above; rounding that would
/// print "1000k" promotes to the next unit instead.
enum TokenFormat {
    static func compact(_ n: Int) -> String {
        let v = Double(max(n, 0))
        if v < 999.5 { return "\(max(n, 0))" }
        for (unit, divisor) in [("k", 1e3), ("M", 1e6), ("B", 1e9)] {
            let scaled = v / divisor
            if scaled < 9.95 { return trimmed(scaled, unit) }
            if scaled < 999.5 { return "\(Int(scaled.rounded()))\(unit)" }
        }
        return "\(Int((v / 1e9).rounded()))B"
    }

    /// "9.4k", but "9k" rather than "9.0k".
    private static func trimmed(_ value: Double, _ unit: String) -> String {
        let s = String(format: "%.1f", value)
        return (s.hasSuffix(".0") ? String(s.dropLast(2)) : s) + unit
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodegen generate && xcodebuild -project HubPlus.xcodeproj -scheme HubPlus -destination 'platform=macOS' test -only-testing:HubPlusTests/TokenFormatTests`
Expected: `Test Suite 'TokenFormatTests' passed`.

- [ ] **Step 5: Commit**

```bash
git add HubPlus/Support/TokenFormat.swift HubPlusTests/TokenFormatTests.swift HubPlus.xcodeproj
git commit -m "feat(stats): add TokenFormat.compact for human-readable token counts"
```

---

### Task 2: `DurationFormat.compactSince`

**Files:**
- Create: `HubPlus/Support/DurationFormat.swift`
- Test: `HubPlusTests/DurationFormatTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `enum DurationFormat { static func compactSince(_ msEpoch: Double?, now: Date = Date()) -> String? }` — used by Task 6's status capsule ("BUSY · 12m").

- [ ] **Step 1: Write the failing test**

Create `HubPlusTests/DurationFormatTests.swift`:

```swift
import XCTest
@testable import HubPlus

final class DurationFormatTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func ms(secondsAgo: Double) -> Double { (1_000_000 - secondsAgo) * 1000 }

    func testNilInputAndUnderAMinuteAreHidden() {
        XCTAssertNil(DurationFormat.compactSince(nil, now: now))
        XCTAssertNil(DurationFormat.compactSince(ms(secondsAgo: 59), now: now))
    }

    func testMinutesHoursDays() {
        XCTAssertEqual(DurationFormat.compactSince(ms(secondsAgo: 60), now: now), "1m")
        XCTAssertEqual(DurationFormat.compactSince(ms(secondsAgo: 12 * 60), now: now), "12m")
        XCTAssertEqual(DurationFormat.compactSince(ms(secondsAgo: 3 * 3600 + 40), now: now), "3h")
        XCTAssertEqual(DurationFormat.compactSince(ms(secondsAgo: 2 * 86400 + 100), now: now), "2d")
    }

    func testFutureTimestampIsHidden() {
        XCTAssertNil(DurationFormat.compactSince(ms(secondsAgo: -30), now: now))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodegen generate && xcodebuild -project HubPlus.xcodeproj -scheme HubPlus -destination 'platform=macOS' test -only-testing:HubPlusTests/DurationFormatTests`
Expected: BUILD FAILURE — `cannot find 'DurationFormat' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `HubPlus/Support/DurationFormat.swift`:

```swift
import Foundation

/// Compact "how long has it been" labels for status capsules: "12m", "3h", "2d".
/// Under a minute (or missing/future input) → nil, so fresh statuses stay clean.
enum DurationFormat {
    static func compactSince(_ msEpoch: Double?, now: Date = Date()) -> String? {
        guard let ms = msEpoch else { return nil }
        let secs = now.timeIntervalSince(Date(timeIntervalSince1970: ms / 1000.0))
        guard secs >= 60 else { return nil }
        if secs < 3600 { return "\(Int(secs / 60))m" }
        if secs < 86400 { return "\(Int(secs / 3600))h" }
        return "\(Int(secs / 86400))d"
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -project HubPlus.xcodeproj -scheme HubPlus -destination 'platform=macOS' test -only-testing:HubPlusTests/DurationFormatTests`
Expected: `Test Suite 'DurationFormatTests' passed`.

- [ ] **Step 5: Commit**

```bash
git add HubPlus/Support/DurationFormat.swift HubPlusTests/DurationFormatTests.swift HubPlus.xcodeproj
git commit -m "feat(agents): add DurationFormat.compactSince for status-age labels"
```

---

### Task 3: Urgency sort for session rows

**Files:**
- Modify: `HubPlus/Models/SessionRow.swift` (append extensions at end of file)
- Test: `HubPlusTests/SessionRowSortTests.swift`

**Interfaces:**
- Consumes: existing `SessionRow`, `SessionInfo`, `SessionStatusKind` (in `HubPlus/Models/SessionRow.swift` and `HubPlus/Models/SessionInfo.swift`).
- Produces: `SessionStatusKind.urgencyRank: Int` and `static SessionRow.urgencySorted(_ rows: [SessionRow]) -> [SessionRow]` — used by Task 6's `NotchRootView`.

- [ ] **Step 1: Write the failing test**

Create `HubPlusTests/SessionRowSortTests.swift`:

```swift
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodegen generate && xcodebuild -project HubPlus.xcodeproj -scheme HubPlus -destination 'platform=macOS' test -only-testing:HubPlusTests/SessionRowSortTests`
Expected: BUILD FAILURE — `value of type 'SessionStatusKind' has no member 'urgencyRank'`.

- [ ] **Step 3: Write minimal implementation**

Append to `HubPlus/Models/SessionRow.swift` (after the `ModelCatalog` enum):

```swift
extension SessionStatusKind {
    /// Lower = needs the user sooner. Drives the Agents tab ordering.
    var urgencyRank: Int {
        switch self {
        case .waiting: return 0
        case .error:   return 1
        case .busy:    return 2
        case .idle:    return 3
        case .unknown: return 4
        }
    }
}

extension SessionRow {
    /// Waiting first, then error/busy/idle/unknown; alphabetical by title
    /// within a rank so the order is deterministic across refreshes.
    static func urgencySorted(_ rows: [SessionRow]) -> [SessionRow] {
        rows.sorted { a, b in
            let ra = a.info.statusKind.urgencyRank
            let rb = b.info.statusKind.urgencyRank
            if ra != rb { return ra < rb }
            return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -project HubPlus.xcodeproj -scheme HubPlus -destination 'platform=macOS' test -only-testing:HubPlusTests/SessionRowSortTests`
Expected: `Test Suite 'SessionRowSortTests' passed`.

- [ ] **Step 5: Commit**

```bash
git add HubPlus/Models/SessionRow.swift HubPlusTests/SessionRowSortTests.swift HubPlus.xcodeproj
git commit -m "feat(agents): urgency rank + deterministic session sort helper"
```

---

### Task 4: 7-day bucketed probe, real/cache split, StatsCache removal

The heart of the change. `ProjectUsageProbe` gains per-day `TokenCount` buckets over a 7-day window; `ProjectUsage.tokensToday: Int?` becomes `tokens: TokenCount?`; `compute` additionally returns `daily`; `AppStore` rewires `tokensToday`/`dailyTokens` to the probe; `StatsCache` and its tests are deleted. `StatsView` gets the *minimal mechanical* compile fix here (visual redesign is Task 5).

**Files:**
- Modify: `HubPlus/Watchers/ProjectUsageProbe.swift` (whole-file rework of the scan/cache/aggregate internals; `sumTokens`/`extractCwd` helpers stay)
- Modify: `HubPlus/Store/AppStore.swift:159-208` (refresh/refreshStats/published shapes)
- Modify: `HubPlus/Views/StatsView.swift:12,15,24,45` (mechanical `.tokens` fixes only)
- Delete: `HubPlus/Store/StatsCache.swift`, `HubPlusTests/StatsCacheTests.swift`
- Modify: `HubPlus/Support/ClaudePaths.swift` (drop now-unused `statsCache` property)
- Test: `HubPlusTests/ProjectUsageProbeTests.swift` (migrate + extend)

**Interfaces:**
- Consumes: existing scan/cache machinery in `ProjectUsageProbe.swift`.
- Produces (relied on by Tasks 5–6):
  - `struct TokenCount: Equatable { var real: Int; var cache: Int; var total: Int { get } }` (in `ProjectUsageProbe.swift`, next to `ProjectUsage`)
  - `struct ProjectUsage: Equatable, Identifiable { let id: String; let name: String; let tokens: TokenCount?; let sessionCount: Int }`
  - `ProjectUsageProbe.compute(now:budget:root:calendar:chunkSize:windowDays:) -> (projects: [ProjectUsage], daily: [(date: Date, tokens: TokenCount)], partial: Bool)` — `daily` always has exactly `windowDays` (default 7) entries, oldest→today, zero-filled.
  - `AppStore.dailyTokens: [(date: Date, tokens: TokenCount)]`, `AppStore.projectUsage: [ProjectUsage]`, `AppStore.tokensToday: Int?` (today's **real** tokens, set only from a **complete** probe pass).

- [ ] **Step 1: Migrate + extend the probe tests (failing first)**

In `HubPlusTests/ProjectUsageProbeTests.swift`:

1. Mechanical migration — every `result.projects.first?.tokensToday` assertion becomes `result.projects.first?.tokens?.real` (expected values unchanged: all those fixtures are input/output-only). Affects the assertions at current lines 85, 107, 116, 138, 196, 202, 238, 257, 289, 295.
2. **Replace** `testFileWithYesterdayMtimeIsSkippedEvenWithTodayTimestampedLines` (its premise inverts: a yesterday-mtime file is now *inside* the 7-day window and must be scanned) with:

```swift
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
```

3. **Add** the bucketing/splitting/daily tests:

```swift
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
```

- [ ] **Step 2: Run probe tests to verify they fail**

Run: `xcodebuild -project HubPlus.xcodeproj -scheme HubPlus -destination 'platform=macOS' test -only-testing:HubPlusTests/ProjectUsageProbeTests`
Expected: BUILD FAILURE — `has no member 'tokens'`, `cannot find 'TokenCount' in scope`.

- [ ] **Step 3: Rework `ProjectUsageProbe.swift`**

Replace the whole file body as follows, keeping `decodeLine`, `extractCwd`, `sumTokens` (which keeps returning the 4-key **total** Int — its test is unchanged), and the streaming/cache/pruning structure. The diff-shaped description below shows every changed declaration in full; unchanged code (chunk reassembly loop mechanics, directory enumeration skeleton, lock pattern) is kept as-is.

**3a — add `TokenCount`, reshape `ProjectUsage`** (top of file):

```swift
/// Real tokens are what a human means by "tokens" (input + output); cache
/// creation/read tokens inflate raw sums ~500× and are tracked separately.
struct TokenCount: Equatable {
    var real: Int = 0
    var cache: Int = 0
    var total: Int { real + cache }

    static func += (l: inout TokenCount, r: TokenCount) {
        l.real += r.real
        l.cache += r.cache
    }
}

struct ProjectUsage: Equatable, Identifiable {
    let id: String
    let name: String
    /// Today's tokens; nil means "scan yielded nothing usable" → the view
    /// falls back to the session count.
    let tokens: TokenCount?
    let sessionCount: Int
}
```

**3b — split token extraction** (replaces `tokenKeys` + `tokenCount(in:)`):

```swift
    private static let realKeys = ["input_tokens", "output_tokens"]
    private static let cacheKeys = ["cache_creation_input_tokens", "cache_read_input_tokens"]

    private static func tokenCount(in obj: [String: Any]) -> TokenCount {
        let usage = ((obj["message"] as? [String: Any])?["usage"] as? [String: Any])
            ?? (obj["usage"] as? [String: Any])
        guard let u = usage else { return TokenCount() }
        func sum(_ keys: [String]) -> Int { keys.reduce(0) { $0 + ((u[$1] as? NSNumber)?.intValue ?? 0) } }
        return TokenCount(real: sum(realKeys), cache: sum(cacheKeys))
    }
```

`sumTokens(jsonlLines:sinceEpoch:)` keeps its `Int` signature: change its accumulation line to `total += tokenCount(in: obj).total`.

**3c — day-bucketed scan.** `FileScanResult` and `scanFile` change from a single `sinceEpoch` sum to per-day buckets. Signature and bucketing:

```swift
    private struct FileScanResult {
        let boundaryByDay: [Double: TokenCount]  // day-start epoch → tokens, "\n"-terminated lines
        let tailByDay: [Double: TokenCount]      // final unterminated line (scan completed only)
        let bytesConsumed: Int64
        let cwd: String?
        let hitDeadline: Bool
    }

    private static func scanFile(at url: URL, startingAt offset: Int64, windowStart: Double,
                                 calendar: Calendar, deadline: Date, chunkSize: Int) -> FileScanResult? {
```

Inside, `consume` becomes (same decode/cwd logic, new filter + bucket):

```swift
        var boundaryByDay: [Double: TokenCount] = [:]

        func consume(_ lineData: Data) -> (day: Double, tokens: TokenCount)? {
            guard !lineData.isEmpty, let line = String(data: lineData, encoding: .utf8),
                  let obj = decodeLine(line) else { return nil }
            if cwd == nil, let c = obj["cwd"] as? String, !c.isEmpty { cwd = c }
            guard let ts = obj["timestamp"] as? String,
                  let date = iso.date(from: ts) ?? isoPlain.date(from: ts),
                  date.timeIntervalSince1970 >= windowStart else { return nil }
            let day = calendar.startOfDay(for: date).timeIntervalSince1970
            return (day, tokenCount(in: obj))
        }
```

The chunk loop's two accumulation points change accordingly:
- terminated lines: `if let r = consume(...) { boundaryByDay[r.day, default: TokenCount()] += r.tokens }`
- EOF tail: `let tail = consume(carry); return FileScanResult(boundaryByDay: boundaryByDay, tailByDay: tail.map { [$0.day: $0.tokens] } ?? [:], bytesConsumed: bytesConsumed, cwd: cwd, hitDeadline: false)`
- deadline returns: `tailByDay: [:]`, other fields as before.

**3d — cache entry buckets.** Key and entry:

```swift
    private struct FileCacheKey: Hashable { let path: String; let windowStart: Double }
    private struct FileCacheEntry {
        let size: Int64
        let mtime: Double
        let bytesConsumed: Int64
        let boundaryByDay: [Double: TokenCount]  // resume base (line-boundary safe)
        let totalByDay: [Double: TokenCount]     // boundary + unterminated tail (reported value)
        let cwd: String?
        let complete: Bool
    }
```

Add a tiny merge helper next to them (used for base+scan and boundary+tail):

```swift
    private static func merged(_ a: [Double: TokenCount], _ b: [Double: TokenCount]) -> [Double: TokenCount] {
        var out = a
        for (k, v) in b { out[k, default: TokenCount()] += v }
        return out
    }
```

**3e — `compute` rework.** New signature and aggregation (directory skeleton, cache snapshot/merge/prune pattern, deadline checks, open-failure fallback, seenByDir pruning all stay structurally identical — only the summed value type changes from `Int` to `[Double: TokenCount]`):

```swift
    static func compute(now: Date, budget: TimeInterval = 1.5, root: URL = ClaudePaths.projectsDir,
                        calendar: Calendar = .current, chunkSize: Int = 1_048_576, windowDays: Int = 7)
        -> (projects: [ProjectUsage], daily: [(date: Date, tokens: TokenCount)], partial: Bool) {
        let deadline = now.addingTimeInterval(budget)
        let todayStart = calendar.startOfDay(for: now)
        let windowStart = calendar.date(byAdding: .day, value: -(windowDays - 1), to: todayStart)!
            .timeIntervalSince1970
        let todayKey = todayStart.timeIntervalSince1970
```

Per directory: `touchedToday` becomes `touchedInWindow` (`mtime >= windowStart`); the per-file mtime skip likewise `mtimeEpoch >= windowStart`. Per-dir accumulation: `var byDay: [Double: TokenCount] = [:]` — cache hit adds `merged(byDay, e.totalByDay)`; a fresh scan computes `let boundary = merged(baseBoundary, r.boundaryByDay)`, `let total = merged(boundary, r.tailByDay)`, stores them in the entry, adds `total` to `byDay`. The open-failure fallback adds `cached.totalByDay`. Cache key construction: `FileCacheKey(path: f.path, windowStart: windowStart)`; resume base: `baseBoundary = e.boundaryByDay`.

After the per-dir file loop, project row (today-only, zero rows omitted) + a running whole-window accumulator:

```swift
            let today = byDay[todayKey] ?? TokenCount()
            for (day, t) in byDay { allByDay[day, default: TokenCount()] += t }
            if today.total > 0 {
                let name = cwd.map { ($0 as NSString).lastPathComponent }
                    ?? SessionRow.projectName(forEncodedDir: dir.lastPathComponent)
                out.append(ProjectUsage(id: dir.lastPathComponent, name: name,
                                        tokens: today, sessionCount: jsonl.count))
            }
```

(`var allByDay: [Double: TokenCount] = [:]` declared next to `var out`.) Cache pruning filter: `item.key.windowStart == windowStart` replaces the `dayKey == since` condition. Final aggregation + return:

```swift
        let daily: [(date: Date, tokens: TokenCount)] = (0..<windowDays).reversed().map { offset in
            let date = calendar.date(byAdding: .day, value: -offset, to: todayStart)!
            return (date, allByDay[date.timeIntervalSince1970] ?? TokenCount())
        }
        return (out.sorted { ($0.tokens?.real ?? 0) > ($1.tokens?.real ?? 0) }, daily, partial)
```

**3f — test hooks.** `_resetCacheForTesting`, `canonicalForTesting`, `_hasCacheEntryForTesting` unchanged. `_seedIncompleteEntryForTesting` keeps its signature; internally:

```swift
        let dayStart = calendar.startOfDay(for: day)
        let windowStart = calendar.date(byAdding: .day, value: -6, to: dayStart)!.timeIntervalSince1970
        let key = FileCacheKey(path: canonicalForTesting(path), windowStart: windowStart)
        let buckets = [dayStart.timeIntervalSince1970: TokenCount(real: boundaryTokens, cache: 0)]
        let entry = FileCacheEntry(size: size, mtime: mtime, bytesConsumed: bytesConsumed,
                                   boundaryByDay: buckets, totalByDay: buckets,
                                   cwd: nil, complete: false)
```

(The `-6` mirrors `compute`'s default `windowDays: 7`; the hook has no production callers.)

- [ ] **Step 4: Rewire `AppStore.swift`**

- `dailyTokens` published property becomes `[(date: Date, tokens: TokenCount)] = []`.
- In `refresh()` (lines 159–180): delete `let today = StatsCache.tokensToday()` and `self?.tokensToday = today`; update the snapshot comment to drop the StatsCache mention ("GitProbe stays direct (host-machine concern, not per-provider)."). Add `refreshStats()` as the last line of `refresh()` (before the closing brace, on the main actor) — its existing 30 s throttle turns the 3 s tick into a keep-warm trigger.
- `refreshStats(force:)` becomes:

```swift
    func refreshStats(force: Bool = false) {
        if !force, Date().timeIntervalSince(lastStats) < 30 { return }
        lastStats = Date()
        statsQueue.async { [weak self] in
            let result = ProjectUsageProbe.compute(now: Date())
            DispatchQueue.main.async {
                guard let self else { return }
                self.dailyTokens = result.daily
                self.projectUsage = result.projects
                self.partialProjects = result.partial
                // Header counter only from a complete pass: a partial sum undercounts,
                // and flashing a lowball "today" number is worse than keeping the last one.
                if !result.partial { self.tokensToday = result.daily.last?.tokens.real }
            }
        }
    }
```

- [ ] **Step 5: Minimal mechanical `StatsView.swift` fixes (compile only)**

- Line 12: `store.dailyTokens.map { $0.tokens }.max()` → `store.dailyTokens.map { $0.tokens.real }.max()`
- Line 15: `CGFloat(d.tokens)` → `CGFloat(d.tokens.real)`
- Line 24: `p.tokensToday.map(tokenLabel)` → `p.tokens.map { tokenLabel($0.real) }`

- [ ] **Step 6: Delete StatsCache**

```bash
git rm HubPlus/Store/StatsCache.swift HubPlusTests/StatsCacheTests.swift
```

In `HubPlus/Support/ClaudePaths.swift`, delete the now-unused line:
`static var statsCache: URL { home.appendingPathComponent("stats-cache.json") }`

- [ ] **Step 7: Run the full suite**

Run: `xcodegen generate && xcodebuild -project HubPlus.xcodeproj -scheme HubPlus -destination 'platform=macOS' test`
Expected: all suites pass, including the migrated `ProjectUsageProbeTests` (13 tests: 9 migrated, 1 replaced, 3 new) and no `StatsCacheTests`.

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "feat(stats): transcript-derived 7-day daily tokens with real/cache split

ProjectUsageProbe now buckets per local day over a 7-day window and splits
input+output from cache tokens; one scan feeds the daily chart, project list,
and header counter. StatsCache is removed: its file is stale on real machines
and its dailyModelTokens parse (dict) no longer matches what Claude Code
writes (array), so both of its consumers read zeros forever."
```

---

### Task 5: Stats tab visual redesign + Sparkline upgrades

**Files:**
- Modify: `HubPlus/Views/Sparkline.swift` (add `fill` / `showGuide` / `endDot` options)
- Modify: `HubPlus/Views/StatsView.swift` (full rewrite)

**Interfaces:**
- Consumes: `TokenFormat.compact` (Task 1); `AppStore.dailyTokens/projectUsage/partialProjects/usage/fiveSeries()/sevenSeries()` (Task 4 shapes); `UsageWindow.utilization`; `TokenCount`.
- Produces: no new API — pure view change. `Sparkline` stays source-compatible (new params default to old behavior).

- [ ] **Step 1: Upgrade `Sparkline.swift`**

Replace the file with:

```swift
import SwiftUI

struct Sparkline: View {
    let values: [Double]            // raw values on a fixed 0...domainMax scale
    var color: Color = .green
    var domainMax: Double = 100     // utilization is a percent, so steady low ≠ "maxed"
    var fill: Bool = false          // soft gradient under the line
    var showGuide: Bool = false     // dotted guide at the domain top (= the limit)
    var endDot: Bool = false        // marks the most-recent sample
    private let lineWidth: CGFloat = 1.5

    var body: some View {
        GeometryReader { geo in
            let pts = points(in: geo.size)
            ZStack {
                if showGuide {
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: lineWidth / 2))
                        p.addLine(to: CGPoint(x: geo.size.width, y: lineWidth / 2))
                    }
                    .stroke(Color.white.opacity(0.12), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                }
                if fill, pts.count >= 2, let first = pts.first, let last = pts.last {
                    Path { p in
                        p.move(to: CGPoint(x: first.x, y: geo.size.height))
                        pts.forEach { p.addLine(to: $0) }
                        p.addLine(to: CGPoint(x: last.x, y: geo.size.height))
                        p.closeSubpath()
                    }
                    .fill(LinearGradient(colors: [color.opacity(0.22), color.opacity(0.02)],
                                         startPoint: .top, endPoint: .bottom))
                }
                Path { p in
                    for (i, pt) in pts.enumerated() {
                        i == 0 ? p.move(to: pt) : p.addLine(to: pt)
                    }
                }
                .stroke(color, lineWidth: lineWidth)
                if endDot, let last = pts.last {
                    Circle().fill(color)
                        .frame(width: 5, height: 5)
                        .position(last)
                }
            }
        }
    }

    private func points(in size: CGSize) -> [CGPoint] {
        let pts = downsample(values, to: 80)
        let maxV = max(domainMax, 0.0001)
        let inset = lineWidth / 2                       // keep a flat line off the edges
        let h = max(size.height - lineWidth, 0.0001)
        return pts.enumerated().map { i, v in
            let x = pts.count <= 1 ? size.width / 2 : size.width * CGFloat(i) / CGFloat(pts.count - 1)
            let clamped = min(max(v, 0), maxV)
            return CGPoint(x: x, y: inset + h * (1 - CGFloat(clamped / maxV)))
        }
    }

    private func downsample(_ v: [Double], to n: Int) -> [Double] {
        guard v.count > n else { return v }
        let strideLen = Double(v.count) / Double(n)
        return (0..<n).map { v[min(v.count - 1, Int(Double($0) * strideLen))] }
    }
}
```

- [ ] **Step 2: Rewrite `StatsView.swift`**

Replace the file with:

```swift
import SwiftUI

/// Consumption-first stats: summary chips, 48h limit history, a 7-day token
/// trend, and today's per-project breakdown. Primary numbers everywhere are
/// real input+output tokens; cache totals (which inflate raw sums ~500×) live
/// in tooltips so they stay inspectable without drowning the signal.
struct StatsView: View {
    @ObservedObject var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            summaryChips
            sectionCaption("LIMITS · 48H")
            limitRow("5h", series: store.fiveSeries().map { $0.util },
                     window: store.usage?.fiveHour, color: .green)
            limitRow("7d", series: store.sevenSeries().map { $0.util },
                     window: store.usage?.sevenDay, color: .blue)
            Divider().opacity(0.2)
            sectionCaption("TOKENS · 7 DAYS")
            dailyChart
            Divider().opacity(0.2)
            sectionCaption("BY PROJECT · TODAY")
            projectRows
        }
        .padding(.vertical, 6)
    }

    // MARK: Summary

    private var todayTokens: TokenCount { store.dailyTokens.last?.tokens ?? TokenCount() }
    private var weekReal: Int { store.dailyTokens.reduce(0) { $0 + $1.tokens.real } }

    private var summaryChips: some View {
        HStack(spacing: 8) {
            chip("TODAY", TokenFormat.compact(todayTokens.real))
                .help("in/out \(TokenFormat.compact(todayTokens.real)) · cache \(TokenFormat.compact(todayTokens.cache))")
            chip("7 DAYS", TokenFormat.compact(weekReal))
            chip("TOP PROJECT", store.projectUsage.first?.name ?? "—")
        }
    }

    private func chip(_ caption: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(caption).font(.system(size: 9, weight: .medium)).kerning(0.5)
                .foregroundColor(.secondary.opacity(0.8))
            Text(value).font(.system(size: 15, weight: .semibold))
                .foregroundColor(.white).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.05)))
    }

    // MARK: Limits

    private func limitRow(_ label: String, series: [Double], window: UsageWindow?, color: Color) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 11)).foregroundColor(.secondary)
                .frame(width: 18, alignment: .leading)
            if series.count < 2 {
                Text("collecting…").font(.system(size: 10))
                    .foregroundColor(.secondary.opacity(0.6))
                    .frame(maxWidth: .infinity, minHeight: 26, alignment: .leading)
            } else {
                Sparkline(values: series, color: color, fill: true, showGuide: true, endDot: true)
                    .frame(maxWidth: .infinity)
                    .frame(height: 26)
            }
            Text(window.map { "\(Int($0.utilization.rounded()))% used" } ?? "—")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(usedColor(window?.utilization))
                .frame(width: 62, alignment: .trailing)
        }
    }

    private func usedColor(_ utilization: Double?) -> Color {
        guard let u = utilization else { return .secondary }
        if u >= 90 { return .red }
        if u >= 70 { return .yellow }
        return .secondary
    }

    // MARK: Daily tokens

    private var dailyChart: some View {
        let days = store.dailyTokens
        let maxReal = max(days.map { $0.tokens.real }.max() ?? 0, 1)
        return HStack(alignment: .bottom, spacing: 6) {
            ForEach(Array(days.enumerated()), id: \.offset) { i, day in
                let isToday = i == days.count - 1
                VStack(spacing: 3) {
                    Text(day.tokens.real > 0 ? TokenFormat.compact(day.tokens.real) : " ")
                        .font(.system(size: 8)).foregroundColor(.secondary)
                        .lineLimit(1).minimumScaleFactor(0.8)
                    if day.tokens.real > 0 {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.orange.opacity(isToday ? 1.0 : 0.55))
                            .frame(height: max(3, 44 * CGFloat(day.tokens.real) / CGFloat(maxReal)))
                    } else {
                        Rectangle().fill(Color.white.opacity(0.15)).frame(height: 1)
                    }
                    Text(weekday(day.date))
                        .font(.system(size: 9, weight: isToday ? .semibold : .regular))
                        .foregroundColor(isToday ? .white : .secondary)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 72, alignment: .bottom)
    }

    private func weekday(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "today" }
        let f = DateFormatter()
        f.dateFormat = "EEE"
        return f.string(from: date)
    }

    // MARK: Projects

    @ViewBuilder private var projectRows: some View {
        let listed = Array(store.projectUsage.prefix(6))
        if listed.isEmpty {
            Text(store.partialProjects ? "scanning transcripts…" : "no activity today yet")
                .font(.system(size: 10)).foregroundColor(.secondary.opacity(0.7))
        } else {
            let maxReal = max(listed.compactMap { $0.tokens?.real }.max() ?? 0, 1)
            VStack(alignment: .leading, spacing: 7) {
                ForEach(listed, id: \.id) { project in
                    projectRow(project, maxReal: maxReal)
                }
                if store.projectUsage.count > listed.count {
                    Text("+\(store.projectUsage.count - listed.count) more")
                        .font(.system(size: 9)).foregroundColor(.secondary.opacity(0.7))
                }
                if store.partialProjects {
                    Text("partial — scanning…")
                        .font(.system(size: 9)).foregroundColor(.secondary.opacity(0.7))
                }
            }
        }
    }

    private func projectRow(_ project: ProjectUsage, maxReal: Int) -> some View {
        HStack(spacing: 8) {
            Text(project.name).font(.system(size: 11)).foregroundColor(.white)
                .lineLimit(1)
                .frame(width: 130, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.07))
                    if let real = project.tokens?.real {
                        Capsule().fill(Color.orange.opacity(0.85))
                            .frame(width: max(3, geo.size.width * CGFloat(real) / CGFloat(maxReal)))
                    }
                }
            }
            .frame(height: 3)
            HStack(spacing: 4) {
                if let tokens = project.tokens {
                    Text(TokenFormat.compact(tokens.real))
                        .font(.system(size: 11)).foregroundColor(.white)
                    Text("· \(project.sessionCount) sess")
                        .font(.system(size: 10)).foregroundColor(.secondary)
                } else {
                    Text("\(project.sessionCount) sess")
                        .font(.system(size: 11)).foregroundColor(.secondary)
                }
            }
            .frame(width: 110, alignment: .trailing)
        }
        .help(helpText(project))
    }

    private func helpText(_ project: ProjectUsage) -> String {
        guard let tokens = project.tokens else { return "\(project.sessionCount) sessions" }
        return "in/out \(TokenFormat.compact(tokens.real)) · cache \(TokenFormat.compact(tokens.cache)) · \(project.sessionCount) sessions"
    }

    // MARK: Shared

    private func sectionCaption(_ title: String) -> some View {
        Text(title).font(.system(size: 9, weight: .medium)).kerning(0.6)
            .foregroundColor(.secondary.opacity(0.8))
    }
}
```

(Note the old `sparkRow`/`tokenLabel` helpers and the `store.burn5h`/`burn7d` reads disappear — burn projections already render in the header rows; repeating them here was noise.)

- [ ] **Step 3: Build + full test run**

Run: `xcodebuild -project HubPlus.xcodeproj -scheme HubPlus -destination 'platform=macOS' test`
Expected: BUILD SUCCEEDED, all tests pass (no view had tests; this catches compile/regression only).

- [ ] **Step 4: Commit**

```bash
git add HubPlus/Views/Sparkline.swift HubPlus/Views/StatsView.swift
git commit -m "feat(stats): redesign Stats tab — summary chips, labeled limit history, 7-day bars, project share rows"
```

---

### Task 6: Agents tab — urgency sort, status duration, git divergence, header/empty-state polish

**Files:**
- Modify: `HubPlus/Views/NotchRootView.swift` (sorted rows, empty state, header formatter)
- Modify: `HubPlus/Views/SessionCardView.swift` (status duration, ahead/behind)

**Interfaces:**
- Consumes: `SessionRow.urgencySorted` (Task 3), `DurationFormat.compactSince` (Task 2), `TokenFormat.compact` (Task 1), `GitInfo.ahead/behind` (existing, currently unrendered).
- Produces: no new API.

- [ ] **Step 1: `NotchRootView.swift` changes**

Replace `agentsContent` with:

```swift
    @ViewBuilder private var agentsContent: some View {
        if store.rows.isEmpty {
            VStack(spacing: 3) {
                Text("No live Claude Code sessions")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                Text("Sessions appear when `claude` runs in a terminal")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary.opacity(0.6))
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 16)
        } else {
            let rows = SessionRow.urgencySorted(store.rows)
            VStack(spacing: 0) {
                ForEach(rows) { row in
                    SessionCardView(row: row, onJump: onJump)
                    if row.id != rows.last?.id {
                        Divider().overlay(Color.white.opacity(0.06))
                    }
                }
            }
            .animation(.default, value: rows.map(\.id))
        }
    }
```

In `header`, replace `Label("\(formatK(today)) today", systemImage: "bolt.fill")` with `Label("\(TokenFormat.compact(today)) today", systemImage: "bolt.fill")`, and delete the now-unused `private func formatK(_ n: Int) -> String { … }` at the bottom of the file.

- [ ] **Step 2: `SessionCardView.swift` changes**

In `statusCapsule`, add the duration after the label text (inside the existing `HStack(spacing: 4)`):

```swift
    private var statusCapsule: some View {
        HStack(spacing: 4) {
            Circle().fill(statusColor).frame(width: 5, height: 5)
            Text(statusLabel).font(.system(size: 9, weight: .semibold))
            if let duration = DurationFormat.compactSince(row.info.statusUpdatedAt) {
                Text("· \(duration)").font(.system(size: 9, weight: .medium)).opacity(0.85)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(Capsule().fill(statusColor.opacity(0.16)))
        .overlay(Capsule().stroke(statusColor.opacity(0.30), lineWidth: 0.5))
        .foregroundColor(statusColor)
    }
```

In `metaLine`'s branch block, add divergence right after the dirty-dot `if` (inside the same `HStack(spacing: 2)`):

```swift
                    if row.git?.isDirty == true {
                        Circle().fill(Color.yellow).frame(width: 4, height: 4)
                    }
                    if let git = row.git, git.ahead > 0 || git.behind > 0 {
                        Text(divergenceLabel(git))
                            .font(.system(size: 9))
                    }
```

And add the helper next to `ageString`:

```swift
    private func divergenceLabel(_ git: GitInfo) -> String {
        [git.ahead > 0 ? "↑\(git.ahead)" : nil, git.behind > 0 ? "↓\(git.behind)" : nil]
            .compactMap { $0 }
            .joined(separator: " ")
    }
```

- [ ] **Step 3: Build + full test run**

Run: `xcodebuild -project HubPlus.xcodeproj -scheme HubPlus -destination 'platform=macOS' test`
Expected: BUILD SUCCEEDED, all tests pass (sort/duration logic was unit-tested in Tasks 2–3; this wires it into views).

- [ ] **Step 4: Commit**

```bash
git add HubPlus/Views/NotchRootView.swift HubPlus/Views/SessionCardView.swift
git commit -m "feat(agents): urgency-sorted rows, status duration, git ahead/behind, richer empty state"
```

---

### Task 7: Full verification, visual check, changelog

**Files:**
- Modify: `CHANGELOG.md` (`[Unreleased]` section)

**Interfaces:** none — verification and docs.

- [ ] **Step 1: Full suite from clean generation**

Run: `xcodegen generate && xcodebuild -project HubPlus.xcodeproj -scheme HubPlus -destination 'platform=macOS' test`
Expected: BUILD SUCCEEDED, every suite green.

- [ ] **Step 2: Run the real app and visually verify (superpowers:verification-before-completion + verify skill)**

Build and launch the actual app, open the panel, switch to Stats:

```bash
xcodebuild -project HubPlus.xcodeproj -scheme HubPlus -configuration Debug build
# find the built .app under DerivedData and `open` it
```

Verify against the spec, on the real machine's data:
- Stats: chips show plausible "TODAY"/"7 DAYS" real-token numbers (this machine burned ~hundreds of M raw / ~single-digit M real recently); daily bars are non-flat with weekday labels and value labels; project rows show readable numbers (`1.2M`, not `604137k`) with share bars; limits sparklines span the panel width with "% used" chips.
- Agents: waiting sessions sort above busy/idle; capsule shows "BUSY · 12m"-style duration after a minute; a repo with unpushed commits shows `↑N`.
- Header: "⚡ N today" appears after the first complete scan (may take a few 30 s ticks while converging on 316 MB of transcripts — "partial — scanning…" shows meanwhile).
- Screenshot the expanded panel for the user.

- [ ] **Step 3: Changelog entry**

Under `## [Unreleased]` in `CHANGELOG.md`, add (create the subsection headers if absent, keeping Keep-a-Changelog order Added/Changed/Fixed):

```markdown
### Added
- Stats tab: summary chips (today / 7 days / top project), per-day token bars for the
  last 7 days, and proportional per-project share bars — all derived from local
  transcripts with real (input+output) vs cache token split; cache totals in tooltips.
- Agents tab: sessions sort by urgency (waiting → error → busy → idle), status
  capsules show how long the state has lasted ("BUSY · 12m"), and branches show
  git ahead/behind (↑2 ↓1).

### Changed
- Token numbers are now humanized everywhere ("1.2M", not "604137k") and mean real
  input+output tokens rather than cache-inflated totals.
- Limit sparklines fill the panel width with a dotted 100% guide, gradient fill, and
  a current "% used" readout.

### Fixed
- "Tokens / day" was permanently flat: it read `~/.claude/stats-cache.json`, which is
  both stale (months old on real machines) and shaped differently than the parser
  expected (`dailyModelTokens` is now an array). Daily tokens now come from the same
  bounded transcript scan as the per-project stats, so the chart reflects reality.
- The header "⚡ today" counter never appeared (same broken source); it now shows real
  tokens from the transcript scan once a complete pass finishes.
```

- [ ] **Step 4: Commit**

```bash
git add CHANGELOG.md
git commit -m "docs: changelog for Stats redesign + Agents upgrades"
```

- [ ] **Step 5: Finish the branch**

Invoke superpowers:finishing-a-development-branch — present merge/PR options for `feat/stats-agents-redesign` (7 commits: spec, 5 feature commits, changelog).

---

## Plan self-review notes

- **Spec coverage:** §4.1→T4-3a, §4.2→T4-3c/3d/3e, §4.3→T4-6, §4.4→T4-4, §5 TokenFormat→T1, §5.1.1 chips→T5, §5.1.2 limits→T5 (Sparkline+limitRow), §5.1.3 daily bars→T5, §5.1.4 projects→T5, §5.2 sort→T3+T6, duration→T2+T6, divergence→T6, empty state→T6, §5.3 header→T6, §6 tests→T1/T2/T3/T4 steps, verification→T7. The spec's "AppStoreProviderTests: header tokensToday derives from probe" is intentionally NOT a test task: the derivation is one guarded assignment inside `refreshStats`, and testing it would require making the static probe injectable — deferred as YAGNI; covered by T7's visual verification instead.
- **Type consistency:** `TokenCount(real:cache:)`, `ProjectUsage.tokens`, `compute(...) -> (projects:daily:partial:)`, `urgencySorted`, `compactSince`, `TokenFormat.compact` used identically across tasks.
- **Known behavior changes called out:** yesterday-mtime files are now scanned (window widened) — old test replaced, not deleted silently; header updates at 30 s stats cadence instead of 3 s (source was broken anyway); Stats tab no longer repeats burn labels (header owns them).
