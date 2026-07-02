import Foundation

/// The built-in provider: reads live sessions and transcript tails from the local
/// Claude Code data directory. It is a thin delegation shim over the existing
/// `SessionWatcher`/`TranscriptReader` statics with no logic of its own, so routing
/// AppStore through it leaves runtime behavior identical to calling those statics
/// directly.
struct ClaudeAgentProvider: AgentProvider {
    let id = "claude"

    func liveSessions() -> [SessionInfo] {
        SessionWatcher.readLiveSessions()
    }

    func transcriptSnapshot(cwd: String, sessionId: String) -> TranscriptSnapshot? {
        TranscriptReader.snapshot(cwd: cwd, sessionId: sessionId)
    }
}
