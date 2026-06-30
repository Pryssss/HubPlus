# Usage Analytics & Jump-to-Window Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an inline burn-rate + a Stats tab (history sparkline, daily tokens, per-project breakdown) + a low-limit alert, and a per-card jump-to-terminal-window action, to the macOS Hub+ app.

**Architecture:** Pure, unit-tested logic structs (`BurnRate`, token summing, tty parsing) sit under thin I/O wrappers (`UsageHistoryStore`, `ProjectUsageProbe`, `WindowJumper`); `AppStore` owns them and publishes `@Published` values the SwiftUI panel renders. New views (`StatsView`, `Sparkline`) and a tab switcher extend the existing notch panel.

**Tech Stack:** Swift 5, SwiftUI + AppKit, XCTest, xcodegen, `Foundation` (JSON, FileManager, Process), `NSAppleScript`.

## Global Constraints

- macOS only; Swift 5 (`SWIFT_VERSION 5.0`), not sandboxed.
- Spec: `docs/superpowers/specs/2026-06-30-usage-analytics-and-jump-to-window-design.md`. Every task's requirements include that spec.
- Constants (no settings UI): usage-history ring **48 h**; burn-rate window **30 min**; low-limit alert **≤ 20 % left**; daily tokens **last 7 days**; per-project scan budget **1.5 s**, throttle **30 s**; "today" = **local midnight**.
- **Prompt-injection (first-class):** never interpolate any transcript/model/cwd/project-name string into AppleScript or a shell. The jump uses only the numeric pid → tty from `ps`.
- Build: `xcodegen generate` then `xcodebuild -project HubPlus.xcodeproj -scheme HubPlus -configuration Debug -derivedDataPath .build CODE_SIGNING_ALLOWED=NO`. Tests: `... -scheme HubPlus test`.
- Commit after every task. Do not push (local only) without explicit OK.
- Token fields summed everywhere = `input_tokens + output_tokens + cache_creation_input_tokens + cache_read_input_tokens`.

---

### Task 0: XCTest target

**Files:**
- Modify: `project.yml` (add `HubPlusTests` target + scheme test action)
- Test: `HubPlusTests/SanityTests.swift` (create)

**Interfaces:**
- Produces: a runnable unit-test bundle with `@testable import HubPlus`; `xcodebuild ... test` green.

- [ ] **Step 1: Add the test target to `project.yml`**

```yaml
  HubPlusTests:
    type: bundle.unit-test
    platform: macOS
    sources: [HubPlusTests]
    dependencies:
      - target: HubPlus
    settings:
      base:
        GENERATE_INFOPLIST_FILE: YES
        SWIFT_VERSION: "5.0"
```
Under the existing `HubPlus` scheme, add:
```yaml
    test:
      targets: [HubPlusTests]
```

- [ ] **Step 2: Write a sanity test**

```swift
import XCTest
@testable import HubPlus

final class SanityTests: XCTestCase {
    func testTrue() { XCTAssertTrue(true) }
}
```

- [ ] **Step 3: Generate + run**

Run: `xcodegen generate && xcodebuild -project HubPlus.xcodeproj -scheme HubPlus -configuration Debug -derivedDataPath .build CODE_SIGNING_ALLOWED=NO test 2>&1 | grep -E "Test Suite.*passed|failed|error:"`
Expected: `SanityTests` passed.

- [ ] **Step 4: Commit**

```bash
git add project.yml HubPlusTests
git commit -m "test: add HubPlusTests XCTest target"
```

---

### Task 1: BurnRate (pure)

**Files:**
- Create: `HubPlus/Usage/BurnRate.swift`
- Test: `HubPlusTests/BurnRateTests.swift`

**Interfaces:**
- Produces:
  - `struct BurnProjection: Equatable { let hoursLeft: Double; let label: String }`
  - `enum BurnRate { static func project(_ samples: [(t: Double, util: Double)], now: Double, window: Double = 1800) -> BurnProjection? }`
  - `samples` are `(t: epoch seconds, util: 0...100)`; returns `nil` when not burning / reset / insufficient data. `label` is `~3h` (≥ 60 min) or `~40m` (< 60 min).

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
@testable import HubPlus

