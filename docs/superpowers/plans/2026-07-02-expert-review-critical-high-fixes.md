# Plan: Fix critical + high-priority findings from the 2026-07-02 expert review

Branch: `fix/expert-review-critical-high` (off `feat/usage-analytics-jump` @ e9b11ea).

Source: four-way expert review (architecture, robustness/concurrency, security, tests/build).
Scope: the two critical findings (permanent-freeze paths) and the five high-priority ones
(provider abstraction, self-sizing panel, ProjectUsageProbe memory, parser tests, CI/versioning).
Medium/low findings are explicitly OUT of scope.

## Global Constraints

- Build & test gate after every task: `xcodegen generate && xcodebuild -project HubPlus.xcodeproj -scheme HubPlus -destination 'platform=macOS' test` — all tests pass, no new warnings.
- Swift 5 language mode, macOS 14.0 deployment target. No new dependencies, no packages.
- All user-visible behavior stays identical unless the task says otherwise.
- Follow existing code style: comments explain *why*, not what; small focused files; injected clocks for anything time-dependent in tests.
- Tests must be deterministic: no sleeps for synchronization, no network, no Keychain, temp dirs cleaned up.
- Do not restructure code outside your task. Adjacent low-priority findings are out of scope unless your task names them.

## Task 1: Shell subprocess hardening — stderr drain + timeout

**Problem (critical).** `HubPlus/Support/Shell.swift` sets `proc.standardError = Pipe()` whose read end is never read. Any child writing >64KB to stderr (e.g. git emitting thousands of `warning: unable to access` lines) blocks on the full pipe, never exits, and the parent blocks forever in `readDataToEndOfFile()`. This runs on `AppStore`'s single serial `work` queue, so the whole HUD freezes permanently. Separately, there is no timeout: a cwd on a dead SMB/NFS mount hangs `git status` in uninterruptible I/O with the same permanent-freeze result.

