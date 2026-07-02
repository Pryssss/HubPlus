# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Fixed
- Permanent-freeze paths in git subprocess handling: stderr is now drained instead of
  blocking on a full pipe buffer, a kill-on-timeout watchdog stops hung `git` processes,
  and the caller is now bounded by its own parent-side deadline (not just the watchdog),
  so a child stuck in uninterruptible I/O (dead SMB/NFS mount) or a helper process that
  keeps the output pipe open past the kill can no longer block the caller forever either.
- Expanded panel clipping when new sessions appear — the panel now self-sizes to its
  SwiftUI content instead of using hand-computed heights.
- "Tokens / day" was permanently flat: it read `~/.claude/stats-cache.json`, which is
  both stale (months old on real machines) and shaped differently than the parser
  expected (`dailyModelTokens` is now an array). Daily tokens now come from the same
  bounded transcript scan as the per-project stats, so the chart reflects reality.
- The header "⚡ today" counter never appeared (same broken source); it now shows real
  tokens from the transcript scan once a complete pass finishes.

### Changed
- Daily usage scan is now bounded/incremental and runs off the session-refresh queue
  instead of blocking it.
- `AppStore` now talks to Claude-specific data through an `AgentProvider`/`UsageProvider`
  seam, paving the way for non-Claude providers.
- Token numbers are now humanized everywhere ("1.2M", not "604137k") and mean real
  input+output tokens rather than cache-inflated totals (cache stays in tooltips).
- Limit sparklines fill the panel width with a dotted 100% guide, gradient fill, and a
  current "% used" readout.

### Added
- Parser test coverage for transcript reading and the usage endpoint.
- GitHub Actions CI (macOS test job + Windows build job), single-source app versioning
  via `project.yml`, and a scripted dmg release (`scripts/make-dmg.sh`).
- Stats tab: summary chips (today / 7 days / top project), per-day token bars for the
  last 7 days, and proportional per-project share bars — all derived from local
  transcripts with a real (input+output) vs cache token split.
- Agents tab: sessions sort by urgency (waiting → error → busy → idle), status capsules
  show how long the state has lasted ("BUSY · 12m"), and branches show git ahead/behind
  (↑2 ↓1).
- `HUBPLUS_OPEN=stats|agents` env var force-expands the panel on launch (dev/testing
  affordance for screenshots and UI verification).

## [0.1.0] - 2026-07-02

### Added
- Live session monitor: status (idle/busy/waiting), model, context-window %, git repo +
  branch, and last message — a macOS notch island (drag-to-edge, hotkey, notifications)
  and a Windows tray + floating panel.
- Subscription usage tracking: 5h/7d limit windows with % left and reset times, plus an
  inline burn-rate (time-to-limit) projection.
- Persisted usage history (`UsageHistoryStore`) and a Stats tab with sparklines, daily
  token totals, and a per-project breakdown.
- Low-limit (20%) threshold notification.
- WindowJumper: jump straight to an agent's terminal window/tab from its session card.
- `HubPlusTests` XCTest target and initial test suite.
