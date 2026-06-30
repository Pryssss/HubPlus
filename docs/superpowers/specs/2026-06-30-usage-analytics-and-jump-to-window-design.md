# Hub+ — Usage Analytics & Jump-to-Window (macOS)

- **Date:** 2026-06-30
- **Status:** Approved design, ready for implementation plan
- **Scope:** macOS app only (Windows parity deferred)

## 1. Goals

Two independent features sharing the existing `AppStore` data layer:

- **A — Usage analytics:** an inline burn-rate / time-to-limit next to the usage
  bars, plus a **Stats** tab in the panel showing a usage-history sparkline,
  daily-token trend, and a per-project token breakdown; plus a low-limit
  threshold notification.
- **B — Jump-to-window:** a per-card button that focuses the existing terminal
  tab/window where that Claude Code agent is running.

Non-goals: cost ($) estimation (dropped per YAGNI); Windows port of these
features (deferred); any settings UI (constants for v1).

## 2. Approved decisions

1. **History source:** persist usage samples to a local JSON log (survives
   restart) — not in-memory only.
2. **Per-project tokens:** scan transcripts for real "tokens today" (off-main,
   throttled, time-budgeted) — with a fallback to live-session grouping.
3. **Jump mechanism:** hybrid — precise tty-match via AppleScript for
   Terminal.app / iTerm2, best-effort app activation for other terminals.

## 3. Feature A — Usage analytics

### 3.1 `UsageHistoryStore` (new)

- On every successful usage poll (`AppStore.applyUsage(.ok)`), append a sample
  `{ t: Double (epoch s), five: Double (utilization 0–100), seven: Double }`.
- Persists to `~/Library/Application Support/HubPlus/usage-history.json`.
  Loaded on launch; corrupt/missing file → start empty (non-fatal).
- **Ring cap:** keep at most the last **48 hours** of samples (≈2880 at the 60 s
  cadence). Trimmed on each append. This keeps the file tiny and is enough for a
  recent trend + burn-rate. (Longer-range view comes from daily tokens, §3.3.)
- Writes happen off-main (a serial queue); the in-memory array is the source of
  truth for the UI and is mutated on main.
- Exposes: `samples5h() -> [(t, util)]`, `samples7d()`, used by burn-rate and the
  sparkline.

### 3.2 `BurnRate` (new, pure / unit-tested)

- Input: the samples for one window (5h or 7d) and "now".
- Take samples within the **last 30 minutes**. Require ≥ 2 samples.
- **Reset guard:** if the latest utilization is *lower* than the earliest sample
  in the window, a limit reset occurred → return `nil` (no projection).
- Compute slope by least-squares over the 30-min window (percent-used per hour);
  if < 3 samples, fall back to first-vs-last slope. If slope ≤ 0 → `nil`.
- `timeToLimit = (100 − utilizationNow) / slope` hours → format `~3h` / `~40m`.
- Returns `BurnProjection?` `{ hoursLeft: Double, label: String }`.

### 3.3 Daily tokens (extend existing `StatsCache`)

- Read `~/.claude/stats-cache.json` → `dailyModelTokens`, summing per day across
  models for the last **7 days** → `[(date, tokens: Int)]` for the token
  sparkline. Cheap; no transcript scan. Missing keys → 0 for that day.

### 3.4 `ProjectUsageProbe` (new)

- Computes **tokens consumed today per project**.
- For each project dir `~/.claude/projects/<encoded>/` whose any `*.jsonl` was
  modified today (mtime ≥ local midnight — bounds the work), scan its session
  JSONL files: for each assistant message whose timestamp ≥ local midnight, sum
  `usage` = `input_tokens + output_tokens + cache_creation_input_tokens +
  cache_read_input_tokens` (same fields stats-cache aggregates).
- Output: `[ProjectUsage { name, tokensToday: Int, sessionCount: Int }]` sorted
  by `tokensToday` desc. `name` is the project (repo) name derived the same way
  as a session row's title.
- **Off-main**, on a work queue. **Throttle:** recompute at most every 30 s, and
  on Stats-tab open. **Time budget:** ~1.5 s; if exceeded, return what was summed
  so far plus a `partial = true` flag.
- **Fallback:** if the scan yields nothing usable (e.g., budget hit immediately),
  fall back to grouping the current live sessions by project (counts only,
  `tokensToday = nil`), so the breakdown still shows something truthful.

### 3.5 `AppStore` additions

- Owns a `UsageHistoryStore`; records a sample inside `applyUsage(.ok)`.
- Publishes: `usageHistory` (for sparkline), `burnRate5h`/`burnRate7d`
  (`BurnProjection?`), `projectUsage` (`[ProjectUsage]`), `dailyTokens`.
- Triggers `ProjectUsageProbe` (off-main) when the Stats tab opens and on the
  normal refresh tick while Stats is visible (subject to the 30 s throttle).
- **Threshold alert:** in `notifyUsageTransitions`, add a one-shot notification
  when a window crosses **≤ 20 % left** (tracked per window via a `prevLow`
  dict, mirroring the existing `prevExhausted` pattern; re-arms when it goes back
  above 20 %). The existing "limit reached" (0 %) notification stays.

### 3.6 UI

- **Inline burn-rate:** `UsageHeaderView`'s per-window row appends `· ~3h left`
  after the reset label when a `BurnProjection` exists, colored by urgency
  (e.g., red < 1 h, orange < 3 h, else secondary). Hidden when `nil`.