final class BurnRateTests: XCTestCase {
    func testProjectsTimeToLimit() {
        // 10%/hour: util 70 now, 60 thirty min ago -> 20%/h -> (100-70)/20 = 1.5h
        let now = 10_000.0
        let s = [(t: now - 1800, util: 60.0), (t: now, util: 70.0)]
        let p = BurnRate.project(s, now: now)
        XCTAssertNotNil(p)
        XCTAssertEqual(p!.hoursLeft, 1.5, accuracy: 0.05)
        XCTAssertEqual(p!.label, "~1h")
    }
    func testNoProjectionWhenFlat() {
        let now = 10_000.0
        XCTAssertNil(BurnRate.project([(now-1800, 50), (now, 50)], now: now))
    }
    func testNoProjectionOnReset() {
        let now = 10_000.0
        // util dropped (window reset) -> nil
        XCTAssertNil(BurnRate.project([(now-1800, 90), (now, 10)], now: now))
    }
    func testMinutesLabel() {
        let now = 10_000.0
        // 90%/h burn, util 70 -> 0.33h -> ~20m
        let s = [(now-600, 60.0), (now, 70.0)]  // 10% in 10min = 60%/h; (100-70)/60=0.5h -> ~30m
        XCTAssertEqual(BurnRate.project(s, now: now)?.label, "~30m")
    }
    func testInsufficientSamples() {
        XCTAssertNil(BurnRate.project([(10_000, 50)], now: 10_000))
    }
}
```

- [ ] **Step 2: Run to verify fail**

Run: `xcodebuild ... -scheme HubPlus test 2>&1 | grep -E "BurnRateTests|error:"`
Expected: FAIL (BurnRate not defined).

- [ ] **Step 3: Implement**

```swift
import Foundation

struct BurnProjection: Equatable { let hoursLeft: Double; let label: String }

/// Projects time-to-limit from recent usage samples. Pure + unit-tested.
enum BurnRate {
    static func project(_ samples: [(t: Double, util: Double)], now: Double, window: Double = 1800) -> BurnProjection? {
        let win = samples.filter { now - $0.t <= window }.sorted { $0.t < $1.t }
        guard win.count >= 2, let first = win.first, let last = win.last else { return nil }
        if last.util < first.util { return nil }                 // reset guard
        // least-squares slope (util per second), fall back to first/last for <3
        let slopePerSec: Double
        if win.count >= 3 {
            let n = Double(win.count)
            let sx = win.reduce(0) { $0 + $1.t }
            let sy = win.reduce(0) { $0 + $1.util }
            let sxx = win.reduce(0) { $0 + $1.t * $1.t }
            let sxy = win.reduce(0) { $0 + $1.t * $1.util }
            let denom = n * sxx - sx * sx
            guard denom != 0 else { return nil }
            slopePerSec = (n * sxy - sx * sy) / denom
        } else {
            let dt = last.t - first.t
            guard dt > 0 else { return nil }
            slopePerSec = (last.util - first.util) / dt
        }
        let perHour = slopePerSec * 3600
        guard perHour > 0.0001 else { return nil }               // not burning
        let hoursLeft = max(0, (100 - last.util) / perHour)
        return BurnProjection(hoursLeft: hoursLeft, label: label(hoursLeft))
    }

    static func label(_ hours: Double) -> String {
        if hours >= 1 { return "~\(Int(hours.rounded()))h" }
        return "~\(Int((hours * 60).rounded()))m"
    }
}
```

- [ ] **Step 4: Run to verify pass.** Expected: BurnRateTests passed.
- [ ] **Step 5: Commit** `git add HubPlus/Usage/BurnRate.swift HubPlusTests/BurnRateTests.swift && git commit -m "feat: BurnRate time-to-limit projection"`

---

### Task 2: UsageHistoryStore

**Files:**
- Create: `HubPlus/Usage/UsageHistoryStore.swift`
- Test: `HubPlusTests/UsageHistoryStoreTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `struct UsageSample: Codable, Equatable { let t: Double; let five: Double; let seven: Double }`
  - `final class UsageHistoryStore` with:
    - `init(fileURL: URL, ringSeconds: Double = 48*3600, now: () -> Double = { Date().timeIntervalSince1970 })`
    - `private(set) var samples: [UsageSample]` (loaded on init)
    - `func record(five: Double, seven: Double)` — appends `{now, five, seven}`, trims to ring, persists off-main.
    - `func fiveSeries() -> [(t: Double, util: Double)]` and `sevenSeries()`.

- [ ] **Step 1: Write failing tests** (inject a temp file + fake clock)

```swift
import XCTest
@testable import HubPlus

final class UsageHistoryStoreTests: XCTestCase {
    func tmp() -> URL { URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString + ".json") }

    func testRecordAndSeries() {
        var clock = 1000.0
        let s = UsageHistoryStore(fileURL: tmp(), now: { clock })
        s.record(five: 10, seven: 5); clock = 1060
        s.record(five: 12, seven: 6)
        XCTAssertEqual(s.fiveSeries().map { $0.util }, [10, 12])
        XCTAssertEqual(s.sevenSeries().last?.util, 6)
    }

    func testRingTrim() {
        var clock = 0.0
        let s = UsageHistoryStore(fileURL: tmp(), ringSeconds: 100, now: { clock })
        s.record(five: 1, seven: 1)           // t=0
        clock = 250
        s.record(five: 2, seven: 2)           // t=250, drops t=0 (>100s old)
        XCTAssertEqual(s.samples.count, 1)
        XCTAssertEqual(s.samples.first?.five, 2)
    }

    func testPersistAcrossInstances() {
        let url = tmp()
        var clock = 500.0
        let a = UsageHistoryStore(fileURL: url, now: { clock }); a.record(five: 7, seven: 3)
        let b = UsageHistoryStore(fileURL: url, now: { clock })
        XCTAssertEqual(b.samples.first?.five, 7)
    }

    func testCorruptFileStartsEmpty() {
        let url = tmp()
        try? "not json".data(using: .utf8)!.write(to: url)
        let s = UsageHistoryStore(fileURL: url, now: { 0 })
        XCTAssertTrue(s.samples.isEmpty)
    }
}
```

