import Foundation

/// Reads branch / dirty / ahead-behind for a working directory. Read-only.
enum GitProbe {
    private static let gitPath = "/usr/bin/git"

    static func probe(cwd: String) -> GitInfo? {
        // No fileExists pre-check: it also blocks on a dead network mount.
        // Let `git -C` fail fast instead -- Shell.run returns nil on
        // non-zero exit (or timeout), which already yields probe -> nil.
        guard Shell.run(gitPath, ["-C", cwd, "rev-parse", "--is-inside-work-tree"]) == "true"
        else { return nil }

        let branch = Shell.run(gitPath, ["-C", cwd, "rev-parse", "--abbrev-ref", "HEAD"])
        let status = Shell.run(gitPath, ["-C", cwd, "status", "--porcelain"]) ?? ""
        let toplevel = Shell.run(gitPath, ["-C", cwd, "rev-parse", "--show-toplevel"])
        let repoName = toplevel.map { ($0 as NSString).lastPathComponent }

        var info = GitInfo(branch: branch, repoName: repoName, isDirty: !status.isEmpty)
        if let counts = Shell.run(gitPath,
            ["-C", cwd, "rev-list", "--left-right", "--count", "@{upstream}...HEAD"]) {
            let parts = counts.split { $0 == " " || $0 == "\t" }
            if parts.count == 2 {
                info.behind = Int(parts[0]) ?? 0
                info.ahead = Int(parts[1]) ?? 0
            }
        }
        return info
    }
}
