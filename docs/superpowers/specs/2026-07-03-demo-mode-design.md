# Demo mode (`HUBPLUS_DEMO=1`) — design

**Date:** 2026-07-03
**Status:** approved (approach A of A/B/C)

## Problem

Repo screenshots are captured from the live app, which renders the developer's real
data: project names, branch names, and last transcript messages. That leaks private
project details into a public repo. We need a way to run the app on believable mock
data so screenshots (and demos) show nothing real.

## Decision

A `HUBPLUS_DEMO=1` environment variable (same dev-affordance family as
`HUBPLUS_OPEN=stats|agents`, composable with it) that swaps every data source for
deterministic in-code demo fixtures. No real file, keychain, or network access is
replaced piecemeal — the store is constructed fully from demo providers.

## Architecture

`AppStore` already takes injectable `agents: [AgentProvider]`, `usage: UsageProvider`,
and `history: UsageHistoryStore`. Two data paths still bypass the seams; demo mode
adds a seam for each, with defaults that reproduce today's behavior byte-for-byte:

1. **Git**: `refresh()` calls `GitProbe.probe(cwd:)` directly. New init parameter
   `gitProbe: @Sendable (String) -> GitInfo?` defaulting to `GitProbe.probe`.
2. **Stats**: `refreshStats()` calls `ProjectUsageProbe.compute(now:)` directly. New
   init parameter `stats: @Sendable (Date) -> (projects: [ProjectUsage], daily:
   [(date: Date, tokens: TokenCount)], partial: Bool)` defaulting to a
   `ProjectUsageProbe.compute` wrapper.

New file `HubPlus/Providers/DemoProviders.swift`:

- `DemoAgentProvider: AgentProvider` — four sessions covering every UI state:
  waiting (checkout-service), busy (mobile-app), idle ×2 (docs-site, infra), with
  distinct models, context %, status ages, and English last-messages.
- `DemoUsageProvider: UsageProvider` — an `.ok` snapshot (5h ≈ 89% left resetting in
  ~2h, 7d ≈ 44% left resetting next day).
- `DemoData` — fixture table shared by the pieces: per-cwd `GitInfo` (branches,
  ahead/behind, dirty), a 7-day daily-token series, per-project shares whose today
  sum equals the daily series' last entry, and a seeded 48h usage history (sawtooth
  5h series, slow-rising 7d series, both ending at the snapshot's utilizations)
  written as `[UsageSample]` JSON to a temp file and loaded via the existing
  `UsageHistoryStore(fileURL:)` initializer — no store changes.
- `AppStore.demo()` — factory wiring all of the above.

`AppDelegate` picks the store: `HUBPLUS_DEMO=1` → `AppStore.demo()`, else `AppStore()`.

## Data coherence rules

- Today's per-project token sum equals the last daily bar and drives the header
  counter ("N today").
- Seeded history's final sample matches the usage snapshot's utilizations, so the
  sparkline endpoint agrees with the 5h/7d bars.
- Cache tokens dwarf real tokens (~40×), matching real transcript proportions.
- All timestamps are relative to launch time, so ages ("BUSY · 12m") stay plausible.

## Testing

`DemoModeTests`: provider covers waiting/busy/idle, every session has a transcript
and git info; seeded history spans ~48h, is time-ordered, ends at the snapshot
utilizations; stats daily has 7 entries and project sum == today's real tokens.

## Out of scope

- Windows app demo mode.
- Screenshot automation tooling (stays ad-hoc).
- Localizing demo content.
