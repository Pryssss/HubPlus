import Foundation

/// Minimal synchronous process runner. Used for short, fast commands (git).
enum Shell {
    /// Run an executable and return trimmed stdout, or nil on launch failure,
    /// non-zero exit, or timeout.
    @discardableResult
    static func run(_ launchPath: String, _ args: [String], timeout: TimeInterval = 10) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: launchPath)
        proc.arguments = args
        let out = Pipe()
        proc.standardOutput = out
        // Callers never read stderr; discard it instead of piping it, so a
        // chatty child (e.g. git emitting thousands of warning lines) can't
        // fill an unread pipe and block forever.
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return nil }

        // Watchdog: if the process outlives the deadline, kill it. Without
        // this, a cwd on a dead network mount hangs `git status` (and this
        // call) forever, freezing the serial queue AppStore runs probes on.
        let watchdog = DispatchWorkItem {
            guard proc.isRunning else { return }
            let pid = proc.processIdentifier
            proc.terminate()
            // terminate() sends SIGTERM, which a hung child in uninterruptible
            // I/O can ignore; escalate to an unblockable SIGKILL shortly after.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                if proc.isRunning { kill(pid, SIGKILL) }
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

        // Drain stdout before/while waiting, never after waitUntilExit(): a
        // full pipe blocks the child mid-write, and waiting first would then
        // block us forever on a child that can't make progress.
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        watchdog.cancel()

        guard proc.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
