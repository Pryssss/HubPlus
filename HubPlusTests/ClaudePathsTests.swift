import XCTest
@testable import HubPlus

final class ClaudePathsTests: XCTestCase {
    func testEncodedProjectDirNameReplacesSlashesAndKeepsInnerHyphens() {
        XCTAssertEqual(ClaudePaths.encodedProjectDirName(forCwd: "/Users/me/my-cool-app"),
                        "-Users-me-my-cool-app")
    }

    func testEncodedProjectDirNameCollapsesSpacesAndPunctuationIndependently() {
        // Each non-alphanumeric char (space, parens) is replaced independently, so two
        // adjacent separators (a space followed by "(") become two hyphens, not one.
        XCTAssertEqual(ClaudePaths.encodedProjectDirName(forCwd: "/Users/me/My Project (v2)"),
                        "-Users-me-My-Project--v2-")
    }

    func testEncodedProjectDirNameKeepsUnicodeLettersButEncodesSeparators() {
        // CharacterSet.alphanumerics includes Unicode letters (accented Latin, CJK, etc.),
        // so they pass through unchanged; only the path separators become "-".
        XCTAssertEqual(ClaudePaths.encodedProjectDirName(forCwd: "/Users/café/日本語-app"),
                        "-Users-café-日本語-app")
    }
}
