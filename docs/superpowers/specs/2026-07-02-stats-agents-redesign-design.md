# Hub+ — Stats Tab Redesign & Agents Screen Upgrades (macOS)

- **Date:** 2026-07-02
- **Status:** Approved defaults (user AFK during Q&A — assumed decisions flagged in §7, veto on review)
- **Scope:** Stats tab, Agents tab, panel header token counter. macOS only.

## 1. Problem

The Stats tab is "not useful and unclear" (user report + screenshot evidence):

1. **"Tokens / day" is permanently flat.** `StatsCache` parses
   `dailyModelTokens` as a `{ "yyyy-MM-dd": … }` dictionary, but current Claude
   Code writes an **array** of `{ date, tokensByModel }` objects — the cast
   fails silently and every day reads 0. Worse, `~/.claude/stats-cache.json` on
   this machine was last computed **2026-02-15** and holds 2 days of data, so
   even a fixed parser would render an empty chart. The same broken source
   feeds the header's "⚡ N today" label, which therefore never appears.
2. **"By project today" is unreadable.** Values like `604137k` are the sum of
   input + output + cache-creation + **cache-read** tokens formatted as
   `n/1000 + "k"`. Cache reads inflate totals ~500×; real (input+output)
   tokens are ~0.2% of the displayed number.
3. **5h/7d sparklines carry no context.** No time axis, no current value, fixed
   120 pt width inside a 560 pt panel, no indication the window is 48 h.
