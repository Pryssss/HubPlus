# Hub+ for Windows

A Windows port of Hub+ — a tray app with a floating, always-on-top panel that
monitors your local Claude Code sessions (status, model, context %, branch, last
message) and your subscription usage (5h / 7d). Windows has no notch, so the
"island" is a floating panel toggled from the system-tray icon.

Reads `%USERPROFILE%\.claude\` (sessions registry, transcripts, `stats-cache.json`)
and the OAuth token (from `~/.claude/.credentials.json` or Windows Credential
Manager) to call `GET https://api.anthropic.com/api/oauth/usage`. Read-only; the
token is used for that one request and never stored.

## Build (on a Windows machine)

Prerequisites: **.NET 8 SDK** (https://dotnet.microsoft.com/download) and **git**
on PATH. (Visual Studio 2022 also works — open the folder and Build.)

```powershell
cd windows\HubPlusWin
dotnet build -c Release
```

### Where the .exe is

```
windows\HubPlusWin\bin\Release\net8.0-windows\HubPlus.exe
```

Run it (double-click or `.\bin\Release\net8.0-windows\HubPlus.exe`). A tray icon
(orange sparkle) appears — **left-click** it to toggle the panel, **right-click**
for the menu (Open / Quit). Drag the panel to move it.

To produce a self-contained single file (no .NET install needed on the target):

```powershell
dotnet publish -c Release -r win-x64 --self-contained true ^
  -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true
# -> bin\Release\net8.0-windows\win-x64\publish\HubPlus.exe
```

## Notes / parity with the macOS app

- Same data model and logic; UI is WPF instead of AppKit/SwiftUI.
- **Not yet ported:** the collapsed pill ⇄ expanded animation, edge-snapping,
  vertical pill, notifications. v1 is tray + a single floating panel.
- The token location on Windows is uncertain across Claude Code versions — the
  reader tries `~/.claude/.credentials.json` first, then Credential Manager under
  a few likely target names. If usage shows "re-auth", tell me where your token
  actually lives and I'll point the reader at it.
- Same Anthropic ToS caveat as the macOS build: personal/local use only; do not
  redistribute as a product that uses subscription tokens.
