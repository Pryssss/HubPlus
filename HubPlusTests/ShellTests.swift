import XCTest
@testable import HubPlus

final class ShellTests: XCTestCase {
    func testEchoReturnsTrimmedStdout() {
        XCTAssertEqual(Shell.run("/bin/echo", ["hi"]), "hi")
    }

    func testNonZeroExitReturnsNil() {
        XCTAssertNil(Shell.run("/usr/bin/false", []))
    }

    /// A child writing >64KB to stderr must not deadlock the parent. Before
    /// the fix, `proc.standardError = Pipe()` had no reader: the pipe filled,
    /// `tr` blocked mid-write, and `readDataToEndOfFile()` never returned.
    func testStderrFloodDoesNotDeadlock() {
        let result = Shell.run(
            "/bin/sh",
            ["-c", "head -c 200000 /dev/zero | tr \"\\0\" e 1>&2; echo ok"]
        )
        XCTAssertEqual(result, "ok")
    }

    /// A hung child (e.g. cwd on a dead network mount) must be killed at the
    /// deadline rather than blocking the caller forever. Elapsed-time bound
    /// is generous (well under the 30s the child would otherwise sleep for)
    /// but deterministic -- no synchronization sleeps are involved.
    func testTimeoutKillsHungProcessAndReturnsNil() {
        let start = Date()
        let result = Shell.run("/bin/sleep", ["30"], timeout: 0.5)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertNil(result)
        XCTAssertLessThan(elapsed, 3.0)
    }

    /// Regression test for the residual freeze path: the direct child can exit
    /// cleanly while a *grandchild* it backgrounded still holds the pipe's write
    /// end open (verified separately: the shell here exits in ~0.07s, but
    /// `readDataToEndOfFile()` on that pipe doesn't return for ~3s -- until the
    /// orphaned `sleep 3` itself exits and closes its inherited fd). Signals sent
    /// to the direct child (SIGTERM/SIGKILL from the watchdog) can never reach or
    /// free that grandchild, so nothing about the watchdog can bound this call --
    /// only a parent-side deadline that gives up on the reader thread can. This
    /// is exactly the "helper process in the same group holds the pipe open past
    /// the kill" case called out in the review; asserting a sub-3s return (not
    /// the ~3s the orphaned grandchild actually takes to exit) is what proves
    /// `Shell.run` didn't wait for it.
    func testOrphanedGrandchildHoldingPipeOpenCannotBlockParentDeadline() {
        let start = Date()
        let result = Shell.run("/bin/sh", ["-c", "sleep 3 &"], timeout: 0.5)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertNil(result)
        XCTAssertLessThan(elapsed, 2.5)
    }
}