- [ ] **Step 2: Run — verify fail.**

- [ ] **Step 3: Implement**

```swift
import Foundation

struct UsageSample: Codable, Equatable { let t: Double; let five: Double; let seven: Double }

/// Persists usage samples to disk, capped to a time ring. The pure trim logic is
/// exercised by tests via an injected clock + temp file.
final class UsageHistoryStore {
    private(set) var samples: [UsageSample] = []
    private let fileURL: URL
    private let ringSeconds: Double
    private let now: () -> Double
    private let io = DispatchQueue(label: "com.hubplus.usagehistory")

    init(fileURL: URL, ringSeconds: Double = 48 * 3600, now: @escaping () -> Double = { Date().timeIntervalSince1970 }) {
        self.fileURL = fileURL
        self.ringSeconds = ringSeconds
        self.now = now
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([UsageSample].self, from: data) {
            samples = decoded
        }
    }

    func record(five: Double, seven: Double) {
        let t = now()
        samples.append(UsageSample(t: t, five: five, seven: seven))
        let cutoff = t - ringSeconds
        samples.removeAll { $0.t < cutoff }
        let snapshot = samples
        io.async { [fileURL] in
            if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: fileURL) }
        }
    }

    func fiveSeries() -> [(t: Double, util: Double)] { samples.map { ($0.t, $0.five) } }
    func sevenSeries() -> [(t: Double, util: Double)] { samples.map { ($0.t, $0.seven) } }

    /// Default on-disk location.
    static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HubPlus", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("usage-history.json")
    }
}
```

- [ ] **Step 4: Run — verify pass.**
- [ ] **Step 5: Commit** `git commit -m "feat: UsageHistoryStore persisted usage samples"`

---

### Task 3: Wire history + burn-rate into AppStore

**Files:**
- Modify: `HubPlus/Store/AppStore.swift`

**Interfaces:**
- Consumes: `UsageHistoryStore`, `BurnRate`, `UsageSnapshot` (`fiveHour`/`sevenDay` `UsageWindow.utilization`).
- Produces on `AppStore`:
  - `@Published private(set) var burn5h: BurnProjection?`
  - `@Published private(set) var burn7d: BurnProjection?`
  - `let history = UsageHistoryStore(fileURL: UsageHistoryStore.defaultURL())`
  - `func fiveSeries() -> [(t: Double, util: Double)]` / `sevenSeries()` (proxy to history) for StatsView.

- [ ] **Step 1: Add properties + recording** — inside `applyUsage`'s `.ok` case, after `usage = snapshot`:

```swift
if let f = snapshot.fiveHour?.utilization, let s = snapshot.sevenDay?.utilization {
    history.record(five: f, seven: s)
}
recomputeBurn()
```
Add:
```swift
@Published private(set) var burn5h: BurnProjection?
@Published private(set) var burn7d: BurnProjection?
let history = UsageHistoryStore(fileURL: UsageHistoryStore.defaultURL())

private func recomputeBurn() {
    let now = Date().timeIntervalSince1970
    burn5h = BurnRate.project(history.fiveSeries(), now: now)
    burn7d = BurnRate.project(history.sevenSeries(), now: now)
}
func fiveSeries() -> [(t: Double, util: Double)] { history.fiveSeries() }
func sevenSeries() -> [(t: Double, util: Double)] { history.sevenSeries() }
```

- [ ] **Step 2: Build** `xcodebuild ... build` — Expected: BUILD SUCCEEDED.
- [ ] **Step 3: Commit** `git commit -m "feat: AppStore records usage history + burn-rate"`

---

### Task 4: Inline burn-rate in UsageHeaderView

**Files:**
- Modify: `HubPlus/Views/UsageHeaderView.swift`

**Interfaces:**
- Consumes: `burn5h`/`burn7d` projections, passed in as parameters so the view stays stateless.
- Produces: visual `· ~3h left` appended to the matching usage row, colored by urgency.

