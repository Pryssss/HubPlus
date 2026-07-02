# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Fixed
- Two permanent-freeze paths in git subprocess handling: stderr is now drained instead
  of blocking on a full pipe buffer, and a kill-on-timeout watchdog stops hung `git`
  processes.
- Expanded panel clipping when new sessions appear — the panel now self-sizes to its
  SwiftUI content instead of using hand-computed heights.

### Changed
- Daily usage scan is now bounded/incremental and runs off the session-refresh queue
  instead of blocking it.
- `AppStore` now talks to Claude-specific data through an `AgentProvider`/`UsageProvider`
  seam, paving the way for non-Claude providers.

### Added
- Parser test coverage for transcript reading and the usage endpoint.

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