4. **Agents tab leaves computed data unused.** `GitInfo.ahead/behind` is probed
   but never rendered; `statusUpdatedAt` exists but status duration ("busy for
   12m") is not shown; rows are unsorted, so a session that *needs the user*
   (waiting/blocked) can sit below idle ones.

## 2. Goals

- Stats answers, at a glance: **where do my tokens go** (per day, per project)
  and **how have my limits trended** (compact history above).
- Numbers a human can read (`1.2M`, not `604137k`), with honest semantics:
  primary = real input+output tokens; cache visible but secondary.
- Daily data from a source that is actually fresh: the transcripts themselves.
- Agents tab surfaces urgency (sort + status duration) and the already-probed
  git divergence.

Non-goals: cost ($) estimation, per-model charts, settings UI, hourly heatmaps,
history beyond 7 days, Windows parity.

## 3. Approaches considered

- **A. Minimal polish** — fix the `dailyModelTokens` array parse, format
  numbers, widen charts. Cheap, but the stats-cache file is stale on real
  machines (5 months here), so the centerpiece chart still lies. Rejected.
- **B. Transcript-derived stats (chosen)** — extend the existing
  `ProjectUsageProbe` resumable scan to bucket tokens **per day over the last
  7 days** and split **real vs cache** tokens. One scan feeds the daily chart,
  the per-project list, and the header counter. `StatsCache` is deleted (both
  of its consumers move to the probe; the source is stale *and*
  wrong-shaped).
- **C. Full analytics store** — own SQLite/JSON aggregate DB, per-model splits,
  cost estimates. Over-scope for a notch panel. Rejected (YAGNI).

Feasibility check (this machine): 1067 transcript files / 316 MB touched in the
last 7 days. The probe's existing per-file resumable cache + 1.5 s budget
converges over a few ticks; steady state skips unchanged files by size+mtime
without opening them.

## 4. Design — data layer

### 4.1 `TokenCount` (new, in ProjectUsageProbe.swift)

`struct TokenCount { var real: Int; var cache: Int }` — `real` =
`input_tokens + output_tokens`, `cache` = `cache_creation_input_tokens +
cache_read_input_tokens`. `+=` convenience. (Named struct, not tuple, so cache
entries stay `Codable`-ready and call sites read clearly.)

### 4.2 `ProjectUsageProbe` — 7-day bucketed scan

- `scanFile` gains day bucketing: instead of one `sinceEpoch` filter producing
  a single `Int`, it filters `timestamp >= startOfWindow` (7 local days back)
  and buckets each line's tokens by `calendar.startOfDay` epoch:
  `[Double: TokenCount]`.
- `FileCacheEntry` stores `boundaryByDay: [Double: TokenCount]` and
  `totalByDay: [Double: TokenCount]` (boundary + unterminated tail), plus the
  existing size/mtime/bytesConsumed/cwd/complete fields. The resume logic
  (append-only growth → resume at line boundary; shrink → rescan; deadline →
  partial with progress persisted) is unchanged.
- Cache key becomes `(path, windowStartDay)` — day rollover shifts the window,
  invalidating naturally, same as today's `(path, dayKey)`.
- mtime pre-filter: skip files with `mtime < startOfWindow` (was: local
  midnight). Directory pre-filter likewise.
- `compute(now:)` returns
  `(projects: [ProjectUsage], daily: [(date: Date, tokens: TokenCount)], partial: Bool)`:
  - `projects`: per project dir, **today's** `TokenCount` + session count,
    sorted by `real` desc — same identity/name derivation as today. Dirs whose
    window activity is all on *past* days (today = 0) still feed `daily` but
    are omitted from `projects`, so the "today" list never shows zero rows.
  - `daily`: last 7 local days ending today, summed across all projects;
    missing days = zero counts.
- `ProjectUsage` gains the split: `let tokens: TokenCount?` replaces
  `tokensToday: Int?` (nil keeps meaning "scan yielded nothing usable → show
  session count fallback").

### 4.3 `StatsCache` deleted

Both consumers (header "today", daily chart) move to the probe. The file and
`StatsCacheTests` are removed; `AppStore.refresh()` no longer computes
`tokensToday` — it comes from `refreshStats` output as `daily.last` (today).

### 4.4 `AppStore`

- `@Published dailyTokens: [(date: Date, tokens: TokenCount)]`,
  `projectUsage: [ProjectUsage]` (new shape), `tokensToday: Int?` now derived
  (today's `real`).
- `refresh()` (3 s tick) additionally calls `refreshStats()` — the existing
  30 s self-throttle stands, so stats stay warm while the panel is open
  instead of only refreshing on expand.

## 5. Design — UI

Panel width is 560 (content 536). All token numbers go through a shared
`TokenFormat.compact(_: Int) -> String`: `0…999` → `"512"`, `<10k` → `"9.4k"`,
`<1M` → `"604k"`, `<10M` → `"1.2M"`, `<1B` → `"604M"`, else `"1.2B"`. One
decimal only below the 10× threshold. Unit-tested.

### 5.1 Stats tab layout (top → bottom)

1. **Summary chips** — three fixed stat tiles in an HStack: `Today` (real
   tokens), `7 days` (sum of daily real), `Top project` (name of
   `projects.first`, or "—"). Tile = caption (10 pt secondary) over value
   (15 pt semibold white). Cache totals for today in a `.help` tooltip on the
   Today tile.
2. **Limits · 48h** — section header (10 pt secondary, "LIMITS · LAST 48H"
   style consistent with other sections). Two rows (5h green, 7d blue), each:
   label (11 pt, 18 pt wide) · sparkline **filling remaining width** (height
   26) · right-aligned current chip ("33% used", 10 pt, colored by threshold
   ≥90 red / ≥70 yellow / else secondary). Sparkline upgrades (in
   `Sparkline.swift`): optional `fill` gradient under the line (8% opacity),
   dotted 100% guide at top edge, terminal dot at the last point. Fewer than 2
   samples → "collecting…" placeholder as today.
3. **Tokens · 7 days** — bar chart across the full width: 7 slots, each a
   vertical bar (real tokens, orange, today tinted white-orange + weekday
   label emphasized), value label above each nonzero bar
   (`TokenFormat.compact`, 8 pt secondary), weekday initial below (9 pt,
   localized). Bar height scales to the 7-day max (min 2 pt when nonzero;
   zero-days render a 1 pt baseline tick, not a fake bar). Chart height 48.
4. **By project · today** — up to 6 rows, each: project name (11 pt white,
   truncating) · proportional share bar (thin 3 pt rounded capsule, orange,
   width = real/max across listed projects, flexible middle) · right-aligned
   `TokenFormat.compact(real)` (11 pt white) + `"· N sess"` (10 pt secondary).
   Row `.help`: "real in/out · cache X · N sessions". `tokens == nil` fallback
   → "N sess" only, no bar. More than 6 projects → trailing "+N more" line
   (9 pt secondary). "partial — scanning…" note stays.

Sections separated by the existing 0.2-opacity dividers; consistent 10 pt
uppercase-style section captions.

### 5.2 Agents tab

- **Sort** (in `NotchRootView`, view-level — store order untouched for
  notification logic): urgency rank `waiting(blocked) = waiting(approve) <
  error < busy < idle < unknown`, stable by title within a rank. Animated with
  the default transaction so reorders don't teleport.
- **Status duration** in the capsule: `BUSY · 12m` using
  `statusUpdatedAt` (RelativeDateTimeFormatter is for the right-edge age; the
  capsule uses a compact `Xm`/`Xh` custom label, hidden when < 1 min).
- **Git divergence**: after the branch name, `↑2` and/or `↓1` (9 pt,
  secondary) when nonzero, next to the existing dirty dot.
- **Empty state**: "No live Claude Code sessions" + second line (10 pt,
  tertiary) "Sessions appear when `claude` runs in a terminal".
- Everything else (last-message line, model/context capsules, jump button)
  unchanged.

### 5.3 Header

"⚡ 1.2M today" — same `Label`, value = today's **real** tokens from the probe
(shown once stats have loaded; hidden before first probe completes, as today
with nil).

## 6. Errors, performance, testing

- **Probe cost**: bounded by the existing 1.5 s budget + resumable per-file
  cache; 7-day window only multiplies the *first* scan (~316 MB here →
  converges across a few ticks with `partial = true` shown); steady state
  re-reads only appended bytes. Cache memory: ≤ 7 `TokenCount`s per file entry.
- **Clock/locale**: day bucketing uses the injected `Calendar` (tests pass
  fixed calendars/timezones, as `StatsCache.dailyTokens` tests did).
- **Failure modes preserved**: transient open failure → last cached totals;
  deleted files pruned only when their directory was enumerated; day rollover
  → natural cache miss.
- **Tests** (XCTest, pure funcs first):
  - `ProjectUsageProbeTests`: existing cases updated to the bucketed shapes +
    new: multi-day bucketing across boundary, real/cache split, `daily` zero
    fill, window-start pre-filter, resume path with buckets.
  - New `TokenFormatTests`: thresholds 999/1.0k/9.9k/10k/604k/1.2M/604M/1.2B.
  - New sort-comparator tests (urgency ranks, stability) and status-duration
    label tests — extracted as pure helpers.
  - `AppStoreProviderTests`: header `tokensToday` derives from probe output.
  - Removed: `StatsCacheTests` (source deleted).
- **Verification**: `xcodebuild test` (scheme HubPlus) + launch the app and
  screenshot the expanded panel for a visual check.

## 7. Assumed decisions (user was AFK — veto any of these)

1. **Stats purpose**: consumption-first dashboard (tokens by day/project) with
   a compact limits-history block — not a limits-centric screen (limits + burn
   already live in the header).
2. **Token semantics**: primary numbers everywhere = real input+output; cache
   shown secondarily (tooltip/help). The old inflated totals disappear.
3. **`StatsCache` deleted** rather than fixed-and-kept-as-fallback (stale
   source, two consumers both better served by the probe).
4. **Agents additions**: urgency sort, status duration, ↑/↓ divergence, empty
   state — chosen as the highest-value, data-already-available upgrades.
   Per-session token counts were considered and dropped (needs a per-session
   full-transcript scan; not worth it yet).
5. **Summary chips row** added atop Stats (cheap, answers "how much today"
   instantly).

## 8. Out of scope / later

- Per-model breakdown (`modelUsage`), hourly heatmap, cost estimates.
- FSEvents-driven refresh (polling stands).
- Clicking a project row to filter agents.
