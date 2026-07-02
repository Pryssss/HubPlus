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
}