- [ ] **Step 1: Add a `burn` parameter to `row`** and a struct field. Change `UsageHeaderView` to take `let burn5h: BurnProjection?` and `let burn7d: BurnProjection?`. In `row(label:window:)` add a `burn: BurnProjection?` arg; call sites pass `burn5h` for "5h" and `burn7d` for "7d". After the reset label:

```swift
if let burn {
    Text("· \(burn.label) left")
        .font(.system(size: 11))
        .foregroundColor(burnColor(burn.hoursLeft))
}
```
```swift
private func burnColor(_ h: Double) -> Color { h < 1 ? .red : (h < 3 ? .orange : .secondary) }
```

- [ ] **Step 2: Update the call site** in `NotchRootView` (where `UsageHeaderView(usage:)` is built) to pass `burn5h: store.burn5h, burn7d: store.burn7d`.

- [ ] **Step 3: Build + manual verify** — run the app; with active sessions burning tokens, the 5h row shows `· ~Xh left`. (If no burn yet, nothing shows — correct.)

- [ ] **Step 4: Commit** `git commit -m "feat: inline burn-rate in usage header"`

---

### Task 5: StatsCache daily tokens

**Files:**
- Modify: `HubPlus/Store/StatsCache.swift`
- Test: `HubPlusTests/StatsCacheTests.swift`

**Interfaces:**
- Produces: `static func dailyTokens(days: Int, json: Data, today: Date, calendar: Calendar = .current) -> [(date: Date, tokens: Int)]` (pure, fixture-tested) **and** a convenience `static func dailyTokens(days: Int = 7) -> [(date: Date, tokens: Int)]` reading the real file.
- `dailyModelTokens` shape: `{ "YYYY-MM-DD": { "<model>": Int, ... }, ... }`. Sum models per day; missing day → 0.

- [ ] **Step 1: Write failing test**

```swift
import XCTest
@testable import HubPlus

final class StatsCacheTests: XCTestCase {
    func testDailyTokensSumsModelsAndFillsGaps() {
        let json = #"{"dailyModelTokens":{"2026-06-30":{"opus":100,"sonnet":50},"2026-06-28":{"opus":7}}}"#.data(using: .utf8)!
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!
        let today = c.date(from: DateComponents(year: 2026, month: 6, day: 30))!
        let out = StatsCache.dailyTokens(days: 3, json: json, today: today, calendar: c)
        XCTAssertEqual(out.map { $0.tokens }, [7, 0, 150])   // 28th, 29th, 30th
    }
}
```

- [ ] **Step 2: Run — verify fail.**
- [ ] **Step 3: Implement** (add to `StatsCache`)

```swift
static func dailyTokens(days: Int, json: Data, today: Date, calendar: Calendar = .current) -> [(date: Date, tokens: Int)] {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.calendar = calendar; f.timeZone = calendar.timeZone
    var perDay: [String: Int] = [:]
    if let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
       let daily = root["dailyModelTokens"] as? [String: Any] {
        for (day, models) in daily {
            if let m = models as? [String: Any] {
                perDay[day] = m.values.reduce(0) { $0 + ((($1 as? NSNumber)?.intValue) ?? 0) }
            }
        }
    }
    return (0..<days).reversed().map { offset in
        let date = calendar.date(byAdding: .day, value: -offset, to: today)!
        return (date, perDay[f.string(from: date)] ?? 0)
    }
}

static func dailyTokens(days: Int = 7) -> [(date: Date, tokens: Int)] {
    guard let data = try? Data(contentsOf: ClaudePaths.statsCache) else {
        return (0..<days).reversed().map { (Calendar.current.date(byAdding: .day, value: -$0, to: Date())!, 0) }
    }
    return dailyTokens(days: days, json: data, today: Date())
}
```
(Confirm the existing stats-cache path constant name in `ClaudePaths`/`StatsCache`; reuse it.)

- [ ] **Step 4: Run — verify pass. Step 5: Commit** `git commit -m "feat: StatsCache daily-token history"`

---

### Task 6: ProjectUsageProbe

**Files:**
- Create: `HubPlus/Watchers/ProjectUsageProbe.swift`
- Test: `HubPlusTests/ProjectUsageProbeTests.swift`

**Interfaces:**
- Produces:
  - `struct ProjectUsage: Equatable { let name: String; let tokensToday: Int?; let sessionCount: Int }`
  - Pure: `static func sumTokens(jsonlLines: [String], sinceEpoch: Double) -> Int` — for each line that parses to an object with a `timestamp` (ISO8601) ≥ `sinceEpoch` and a `message.usage` (or top-level `usage`), sum the four token fields.
  - I/O: `static func compute(now: Date, budget: TimeInterval = 1.5) -> (projects: [ProjectUsage], partial: Bool)` — walks `~/.claude/projects/*` dirs whose any `*.jsonl` mtime ≥ local midnight, sums via `sumTokens`, sorts desc, honors the time budget.

