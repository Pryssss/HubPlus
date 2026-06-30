# Using Hub+

Hub+ sits at the top of your screen (or any edge you drag it to) and has two
states — a small **pill** and a full **panel** — plus a Dock icon (macOS) or
tray icon (Windows). No setup or onboarding: launch it and it shows whatever
Claude Code sessions you have running.

---

## 1 · The collapsed pill — at a glance

![Collapsed pill](screenshots/collapsed.png)

Always visible, tiny. Without opening anything it tells you:

- **✳** — Hub+.
- **A dot per running agent**, colored by status — 🟢 idle · 🟡 busy · 🔴 waiting.
- **Your tightest usage window** — e.g. `5h 82%` (82% of your 5-hour limit left),
  turning orange then red as it runs low.

Hover it to peek, click it to pin it open.

---

## 2 · The expanded panel — the full view

![Expanded panel](screenshots/expanded.png)

- **Header** — how many agents are running and tokens used today. **✕** collapses it.
- **Claude usage** — your **5h** and **7d** limit windows: % left and when each resets.
- **One card per session**:
  - the **project** (git repo) name and `⎇ branch`,
  - a **status** capsule — `IDLE` / `BUSY` / `WAITING`,
  - the **model**,
  - **context %** — how full that model's context window is (reddens near 100%),
  - how long ago it last did something, and its **last message**.

---

## 3 · Dock it to any edge

![Vertical pill on a side edge](screenshots/vertical.png)

**Drag the pill** anywhere — on release it snaps to the nearest screen edge and
remembers the spot. On the **left or right** edge it turns **vertical**, and the
panel expands inward (left → grows right, right → grows left; top → down).

---

## Opening & closing

| Action | What it does |
|---|---|
| **Hover** the pill | Expands to the panel; collapses when you move away |
| **Click** the pill | Pins the panel open |
| **✕** / click elsewhere | Collapses |
| **⌃⌥H** (Ctrl+Opt+H) | Toggle from anywhere — even if the menu-bar icon is hidden behind the notch |
| **Dock / tray icon** | Click to open |

## Statuses

- 🟢 **IDLE** — the agent finished and is waiting for your input.
- 🟡 **BUSY** — actively working.
- 🔴 **WAITING** — it needs you (a question, or a tool approval).

## Notifications

Hub+ pings you when an agent **finishes and is ready**, when one **needs you**,
and when a **usage limit is reached** or **becomes available again**.

## Usage limits & the token

The 5h/7d bars come from your **own** Claude Code login, read-only. On first
launch, click **Always Allow** on the Keychain prompt (macOS). If you ever see
**"re-auth in terminal"**, run `claude` once to refresh the login.
