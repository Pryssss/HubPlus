import Foundation

/// A source of subscription-usage state. Kept separate from `AgentProvider` because
/// usage can come from somewhere other than the session source: today it's the OAuth
/// endpoint, but the roadmap has a fully-local estimation provider that needs no token
/// or network at all. The signature mirrors what `AppStore.refreshUsage()` calls today.
///
/// `Sendable`: AppStore awaits `fetch()` from a detached, off-main task, so the provider
/// value crosses that boundary. (Added beyond the brief's sketch; the built-in provider
/// is stateless.)
protocol UsageProvider: Sendable {
    func fetch() async -> UsageResult
}

/// The built-in usage provider: reads the Claude Code OAuth token from the Keychain and
/// hands it to `UsageClient`. Token acquisition lives here — not in `UsageClient` — so a
/// future local-estimation provider needs no token.
///
/// AppStore calls `fetch()` from a detached, off-main task, so the Keychain read (which
/// may prompt) stays off the main thread exactly as it did when it lived inside
/// `UsageClient.fetch()`. This type is nonisolated, so awaiting it from that detached
/// task does not hop back to the main actor.
struct ClaudeOAuthUsageProvider: UsageProvider {
    func fetch() async -> UsageResult {
        guard let token = KeychainReader.claudeCodeToken() else { return .authError }
        return await UsageClient.fetch(token: token)
    }
}
