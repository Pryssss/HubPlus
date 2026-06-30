import Foundation

/// Locations and naming rules of the local Claude Code data directory.
enum ClaudePaths {
    static var home: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
    }
    static var sessionsDir: URL { home.appendingPathComponent("sessions") }
    static var projectsDir: URL { home.appendingPathComponent("projects") }
    static var statsCache: URL { home.appendingPathComponent("stats-cache.json") }

    /// Claude Code names a project's transcript folder by replacing every
    /// non-alphanumeric character of the absolute cwd with "-".
    /// e.g. "/Users/me/projects" -> "-Users-me-projects".
    static func encodedProjectDirName(forCwd cwd: String) -> String {
        let allowed = CharacterSet.alphanumerics
        var out = String.UnicodeScalarView()
        for scalar in cwd.unicodeScalars {
            out.append(allowed.contains(scalar) ? scalar : "-")
        }
        return String(out)
    }

    static func transcriptURL(cwd: String, sessionId: String) -> URL {
        projectsDir
            .appendingPathComponent(encodedProjectDirName(forCwd: cwd))
            .appendingPathComponent("\(sessionId).jsonl")
    }
}
