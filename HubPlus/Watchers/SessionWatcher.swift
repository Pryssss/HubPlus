import Foundation

/// Reads the live-session registry, dropping entries whose process is dead.
enum SessionWatcher {
    /// `root` defaults to the real `~/.claude/sessions` dir so every existing call site is
    /// unchanged; tests pass a fixture directory laid out the same way (mirrors the
    /// `TranscriptReader.snapshot(root:)` / `ProjectUsageProbe.compute(root:)` pattern).
    static func readLiveSessions(root: URL = ClaudePaths.sessionsDir) -> [SessionInfo] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        ) else { return [] }

        let decoder = JSONDecoder()
        var result: [SessionInfo] = []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let info = try? decoder.decode(SessionInfo.self, from: data),
                  info.isAlive
            else { continue }
            result.append(info)
        }
        // Most recently active first.
        return result.sorted { ($0.updatedAt ?? 0) > ($1.updatedAt ?? 0) }
    }
}
