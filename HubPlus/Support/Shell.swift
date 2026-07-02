import Foundation

/// Minimal synchronous process runner. Used for short, fast commands (git).
enum Shell {
    /// Holds the reader thread's outcome. Written only on the detached reader
    /// thread, read only after the semaphore below has signaled (or the wait
    /// has timed out and the caller no longer looks at it) -- the semaphore
    /// is the synchronization edge, so no lock is needed for the happy path.
    private final class ReadOutcome {
        var data = Data()
        var status: Int32 = -1
    }

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

        // Watchdog: if the process outlives the deadline, kill it. This is
        // best-effort cleanup, not the thing that bounds this call (see
        // below) -- a cwd on a dead network mount can leave a child stuck in
        // uninterruptible kernel I/O that ignores signals until its I/O
        // returns, possibly never, and a helper process (e.g. one `git`
        // spawns, or a backgrounded job) can inherit the pipe's write end
        // and keep it open past the direct child's death regardless.
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

        // Do the actual draining + waiting on a detached thread, and bound
        // *this* (the caller's) thread with its own deadline instead of
        // trusting the child to ever die. Signals only reach the direct
        // child: a grandchild that inherited the pipe's write end (or a
        // child parked in uninterruptible I/O) can keep readDataToEndOfFile()
        // blocked forever even after SIGKILL, so the watchdog above cannot be
        // what unblocks us. The reader thread is deliberately abandoned when
        // the deadline below fires -- it may stay parked in kernel space for
        // the life of the process. That's an acceptable trade (one leaked
        // thread) for guaranteeing this call, and the serial queue it runs
        // on, never freezes permanently again.
        let outcome = ReadOutcome()
        let readerDone = DispatchSemaphore(value: 0)
        let reader = Thread {
            outcome.data = out.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            outcome.status = proc.terminationStatus
            readerDone.signal()
        }
        // .userInteractive so the reader is never a *lower* QoS than whatever thread
        // is about to block waiting on it below -- Shell.run can be called from any
        // QoS context (a background queue today, potentially a user-facing one later),
        // and a higher-QoS caller blocked on a lower-QoS worker is a real priority
        // inversion the system won't automatically correct for a plain Thread.
        reader.qualityOfService = .userInteractive
        reader.start()

        // Deadline sits just past the watchdog's SIGTERM->SIGKILL escalation
        // (timeout + 0.5s) so the common "child dies from the watchdog" path
        // still returns real output; a bit of slack beyond that covers the
        // OS actually delivering EOF after the kill.
        guard readerDone.wait(timeout: .now() + timeout + 1) == .success else { return nil }
        watchdog.cancel()

        guard outcome.status == 0 else { return nil }
        return String(data: outcome.data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