- [ ] **Step 1: Write failing test for the pure summer**

```swift
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
}
```

- [ ] **Step 2: Run — verify fail.**
- [ ] **Step 3: Implement**

```swift
import Foundation

struct ProjectUsage: Equatable { let name: String; let tokensToday: Int?; let sessionCount: Int }

enum ProjectUsageProbe {
    static func sumTokens(jsonlLines: [String], sinceEpoch: Double) -> Int {
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()
        var total = 0
        for line in jsonlLines {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let ts = obj["timestamp"] as? String,
                  let date = iso.date(from: ts) ?? isoPlain.date(from: ts),
                  date.timeIntervalSince1970 >= sinceEpoch else { continue }
            let usage = ((obj["message"] as? [String: Any])?["usage"] as? [String: Any])
                ?? (obj["usage"] as? [String: Any])
            guard let u = usage else { continue }
            for k in ["input_tokens", "output_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"] {
                total += (u[k] as? NSNumber)?.intValue ?? 0
            }
        }
        return total
    }

    static func compute(now: Date, budget: TimeInterval = 1.5) -> (projects: [ProjectUsage], partial: Bool) {
        let deadline = Date().addingTimeInterval(budget)
        let since = Calendar.current.startOfDay(for: now).timeIntervalSince1970
        let fm = FileManager.default
        let root = ClaudePaths.projectsDir            // ~/.claude/projects
        guard let dirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return ([], false)
        }
        var out: [ProjectUsage] = []
        var partial = false
        for dir in dirs where (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            if Date() > deadline { partial = true; break }
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            let jsonl = files.filter { $0.pathExtension == "jsonl" }
            let touchedToday = jsonl.contains {
                ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate?.timeIntervalSince1970 ?? 0) >= since
            }
            guard touchedToday else { continue }
            var tokens = 0
            for f in jsonl {
                if Date() > deadline { partial = true; break }
                if let text = try? String(contentsOf: f, encoding: .utf8) {
                    tokens += sumTokens(jsonlLines: text.split(separator: "\n").map(String.init), sinceEpoch: since)
                }
            }
            out.append(ProjectUsage(name: SessionRow.projectName(forEncodedDir: dir.lastPathComponent),
                                    tokensToday: tokens, sessionCount: jsonl.count))
        }
        return (out.sorted { ($0.tokensToday ?? 0) > ($1.tokensToday ?? 0) }, partial)
    }
}
```
(Confirm `ClaudePaths.projectsDir`; if absent, add it. `SessionRow.projectName(forEncodedDir:)` — if a reusable decoder doesn't exist, derive the name from the last path component of the decoded cwd, mirroring `SessionRow.title`; add a small static helper.)

- [ ] **Step 4: Run — verify pass. Step 5: Commit** `git commit -m "feat: ProjectUsageProbe per-project tokens today"`

---

### Task 7: Tab state + switcher

**Files:**
- Modify: `HubPlus/App/NotchController.swift` (the `NotchUIModel` at top)
- Modify: `HubPlus/Views/NotchRootView.swift`

**Interfaces:**
- Produces: `enum NotchTab { case agents, stats }`; `@Published var tab: NotchTab = .agents` on `NotchUIModel`. The expanded panel header renders an `Agents | Stats` `Picker`/segmented control bound to `ui.tab`.

- [ ] **Step 1: Add tab state** to `NotchUIModel`:

```swift
enum NotchTab { case agents, stats }
@Published var tab: NotchTab = .agents
```

- [ ] **Step 2: Add the switcher** in `NotchRootView` (only when expanded), above the content:

```swift
Picker("", selection: $ui.tab) {
    Text("Agents").tag(NotchTab.agents)
    Text("Stats").tag(NotchTab.stats)
}
.pickerStyle(.segmented)
.labelsHidden()
.frame(width: 180)
```
Switch the body on `ui.tab`: `.agents` → existing cards list; `.stats` → `StatsView(store: store)` (added in Task 8 — a stub returning `EmptyView()` is fine for this task's build).

- [ ] **Step 3: Build + manual verify** — toggle shows two segments; Agents shows cards. Step 4: Commit `git commit -m "feat: Agents/Stats tab switcher"`

---

### Task 8: Sparkline + StatsView

**Files:**
- Create: `HubPlus/Views/Sparkline.swift`
- Create: `HubPlus/Views/StatsView.swift`
- Modify: `HubPlus/Store/AppStore.swift` (publish `projectUsage`, `partialProjects`, `dailyTokens`; recompute on demand)
- Modify: `HubPlus/App/NotchController.swift` (trigger probe when `ui.tab == .stats`)

**Interfaces:**
- Consumes: `fiveSeries()/sevenSeries()`, `burn5h/burn7d`, `StatsCache.dailyTokens`, `ProjectUsageProbe`.
- Produces on `AppStore`: `@Published private(set) var projectUsage: [ProjectUsage] = []`, `@Published private(set) var partialProjects = false`, `@Published private(set) var dailyTokens: [(date: Date, tokens: Int)] = []`, and `func refreshStats()` (computes both off-main, throttled ≥ 30 s, publishes on main).

- [ ] **Step 1: AppStore `refreshStats()`**

```swift
@Published private(set) var projectUsage: [ProjectUsage] = []
@Published private(set) var partialProjects = false
@Published private(set) var dailyTokens: [(date: Date, tokens: Int)] = []
private var lastStats = Date.distantPast

func refreshStats(force: Bool = false) {
    if !force, Date().timeIntervalSince(lastStats) < 30 { return }
    lastStats = Date()
    work.async { [weak self] in
        let daily = StatsCache.dailyTokens(days: 7)
        let (projects, partial) = ProjectUsageProbe.compute(now: Date())
        DispatchQueue.main.async {
            self?.dailyTokens = daily
            self?.projectUsage = projects
            self?.partialProjects = partial
        }
    }
}
```

- [ ] **Step 2: Trigger on tab open** — in `NotchController`, observe `ui.tab`; when it becomes `.stats`, call `store.refreshStats(force: true)`. (Use a Combine sink on `ui.$tab` in `init`/`show`.)

- [ ] **Step 3: Sparkline view**

```swift
import SwiftUI

struct Sparkline: View {
    let values: [Double]            // already 0...1 normalized OR raw; see normalize
    var color: Color = .green
    var body: some View {
        GeometryReader { geo in
            let pts = downsample(values, to: 80)
            let maxV = max(pts.max() ?? 1, 0.0001)
            Path { p in
                for (i, v) in pts.enumerated() {
                    let x = pts.count <= 1 ? 0 : geo.size.width * CGFloat(i) / CGFloat(pts.count - 1)
                    let y = geo.size.height * (1 - CGFloat(v / maxV))
                    i == 0 ? p.move(to: CGPoint(x: x, y: y)) : p.addLine(to: CGPoint(x: x, y: y))
                }
            }.stroke(color, lineWidth: 1.5)
        }
    }
    private func downsample(_ v: [Double], to n: Int) -> [Double] {
        guard v.count > n else { return v }
        let stride = Double(v.count) / Double(n)
        return (0..<n).map { v[min(v.count - 1, Int(Double($0) * stride))] }
    }
}
```

- [ ] **Step 4: StatsView**

```swift
import SwiftUI

struct StatsView: View {
    @ObservedObject var store: AppStore
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            sparkRow("5h", store.fiveSeries().map { $0.util }, store.burn5h, .green)
            sparkRow("7d", store.sevenSeries().map { $0.util }, store.burn7d, .blue)
            Divider().opacity(0.2)
            Text("Tokens / day").font(.system(size: 10)).foregroundColor(.secondary)
            HStack(alignment: .bottom, spacing: 3) {
                let maxT = max(store.dailyTokens.map { $0.tokens }.max() ?? 1, 1)
                ForEach(Array(store.dailyTokens.enumerated()), id: \.offset) { _, d in
                    Capsule().fill(Color.orange.opacity(0.8))
                        .frame(width: 10, height: max(2, 34 * CGFloat(d.tokens) / CGFloat(maxT)))
                }
            }.frame(height: 36)
            Divider().opacity(0.2)
            Text("By project today").font(.system(size: 10)).foregroundColor(.secondary)
            ForEach(store.projectUsage.prefix(6), id: \.name) { p in
                HStack {
                    Text(p.name).font(.system(size: 11)).foregroundColor(.white).lineLimit(1)
                    Spacer()
                    Text(p.tokensToday.map(tokenLabel) ?? "\(p.sessionCount) sess")
                        .font(.system(size: 11)).foregroundColor(.secondary)
                }
            }
            if store.partialProjects {
                Text("partial — scanning…").font(.system(size: 9)).foregroundColor(.secondary.opacity(0.7))
            }
        }.padding(.vertical, 6)
    }
    private func sparkRow(_ label: String, _ vals: [Double], _ burn: BurnProjection?, _ c: Color) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 11)).foregroundColor(.secondary).frame(width: 18, alignment: .leading)
            Sparkline(values: vals, color: c).frame(width: 120, height: 24)
            if let burn { Text(burn.label).font(.system(size: 10)).foregroundColor(.secondary) }
        }
    }
    private func tokenLabel(_ n: Int) -> String { n >= 1000 ? "\(n/1000)k" : "\(n)" }
}
```
Replace the Task-7 `StatsView` stub usage with this real view.

- [ ] **Step 5: Build + manual verify** — Stats tab shows two sparklines, daily bars, project list. Step 6: Commit `git commit -m "feat: Stats tab (sparklines, daily tokens, per-project)"`

---

### Task 9: Low-limit threshold alert

**Files:**
- Modify: `HubPlus/Store/AppStore.swift`
- Test: `HubPlusTests/ThresholdAlertTests.swift` (via a small pure helper)

**Interfaces:**
- Produces: pure `static func crossedLow(prev: Int?, now: Int, threshold: Int = 20) -> Bool` (true when `now <= threshold` and `prev` was `nil` or `> threshold`). Used in `notifyUsageTransitions` with a `prevLow: [String: Int]` map to fire one notification per crossing.

- [ ] **Step 1: Failing test**

```swift
import XCTest
@testable import HubPlus

final class ThresholdAlertTests: XCTestCase {
    func testCrossing() {
        XCTAssertTrue(AppStore.crossedLow(prev: 25, now: 18))
        XCTAssertFalse(AppStore.crossedLow(prev: 18, now: 15)) // already low
        XCTAssertFalse(AppStore.crossedLow(prev: 30, now: 22)) // still above
        XCTAssertTrue(AppStore.crossedLow(prev: nil, now: 10))
    }
}
```

- [ ] **Step 2: Run — verify fail.**
- [ ] **Step 3: Implement** the static helper + use it in `check(_:label:)` (add a `prevLow` dict and, when `crossedLow`, `Notifier.notify("Claude \(label) at \(window.percentLeft)% left")`).

```swift
static func crossedLow(prev: Int?, now: Int, threshold: Int = 20) -> Bool {
    now <= threshold && (prev == nil || prev! > threshold)
}
```

- [ ] **Step 4: Run — verify pass. Step 5: Commit** `git commit -m "feat: low-limit (20%) threshold notification"`

---

### Task 10: WindowJumper (pure parts + jump)

**Files:**
- Create: `HubPlus/App/WindowJumper.swift`
- Test: `HubPlusTests/WindowJumperTests.swift`

**Interfaces:**
- Produces:
  - `static func parseTTY(_ psOutput: String) -> String?` — `"ttys003\n"` → `"/dev/ttys003"`; empty/`"??"` → nil.
  - `enum TerminalKind { case terminalApp, iterm, other(String) }`
  - `static func terminalKind(comm: String) -> TerminalKind?` — maps a process `comm` to a kind (Terminal, iTerm2, Ghostty, WezTerm, Alacritty, kitty, Code, Warp, …); nil if unknown.
  - `static func jump(pid: Int32)` — does the ps/parent-walk/AppleScript-or-activate off-main. **Only numeric pid/tty reach osascript.**

- [ ] **Step 1: Failing tests for the pure helpers**

```swift
import XCTest
@testable import HubPlus

final class WindowJumperTests: XCTestCase {
    func testParseTTY() {
        XCTAssertEqual(WindowJumper.parseTTY("ttys003\n"), "/dev/ttys003")
        XCTAssertEqual(WindowJumper.parseTTY("  ttys012 "), "/dev/ttys012")
        XCTAssertNil(WindowJumper.parseTTY("??\n"))
        XCTAssertNil(WindowJumper.parseTTY(""))
    }
    func testTerminalKind() {
        if case .terminalApp? = WindowJumper.terminalKind(comm: "Terminal") {} else { XCTFail() }
        if case .iterm? = WindowJumper.terminalKind(comm: "iTerm2") {} else { XCTFail() }
        XCTAssertNil(WindowJumper.terminalKind(comm: "claude"))
    }
}
```

- [ ] **Step 2: Run — verify fail.**
- [ ] **Step 3: Implement** (pure helpers fully; `jump` using `Process` + `NSAppleScript` + `NSRunningApplication`)

```swift
import AppKit

enum TerminalKind: Equatable { case terminalApp, iterm, other(String) }

enum WindowJumper {
    static func parseTTY(_ psOutput: String) -> String? {
        let t = psOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t != "??", t != "?" else { return nil }
        return t.hasPrefix("/dev/") ? t : "/dev/\(t)"
    }

    static func terminalKind(comm: String) -> TerminalKind? {
        let c = comm.lowercased()
        if c.contains("iterm") { return .iterm }
        if c == "terminal" || c.contains("terminal") { return .terminalApp }
        for t in ["ghostty", "wezterm", "alacritty", "kitty", "electron", "code", "warp"] where c.contains(t) {
            return .other(comm)
        }
        return nil
    }

    /// Off-main. Only numeric pid/tty are passed to AppleScript.
    static func jump(pid: Int32) {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let tty = parseTTY(shell("ps", ["-o", "tty=", "-p", "\(pid)"])) else { return }
            guard let (termPID, kind) = findTerminal(of: pid) else { return }
            switch kind {
            case .terminalApp: runScript(terminalScript(tty: tty))
            case .iterm:       runScript(itermScript(tty: tty))
            case .other:       DispatchQueue.main.async { activate(pid: termPID) }
            }
        }
    }

    // walk parent pids until a known terminal; returns (terminalPID, kind)
    private static func findTerminal(of pid: Int32) -> (Int32, TerminalKind)? {
        var cur = pid
        for _ in 0..<12 {
            let line = shell("ps", ["-o", "ppid=,comm=", "-p", "\(cur)"]).trimmingCharacters(in: .whitespaces)
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2, let ppid = Int32(parts[0]) else { return nil }
            let comm = (parts[1] as NSString).lastPathComponent
            if let kind = terminalKind(comm: comm) { return (cur == pid ? ppid : cur, kind) }
            if ppid <= 1 { return nil }
            cur = ppid
        }
        return nil
    }

    private static func activate(pid: Int32) {
        NSRunningApplication(processIdentifier: pid)?.activate(options: [.activateAllWindows])
    }
    private static func runScript(_ src: String) {
        DispatchQueue.main.async { var err: NSDictionary?; NSAppleScript(source: src)?.executeAndReturnError(&err) }
    }
    private static func terminalScript(tty: String) -> String { """
    tell application "Terminal"
      activate
      repeat with w in windows
        repeat with t in tabs of w
          if tty of t is "\(tty)" then
            set selected of t to true
            set index of w to 1
            return
          end if
        end repeat
      end repeat
    end tell
    """ }
    private static func itermScript(tty: String) -> String { """
    tell application "iTerm2"
      activate
      repeat with w in windows
        repeat with t in tabs of w
          repeat with s in sessions of t
            if tty of s is "\(tty)" then
              select s
              select t
              return
            end if
          end repeat
        end repeat
      end repeat
    end tell
    """ }

    private static func shell(_ cmd: String, _ args: [String]) -> String {
        let p = Process(); p.launchPath = "/bin/ps"; p.arguments = args
        if cmd != "ps" { p.launchPath = "/usr/bin/env"; p.arguments = [cmd] + args }
        let pipe = Pipe(); p.standardOutput = pipe
        try? p.run(); p.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }
}
```
Note: `tty` here is a numeric/device string from `ps` — safe to interpolate. Do **not** pass any other field.

- [ ] **Step 4: Run — verify pass. Step 5: Commit** `git commit -m "feat: WindowJumper tty-match + activate fallback"`

---

### Task 11: Card jump button + Info.plist

**Files:**
- Modify: `HubPlus/Views/SessionCardView.swift`
- Modify: `HubPlus/Views/NotchRootView.swift` / `NotchContainerView.swift` (thread `onJump`)
- Modify: `HubPlus/App/NotchController.swift` (call `WindowJumper.jump(pid:)`)
- Modify: `project.yml` (Info.plist `NSAppleEventsUsageDescription`)

**Interfaces:**
- Consumes: `WindowJumper.jump(pid:)`, `row.info.pid`.
- Produces: a trailing button on each card invoking a closure `onJump: (SessionRow) -> Void`.

- [ ] **Step 1: Add the button** to `SessionCardView` (new `let onJump: (SessionRow) -> Void`), at the trailing edge of the meta line:

```swift
Button { onJump(row) } label: {
    Image(systemName: "arrow.up.forward.app").font(.system(size: 11))
}
.buttonStyle(.plain).foregroundColor(.white.opacity(0.5))
.help("Jump to this agent's terminal window")
```

- [ ] **Step 2: Thread `onJump`** from `NotchRootView` → each `SessionCardView`, and from `NotchController` provide it: `{ row in WindowJumper.jump(pid: row.info.pid) }`.

- [ ] **Step 3: Add the usage string** to `project.yml` target `HubPlus` `info.properties`:

```yaml
        NSAppleEventsUsageDescription: "Hub+ focuses the terminal window of the agent you tap."
```

- [ ] **Step 4: Build + manual verify** — `xcodegen generate` then build; run; tap the button on a card whose agent runs in Terminal.app or iTerm2 → that tab comes to front (first run prompts Automation; click OK). A fallback terminal at least comes forward.

- [ ] **Step 5: Commit** `git commit -m "feat: jump-to-window card action + Automation usage string"`

---

### Task 12: Adversarial review + manual test pass

**Files:** none (review/verification)

- [ ] **Step 1:** Run a Workflow adversarial review over the new Swift files (burn-rate math, ring trim, today-boundary, tty/AppleScript safety, threading, retain cycles, prompt-injection invariant). Apply confirmed fixes (each its own commit).
- [ ] **Step 2:** Manual matrix — restart persistence; burn-rate appears under load; Stats renders (use the demo path); jump on Terminal.app + iTerm2 + one fallback.
- [ ] **Step 3:** Build Release, install to `/Applications`, launch.
