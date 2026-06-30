# Hub+ — design spec

A macOS notch HUD that **monitors** every local Claude Code session and **controls**
the agents it launches itself. Inspired by `agent.notch`; distinct from `AgentHub`
(which is an orchestrator/kanban). Hub+ is an observability HUD first, a launcher second.

- Display name: **Hub+** · target/bundle: `HubPlus` / `com.hubplus.app`
- Native macOS SwiftUI + AppKit, accessory app (`LSUIElement`), not sandboxed.
- Ground truth for all capabilities was verified against the installed CLI
  (`claude` 2.1.196) by grepping the binary — **no dependency on third-party sources.**

---

## Verified facts (installed CLI 2.1.196, local machine)

| Need | Evidence on disk / in binary |
|---|---|
| Live session registry | `~/.claude/sessions/<pid>.json` → `{pid, sessionId, cwd, name, status(busy/idle), kind, entrypoint, version, peerProtocol, startedAt, updatedAt, statusUpdatedAt}` |
| Transcript / model / tokens | `~/.claude/projects/<encoded-cwd>/<sessionId>.jsonl` → per-line events; assistant lines carry `message.model` (e.g. `claude-opus-4-8`) and `message.usage` (input/output/cache tokens) |
| Tokens today | `~/.claude/stats-cache.json` → `dailyModelTokens` |
| Subscription limits (5h/7d) | `GET https://api.anthropic.com/api/oauth/usage` (the CLI's `fetchUtilization`), Bearer OAuth token; fallback `anthropic-ratelimit-unified-*` response headers (`-reset`, `-status`, `-overage-*`, `-representative-claim`) |
| OAuth token | macOS Keychain generic item, service `Claude Code-credentials` |
| Clean approve / control | binary strings: `--permission-prompt-tool` (×12), `--input-format stream-json`, `canUseTool` (×85), `--bg/--background`, `claude agents` |

`encoded-cwd` = absolute cwd with every non-alphanumeric char replaced by `-`
(e.g. `/Users/me/projects` → `-Users-me-projects`).

---

## Scope

**v1 (in):** monitor all sessions · usage panel (5h/7d + today) · launch agents from
the notch under full control · clean tool-approval · native notifications · notch
pill ⇄ panel UI.

**Deferred (v2+):** controlling *foreign* terminal sessions (tmux send-keys / reverse
`peerProtocol`) · other providers (Codex / Gemini CLI) · usage history & charts.

---

## §1 Architecture (components + trust boundary)

```
                         NotchUI (SwiftUI)  —  pill ⇄ panel, everything INERT text
   ┌──────── TRUSTED (local) ────────┐   ┌──────── CONTROL (we own the proc) ──────┐
 SessionWatcher  UsageClient  GitProbe   AgentLauncher              ApprovalBroker
 FSEvents on     Keychain →   git in     claude --input-format      local MCP that
 sessions/*.json oauth/usage  cwd:       stream-json (+ permission  --permission-prompt
 → live registry 5h/7d+today  branch/    -prompt-tool) — owns &     -tool calls → shows
                              status      streams the agent          RAW action → y/n
 TranscriptReader  ◀── UNTRUSTED ──▶  tail projects/**/<sid>.jsonl
 last msg, model, ctx%             (tool output / GitHub text = display-only, never
                                    executed, never fed to any in-app model)
 Notifier: finished / waiting-approval / hit-limit
```

- **Monitor** (Watcher + Transcript + Usage + Git) is read-only and runs for **every**
  session.
- **Control** (Launcher + Broker) runs **only** for agents Hub+ spawned
  (`--permission-prompt-tool` is a flag on *our* invocation). Foreign terminal sessions
  stay view-only — by design.
- Each unit is independently testable from a fixture file.

## §2 UI

- **Collapsed pill** in the notch: logo + agent count + summary status dot
  (green idle / yellow busy / red waiting-approval). Pulses on attention.
- **Expanded panel** (hover = peek, click = pin): header (count, ⚡today, open) →
  Claude usage rows (5h, 7d bars with % left + reset) → session cards → `+ Launch agent`.
- **Card:** status dot · name · `⎇ branch` + git state · age · last transcript line
  (inert, truncated) · `[status pill] [model] [context % bar]` · hover actions.
- **Approve morph** (security-critical): card shows the tool name + the **verbatim**
  action (exact Bash command / path / URL) and `[Deny] [Approve once] [Approve for session]`.
- States: idle · busy (spinner) · waiting-approval · hit-limit (red badge) · error.

## §3 Data flow

- Event-driven where possible: FSEvents on `sessions/` and on each active `.jsonl`;
  polling for usage (~45s) and git (~5s). Central `AppStore` (ObservableObject),
  ~150ms debounce, drives SwiftUI.
- **Sessions:** read `<pid>.json`, prune entries whose pid is dead (`kill(pid,0)`).
- **Transcript:** deterministic path from `cwd`+`sessionId`; tail from last offset;
  context % = `(input+cache_read+cache_creation tokens of last assistant msg) / window`
  (`opus-4-8`=200k, `[1m]` variant=1M, default 200k).
- **UsageClient:** read Keychain `Claude Code-credentials` via `SecItemCopyMatching`
  (first access prompts the user once — expected); `GET oauth/usage` with
  `Authorization: Bearer <token>`; parse 5h/7d windows + reset. Fallback: parse
  `anthropic-ratelimit-unified-*` response headers. `401` → soft "re-auth in terminal".
  **Token is read-only, sent only to Anthropic's domain, never logged/shown/forwarded.**
  Pinned endpoint: `GET https://api.anthropic.com/api/oauth/usage` (the CLI's
  `fetchUtilization`; returns the utilization object `/usage` renders).
- **Controlled agents:** read structured events straight from the agent's
  `stream-json` stdout (lowest latency), not the file.

## §4 Control & clean approve

- **Launch:** `claude --input-format stream-json --output-format stream-json
  --permission-prompt-tool <hubplus-mcp> --add-dir <repo> [--agent ...]`, spawned as a
  child `Process` Hub+ owns. We write user turns as stream-json to stdin; read
  assistant/tool/result events from stdout.
- **ApprovalBroker:** Hub+ hosts a tiny local MCP server exposing the permission-prompt
  tool named by `--permission-prompt-tool`. When the agent wants a tool, Claude Code
  calls our MCP tool with `{tool_name, input}`; we surface the **verbatim** action in the
  notch, await the human, and return allow/deny (and updated input on "modify"). This is
  the supported, structured handshake — never blind keystrokes.
- **Resume:** persist sessionId; relaunch with `--resume <id>` after app restart.

## §5 Threat model — prompt injection (first-class)

All transcript text, tool output, and any GitHub/git data are **untrusted**.

1. **Reviewer-targeted injection** ("just tidying up" hiding `rm -rf`): the approve UI
   renders the **verbatim** tool action, never a paraphrase or model summary. The human
   gates the real thing.
2. **In-app-LLM injection:** Hub+ runs **no** LLM over untrusted content in v1. The
   "last message" line is shown raw and inert — no auto-links, no execution, control
   sequences stripped, length-capped.
3. **GitHub text as vector:** v1 pulls only **local** git (`status`/branch). Remote
   GitHub text (issue/PR bodies) is deferred and, when added, is untrusted display-only.
4. Token handling: read-only from Keychain, transmitted only to Anthropic, never
   persisted by Hub+.

## Build & test

- `xcodegen generate` (folder-based sources → no pbxproj merge conflicts);
  `xcodebuild -scheme HubPlus`. Swift language mode 5.
- Each unit tested against a checked-in fixture (sample `<pid>.json`, `.jsonl`,
  `git status` output, a captured `oauth/usage` JSON). No network in unit tests.
