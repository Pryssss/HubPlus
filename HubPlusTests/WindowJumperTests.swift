import XCTest
@testable import HubPlus

final class WindowJumperTests: XCTestCase {
    func testParseTTY() {
        XCTAssertEqual(WindowJumper.parseTTY("ttys003\n"), "/dev/ttys003")
        XCTAssertEqual(WindowJumper.parseTTY("  ttys012 "), "/dev/ttys012")
        XCTAssertNil(WindowJumper.parseTTY("??\n"))
        XCTAssertNil(WindowJumper.parseTTY(""))
        // Injection guard: non-alphanumeric/slash characters must be rejected.
        XCTAssertNil(WindowJumper.parseTTY("ttys003\"; tell application"))
        XCTAssertNil(WindowJumper.parseTTY("/dev/ttys003; rm -rf /"))
        XCTAssertNil(WindowJumper.parseTTY("ttys003\n\"; evil"))
    }
    func testTerminalKind() {
        if case .terminalApp? = WindowJumper.terminalKind(comm: "Terminal") {} else { XCTFail() }
        if case .iterm? = WindowJumper.terminalKind(comm: "iTerm2") {} else { XCTFail() }
        XCTAssertNil(WindowJumper.terminalKind(comm: "claude"))
    }
}