**Requirements:**
1. In `Shell.run`, discard stderr via `proc.standardError = FileHandle.nullDevice` (stderr output is never used).
2. Add a timeout (parameter `timeout: TimeInterval = 10`). If the process has not exited by the deadline, `terminate()` it (send SIGKILL after a short grace period if it still hasn't exited — `terminate()` can be ignored/blocked by a hung child) and return `nil`. Beware the classic ordering bug: stdout must be drained before/while waiting, never after `waitUntilExit()`. A watchdog `DispatchWorkItem`/`DispatchSourceTimer` that terminates the process is an acceptable design; `readDataToEndOfFile()` returns once the child dies and the pipe closes.
3. Remove the unused `cwd:` parameter from `Shell.run` (verify no call site passes it — `GitProbe` uses `git -C` instead).
4. In `HubPlus/Watchers/GitProbe.swift`, remove the `FileManager.default.fileExists(atPath: cwd)` pre-check (it also blocks on dead mounts); let `git -C <cwd>` fail fast instead — `Shell.run` returning nil on non-zero exit already yields `probe → nil`.
5. New `HubPlusTests/ShellTests.swift` (TDD — write the stderr-flood and timeout tests first, watch them fail/hang-guard, then implement):
   - `/bin/echo hi` → `"hi"` (trimmed).
   - non-zero exit (e.g. `/usr/bin/false`) → `nil`.
   - stderr flood does not deadlock: `/bin/sh -c 'head -c 200000 /dev/zero | tr "\0" e 1>&2; echo ok'` → `"ok"`, completing well under the timeout.
   - timeout: `/bin/sleep 30` with `timeout: 0.5` returns `nil` in ~under 3 s (assert elapsed time bound, generously).

**Files:** `HubPlus/Support/Shell.swift`, `HubPlus/Watchers/GitProbe.swift`, `HubPlusTests/ShellTests.swift` (new).

## Task 2: ProjectUsageProbe — bounded, incremental scanning off the hot queue

**Problem (high).** `HubPlus/Watchers/ProjectUsageProbe.swift` `compute` does `try? String(contentsOf: f)` on every `.jsonl` transcript (they reach tens–hundreds of MB), splits all lines (≈3× memory), re-parses everything from scratch every 30 s, reads files that cannot possibly contain today's entries, and only checks its 1.5 s deadline *between* files. It runs on the same serial `work` queue as the 3 s session refresh in `AppStore`, so a slow scan delays session updates.

**Requirements:**
1. Skip any transcript file whose modification date is before the start of `today` (per the injected `calendar`/`now` already threaded through `compute`) — a file not written today cannot contain lines timestamped today. Keep the existing directory-level filter as-is.
2. Replace whole-file `String(contentsOf:)` with bounded streaming: read the file in chunks via `FileHandle` (e.g. 1 MB chunks), splitting on `\n` across chunk boundaries, so peak memory is O(chunk), not O(file).
3. Check the wall-clock deadline inside the per-line loop (or at least per chunk), not only between files, so one huge file cannot blow the budget.
4. Add a per-file result cache keyed by `(path, size, mtime)` holding that file's token total for the current day-key, so unchanged files are never re-parsed on the next 30 s tick. The cache must be invalidated when the day changes (key it by day as well) and must not grow unboundedly (drop entries for files no longer seen). Since `compute` is currently a pure static, hold the cache in the type behind an internal lock, or convert the probe to an instance owned by `AppStore` — choose the smaller diff that keeps `compute(root:now:calendar:)`'s signature testable.
5. In `HubPlus/Store/AppStore.swift`, move `refreshStats()` work onto its own serial queue with `.utility` QoS (separate from the 3 s `work` queue) so stats scans never delay session refreshes. Published-property assignments must still happen on the main thread exactly as they do now.
6. Tests (extend `HubPlusTests/ProjectUsageProbeTests.swift`, keep existing three passing):
   - a transcript file with mtime set to yesterday (via `FileManager.setAttributes`) is not counted even if its contents carry today-timestamps;
   - incremental behavior: compute → append a valid today-line to a file → compute again → total increases by the appended amount;
   - a line split across the streaming chunk boundary is still parsed correctly (use a small injectable chunk size, or construct a file larger than one chunk).

**Files:** `HubPlus/Watchers/ProjectUsageProbe.swift`, `HubPlus/Store/AppStore.swift`, `HubPlusTests/ProjectUsageProbeTests.swift`.

## Task 3: Make TranscriptReader and UsageClient parsing testable, and test them

**Problem (high).** The two riskiest parsers have zero tests. `HubPlus/Watchers/TranscriptReader.swift` (last-assistant extraction, model, context tokens, ISO dates, latest-cwd-wins, and `sanitize()` — a stated security boundary) is hard-wired to `ClaudePaths` under `~/.claude`. `HubPlus/Usage/UsageClient.swift`'s response parsing (`window()`, `parseDate()` with 5 fallback formats) is private and fused to the live network call against an undocumented Anthropic endpoint — the app's #1 external-drift risk.

**Requirements:**
1. `TranscriptReader.snapshot(cwd:sessionId:)` gains a `root: URL = ClaudePaths.claudeDir` (or equivalent) parameter so tests can point it at a fixture directory. Default keeps production behavior identical.
2. Extract UsageClient's response handling into `static func parse(statusCode: Int, data: Data) -> UsageResult` (internal, not private); `fetch()` becomes: build request → dataTask → `parse(...)`. No behavior change.
3. New `HubPlusTests/TranscriptReaderTests.swift` — fixture JSONL written to a temp dir, covering:
   - last assistant text extraction (assistant/user/tool lines interleaved), model field, context tokens = `input + cache_read + cache_creation`;
   - ISO timestamps both fractional and plain;
   - latest-cwd-wins;
   - `sanitize`: ESC/ANSI control chars stripped, 240-char cap, newlines flattened;
   - tolerance of a torn (truncated) final line.
4. New `HubPlusTests/UsageClientParseTests.swift` — fixture JSON `Data`, covering:
   - utilization as Int and as Double;
   - both windows present → `.ok` with correct percents;
   - missing both windows → `.transient`;
   - HTTP 401 and 403 → `.authError`; 429 and 500 → `.transient`;
   - `resets_at` in each supported format: ISO with fractional seconds, plain ISO, epoch seconds, epoch milliseconds.
5. Cheap adjacent pure-function tests (same commit, small): `SessionInfo.statusKind` string-table mapping (including `"waiting-approval"`, `"blocked"`, `"needs-input"` → `.waiting`, unknown → `.unknown`) and `ClaudePaths.encodedProjectDirName` (hyphens, spaces, unicode).
6. TDD where refactoring permits: for pure additions (the test files), write tests first against the refactored seams.

**Files:** `HubPlus/Watchers/TranscriptReader.swift`, `HubPlus/Usage/UsageClient.swift`, `HubPlusTests/TranscriptReaderTests.swift` (new), `HubPlusTests/UsageClientParseTests.swift` (new), plus small test files for item 5.

## Task 4: Self-sizing expanded panel — delete hand-computed heights

**Problem (high).** `HubPlus/App/NotchController.swift` `expandedHeight()` duplicates the SwiftUI layout as arithmetic (`chrome = 20 + 34 + 68 + 40`, agent row = 52, stats = 176 + …), with two `DispatchQueue.main.async { applyFrame() }` re-fit hacks (tab change, `$projectUsage` arrival). Any padding/font change silently clips the panel. Concrete live bug: no `$rows` sink exists, so with the panel pinned open on the Agents tab a new session's row is clipped (or a dead session leaves blank space) until the user collapses/re-expands.

**Requirements:**
1. Make SwiftUI the source of truth for the expanded panel's content size. Preferred: `NSHostingView`/`NSHostingController` `sizingOptions = [.preferredContentSize]` with KVO observation of `preferredContentSize`, or a `GeometryReader`/preference-key (`onGeometryChange` only if available on macOS 14.0) callback from the root expanded view into the controller. The controller's `applyFrame` consumes the reported size instead of computing it.
2. Delete `expandedHeight()` and both deferred re-fit workarounds; the size-report path must cover all the cases they covered (tab switch, projects loading, expand/collapse) plus row-count changes.
3. Preserve exactly: collapsed pill sizing/behavior, edge docking and reorientation (vertical edges), snap behavior, expand/collapse animation, and the panel's max-height clamping to the screen (if the current code clamps, keep clamping; if content exceeds screen height, it must not grow off-screen).
4. Verification: `xcodegen generate && xcodebuild … test` green, plus build and launch the app once (`xcodebuild -scheme HubPlus -configuration Debug build` then run the built product briefly) to confirm it launches and the panel expands without console layout errors; describe in the report what was and wasn't verifiable headlessly.

**Files:** `HubPlus/App/NotchController.swift`, `HubPlus/Views/NotchContainerView.swift` and/or `HubPlus/Views/NotchRootView.swift` (whichever hosts the expanded content).

## Task 5: Provider abstraction — decouple AppStore from Claude-specific statics

**Problem (high).** Every data source is a hard-wired static: `AppStore.refresh()` calls `SessionWatcher.readLiveSessions()`, `TranscriptReader.snapshot`, `GitProbe.probe`, `StatsCache.tokensToday()`; `refreshUsage()` calls `UsageClient.fetch()` which itself reads the Keychain. The roadmap (Codex/other agent providers; fully-local usage estimation with no network) has no seam to plug into, and `AppStore` cannot be constructed in tests without touching the user's real `~/.claude` and Application Support.

**Requirements:**
1. Introduce two protocols (new files under `HubPlus/Providers/`):
   ```swift
   protocol AgentProvider {
       var id: String { get }
       func liveSessions() -> [SessionInfo]
       func transcriptSnapshot(cwd: String, sessionId: String) -> TranscriptSnapshot?
   }
   protocol UsageProvider {
       func fetch() async -> UsageResult
   }
   ```
   (Adjust signatures minimally to match the actual current call shapes in `AppStore.refresh()` — the protocol should mirror what `refresh()` needs today, not speculate.)
2. `ClaudeAgentProvider` wraps the existing `SessionWatcher`/`TranscriptReader` statics; `ClaudeOAuthUsageProvider` wraps token acquisition (`KeychainReader.claudeCodeToken()`) + `UsageClient` — token acquisition moves OUT of `UsageClient.fetch()` and into the provider (e.g. `UsageClient.fetch(token:)`), so a future local-estimation provider needs no token. Keep `UsageClient.parse` from Task 3 untouched.
3. `AppStore.init(agents: [AgentProvider] = [ClaudeAgentProvider()], usage: UsageProvider = ClaudeOAuthUsageProvider(), history: UsageHistoryStore = UsageHistoryStore(fileURL: UsageHistoryStore.defaultURL()))` — the history store becomes injected too (today it's a property initializer that touches real Application Support in any test that constructs AppStore).
4. `SessionRow` (or `SessionInfo` — pick the smaller ripple) carries `providerID: String` so views/notifications can distinguish sources later. Default `"claude"` for the existing provider. No UI change.
5. Testability injection for the wrapped statics, mirroring the pattern `ProjectUsageProbe.compute(root:)` already uses: `SessionWatcher.readLiveSessions(root: URL = ClaudePaths.sessionsDir)` and `StatsCache.tokensToday(root:)` (or equivalent) gain root parameters with production defaults.
6. GitProbe and stats (`tokensToday`, `dailyTokens`, `projectUsage`) may stay direct calls in AppStore for now — they are host-machine concerns, not provider concerns. Do NOT build a registry, plugin loader, or any second provider.
7. New test: construct `AppStore` with a fake `AgentProvider`/`UsageProvider` and a temp-file history store; drive one refresh (call the internal refresh method directly or via a short expectation) and assert `rows` reflects the fake's sessions and `usage` reflects the fake's result. No timers needed — construct with timers not started if that requires a flag, prefer exposing the existing internal refresh for tests via `@testable`.
8. Behavior must be byte-for-byte identical at runtime: same refresh cadence, same notifications, same UI.

**Files:** `HubPlus/Providers/AgentProvider.swift` (new), `HubPlus/Providers/ClaudeAgentProvider.swift` (new), `HubPlus/Providers/UsageProviders.swift` (new), `HubPlus/Store/AppStore.swift`, `HubPlus/Usage/UsageClient.swift`, `HubPlus/Usage/KeychainReader.swift` (only if needed), `HubPlus/Models/SessionRow.swift` or `SessionInfo.swift`, `HubPlus/Watchers/SessionWatcher.swift`, `HubPlus/Store/StatsCache.swift`, `HubPlusTests/AppStoreProviderTests.swift` (new).

## Task 6: CI, versioning, and a scripted release

**Problem (high).** No CI despite a fast green suite; version hardcoded `1.0`/`1` in Info.plist; zero git tags; the shipped `dist/HubPlus.dmg` was built by hand with no script; no CHANGELOG.

**Requirements:**
1. `.github/workflows/ci.yml`:
   - Job `macos` on `macos-15`: checkout → `brew install xcodegen` → `xcodegen generate` → `xcodebuild -project HubPlus.xcodeproj -scheme HubPlus -destination 'platform=macOS' test`. (The whole `.xcodeproj` is gitignored by design — generation is a hard prerequisite; do not commit the xcodeproj.)
   - Job `windows` on `windows-latest`: checkout → `actions/setup-dotnet` with dotnet 8 → `dotnet build windows/HubPlusWin -c Release` (build only; no tests exist there).
   - Trigger on `push` to `main` and on `pull_request`.
2. Versioning single source of truth: `MARKETING_VERSION: 0.1.0` and `CURRENT_PROJECT_VERSION: 1` in `project.yml` settings; `HubPlus/Resources/Info.plist` switches to `$(MARKETING_VERSION)` / `$(CURRENT_PROJECT_VERSION)`. Also add `gatherCoverageData: true` to the scheme's test options in `project.yml` (XcodeGen `schemes.HubPlus.test.gatherCoverageData`).
3. `scripts/make-dmg.sh` (executable, `set -euo pipefail`): xcodegen generate → Release build into a derived-data path under `./.build` → create `dist/HubPlus-<MARKETING_VERSION>.dmg` via `hdiutil create -volname "Hub+" -srcfolder <staging with HubPlus.app and an /Applications symlink> -ov -format UDZO`. Read the version from `project.yml` (grep/sed is fine). Include a commented-out `notarytool submit`/`stapler` section and echo a note that ad-hoc-signed builds require `xattr -dr com.apple.quarantine HubPlus.app` on other machines.
4. `CHANGELOG.md` (Keep a Changelog format) with an `## [Unreleased]` section summarizing this branch's fixes and `## [0.1.0]` for the existing feature set (one-liners; date 2026-07-02).
5. README: fix the broken XcodeGen link (`yonifc` → `yonaskolb`) and add one line under Build/macOS pointing at `scripts/make-dmg.sh`. Do not create git tags — note in the report that tagging `v0.1.0` is left to the maintainer.
6. Verification: `xcodegen generate && xcodebuild … test` still green after the project.yml/Info.plist changes (this validates the version variables); `bash -n scripts/make-dmg.sh`; run `scripts/make-dmg.sh` end-to-end if the build environment allows and report the result either way. Validate the workflow YAML parses (e.g. `ruby -ryaml -e 'YAML.load_file(".github/workflows/ci.yml")'`).

**Files:** `.github/workflows/ci.yml` (new), `project.yml`, `HubPlus/Resources/Info.plist`, `scripts/make-dmg.sh` (new), `CHANGELOG.md` (new), `README.md`.
