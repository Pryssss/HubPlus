import AppKit

enum TerminalKind: Equatable { case terminalApp, iterm, other(String) }

enum WindowJumper {
    static func parseTTY(_ psOutput: String) -> String? {
        let t = psOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t != "??", t != "?" else { return nil }
        guard t.range(of: "^[a-zA-Z0-9/]+$", options: .regularExpression) != nil else { return nil }
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
            case .terminalApp: runScript(terminalScript(tty: tty)) { activate(pid: termPID) }
            case .iterm:       runScript(itermScript(tty: tty)) { activate(pid: termPID) }
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
            if let kind = terminalKind(comm: comm) { return (cur, kind) }
            if ppid <= 1 { return nil }
            cur = ppid
        }
        return nil
    }

    private static func activate(pid: Int32) {
        NSRunningApplication(processIdentifier: pid)?.activate(options: [.activateAllWindows])
    }
    /// Runs `src` on the main queue. If AppleScript returns an error (including
    /// Automation permission denied on first use), `fallback` is invoked so the
    /// caller can activate the app directly instead of silently doing nothing.
    private static func runScript(_ src: String, fallback: @escaping () -> Void = {}) {
        DispatchQueue.main.async {
            var err: NSDictionary?
            NSAppleScript(source: src)?.executeAndReturnError(&err)
            if err != nil { fallback() }
        }
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
