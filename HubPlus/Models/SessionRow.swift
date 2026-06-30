import Foundation

/// A merged view-model for one session: registry entry + transcript snapshot + git.
struct SessionRow: Identifiable, Equatable {
    let info: SessionInfo
    var transcript: TranscriptSnapshot?
    var git: GitInfo?

    var id: String { info.sessionId }

    /// Display name: prefer the git repo name, else the cwd's folder name — never
    /// Claude's derived session name (e.g. "projects-7b").
    var title: String {
        if let repo = git?.repoName, !repo.isEmpty { return repo }
        let cwd = transcript?.cwd ?? info.cwd
        return (cwd as NSString).lastPathComponent
    }
}

/// What we extract from the tail of a session transcript.
struct TranscriptSnapshot: Equatable {
    var lastText: String?
    var model: String?
    var contextTokens: Int?
    var lastActivity: Date?
    /// The agent's most-recent effective working dir (often a specific project,
    /// even when the session was launched from a parent folder).
    var cwd: String?

    var contextWindow: Int {
        // A session can't exceed a 200k context window without being on the 1M tier,
        // so infer 1M once the live token count passes 200k (the model id alone does
        // not distinguish the [1m] variant).
        if let contextTokens, contextTokens > 200_000 { return 1_000_000 }
        return ModelCatalog.contextWindow(for: model)
    }

    var contextPercent: Double? {
        guard let contextTokens, contextWindow > 0 else { return nil }
        return min(1.0, Double(contextTokens) / Double(contextWindow))
    }

    var modelShortName: String { ModelCatalog.shortName(for: model) }
}

struct GitInfo: Equatable {
    var branch: String?
    var repoName: String?
    var isDirty: Bool = false
    var ahead: Int = 0
    var behind: Int = 0
}

/// Maps Claude model identifiers to display names and context-window sizes.
enum ModelCatalog {
    static func contextWindow(for model: String?) -> Int {
        guard let m = model?.lowercased() else { return 200_000 }
        if m.contains("[1m]") || m.contains("-1m") { return 1_000_000 }
        return 200_000
    }

    static func shortName(for model: String?) -> String {
        guard let m = model?.lowercased() else { return "—" }
        if m.contains("opus-4-8")   { return "Opus 4.8" }
        if m.contains("opus")       { return "Opus" }
        if m.contains("sonnet-4-6") { return "Sonnet 4.6" }
        if m.contains("sonnet")     { return "Sonnet" }
        if m.contains("haiku")      { return "Haiku" }
        if m.contains("fable")      { return "Fable 5" }
        return model ?? "—"
    }
}
