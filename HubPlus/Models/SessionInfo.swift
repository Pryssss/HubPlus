import Foundation
import Darwin

/// One entry of the live-session registry: `~/.claude/sessions/<pid>.json`.
struct SessionInfo: Codable, Identifiable, Equatable {
    let pid: Int
    let sessionId: String
    let cwd: String
    var name: String?
    var status: String?          // "busy" | "idle" | ...
    var kind: String?            // "interactive" | ...
    var entrypoint: String?
    var version: String?
    var peerProtocol: Int?
    var startedAt: Double?       // ms since epoch
    var updatedAt: Double?       // ms since epoch
    var statusUpdatedAt: Double? // ms since epoch

    var id: String { sessionId }

    var displayName: String {
        if let name, !name.isEmpty { return name }
        return (cwd as NSString).lastPathComponent
    }

    /// True if the recorded pid is still a live process. `kill(pid, 0)` returns 0
    /// when we may signal it; EPERM means it exists but is owned by another user.
    var isAlive: Bool {
        if kill(pid_t(pid), 0) == 0 { return true }
        return errno == EPERM
    }

    var statusKind: SessionStatusKind {
        switch (status ?? "").lowercased() {
        case "idle":                              return .idle
        case "busy", "running", "active":         return .busy
        case "waiting", "waiting-approval",
             "blocked", "needs-input":            return .waiting
        case "error", "failed":                   return .error
        default:                                  return .unknown
        }
    }
}

enum SessionStatusKind: Equatable {
    case idle, busy, waiting, error, unknown
}
