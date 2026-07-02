import Foundation

/// A source of live agent sessions plus their transcript tails. The default
/// implementation (`ClaudeAgentProvider`) reads Claude Code's local files; this
/// protocol is the seam the roadmap needs — additional providers (Codex, etc.) can
/// be plugged into `AppStore` without changing its aggregation logic.
///
/// The signatures mirror exactly what `AppStore.refresh()` calls today: it lists
/// live sessions, then for each one asks for a transcript snapshot by (cwd, sessionId).
/// GitProbe and stats stay direct calls in AppStore — they are host-machine concerns,
/// not per-provider concerns.
///
/// `Sendable`: AppStore snapshots its providers on the main actor and hands them to a
/// background GCD queue for the off-main refresh scan, so the type must cross that
/// boundary safely. (Added beyond the brief's sketch to keep the concurrency-checked
/// capture warning-free; the built-in providers are stateless and trivially satisfy it.)
protocol AgentProvider: Sendable {
    /// Stable identifier stamped onto every `SessionRow` this provider produces
    /// (the built-in provider uses `"claude"`), so views/notifications can tell
    /// sources apart later.
    var id: String { get }

    /// The provider's currently-live sessions (newest-active first for the built-in
    /// provider — AppStore preserves whatever order the provider returns).
    func liveSessions() -> [SessionInfo]

    /// The tail-of-transcript snapshot for one session, or nil when unavailable.
    func transcriptSnapshot(cwd: String, sessionId: String) -> TranscriptSnapshot?
}