- **Tab switcher:** `NotchUIModel` gains `enum Tab { case agents, stats }` and
  `@Published var tab = .agents`. The expanded panel header shows an
  `Agents | Stats` segmented control. `expandedHeight()` picks a height based on
  the active tab (rows-based for Agents; a fixed height for Stats).
- **`StatsView` (new):** 5h & 7d utilization sparklines (with the burn label),
  a daily-tokens mini bar chart (last 7 days), and the per-project list
  (`name · tokensToday · sessionCount`; shows "—" tokens when `partial`/fallback).
- **`Sparkline` (new):** a small `Path`-based line/bar view; downsamples its
  input to ≤ ~80 points.

## 4. Feature B — Jump-to-window

### 4.1 `WindowJumper` (new)

`jump(_ row: SessionRow)`:

1. **tty:** `ps -o tty= -p <pid>` → e.g. `ttys003` → `/dev/ttys003`. If empty/dead
   → no-op with subtle feedback.
2. **Terminal app:** walk parent pids (`ps -o ppid= -p <pid>`) up the chain until
   a process matching a known terminal is found; resolve that pid to an app via
   `NSRunningApplication(processIdentifier:)`.
3. **Precise (Terminal.app / iTerm2):** run AppleScript (`NSAppleScript`) that
   selects the tab/session whose `tty` equals the agent's tty, raises its window,
   and `activate`s the app.
4. **Fallback (other terminals — Ghostty, WezTerm, Alacritty, kitty, VS Code,
   Warp, …):** `activate` the resolved app (brings it forward; no exact-tab
   selection — those terminals lack per-tab AppleScript).
5. **Unknown / not found:** no-op with subtle feedback (never crash).

- `ps`/`osascript` run off-main; activation on main.
- **Permission:** the AppleScript path triggers the macOS **Automation** (Apple
  Events) TCC prompt on first use ("HubPlus wants to control Terminal").
  `NSAppleEventsUsageDescription` is added to Info.plist. The fallback path needs
  no permission.

### 4.2 UI

- `SessionCardView` gains a trailing icon button (`arrow.up.forward.app`) →
  `onJump(row)`, wired `NotchContainerView → NotchRootView → NotchController →
  WindowJumper`.

## 5. Data flow

```
usage poll (60s) → applyUsage(.ok) → UsageHistoryStore.record + persist
                                   → BurnRate → @Published → inline + sparkline
Stats tab open / refresh tick     → ProjectUsageProbe (off-main) + StatsCache daily
                                   → @Published projectUsage / dailyTokens
card → jump button                → WindowJumper.jump (off-main ps/osascript)
                                   → AppleScript select-tab OR app activate (main)
```

## 6. Error handling

- **UsageHistoryStore:** file read/write/JSON errors are non-fatal (log; keep
  in-memory). Corrupt file → start empty. Size bounded by the 48 h ring.
- **BurnRate:** < 2 samples or slope ≤ 0 → hide projection. Utilization drop in
  the window → treat as reset, hide.
- **ProjectUsageProbe:** per-file parse errors skipped; time-budget hit → partial
  flag; nothing usable → live-session-grouping fallback. Today boundary = local
  midnight.
- **WindowJumper:** dead pid / no tty / unknown terminal → no-op + subtle
  feedback. AppleScript error (incl. permission denied) → fallback to app
  activate. Never crashes.

## 7. Security — prompt injection (kept first-class)

- The jump passes **only the numeric pid → tty obtained from `ps`** into
  AppleScript. **No** transcript-, model-, cwd-, or project-name string is ever
  interpolated into AppleScript or a shell. Untrusted text remains display-only
  and inert.
- No LLM runs over any untrusted text. The analytics features read only numeric
  token counts and timestamps from local files.

## 8. Testing

- **Unit (pure logic, with fixtures):** burn-rate projection from samples;
  reset detection; ring-buffer cap; per-project "today" token summation; tty
  string parsing from `ps` output; daily-token aggregation from a `stats-cache`
  fixture.
- **Manual:** history persistence across an app restart; jump on Terminal.app and
  iTerm2 (precise tab) plus a fallback terminal (e.g., Ghostty); Stats tab
  rendering driven by the existing demo-data path.
- AppleScript/window activation is not unit-testable headless — covered by the
  manual matrix above.

## 9. Files

**New:**
`HubPlus/Usage/UsageHistoryStore.swift`, `HubPlus/Usage/BurnRate.swift`,
`HubPlus/Watchers/ProjectUsageProbe.swift`, `HubPlus/App/WindowJumper.swift`,
`HubPlus/Views/StatsView.swift`, `HubPlus/Views/Sparkline.swift`.

**Changed:**
`HubPlus/Store/AppStore.swift`, `HubPlus/Store/StatsCache.swift`,
`HubPlus/Views/UsageHeaderView.swift`, `HubPlus/Views/SessionCardView.swift`,
`HubPlus/Views/NotchRootView.swift`, `HubPlus/Views/NotchContainerView.swift`
(+ `NotchUIModel` tab state), `HubPlus/App/NotchController.swift` (wire jump),
`project.yml` (Info.plist `NSAppleEventsUsageDescription`), possibly
`HubPlus/Views/Notifier.swift`.

## 10. Out of scope (now)

- Windows parity (jump via Win32 `SetForegroundWindow` + console matching;
  analytics on the same data layer) — a later phase.
- Cost ($) estimation — dropped.
- Any preferences/settings UI — constants for v1 (48 h ring, 30 min burn window,
  20 % threshold, 7-day daily tokens, 1.5 s probe budget, 30 s throttle).
