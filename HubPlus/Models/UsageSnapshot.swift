import Foundation

/// One subscription rate-limit window (e.g. 5h or 7d).
struct UsageWindow: Equatable {
    /// Percent used, 0...100 (the API field `utilization`). Confirmed against the live
    /// /api/oauth/usage response, where `utilization: 12.0` == 12% == `limits[].percent`.
    var utilization: Double
    var resetsAt: Date?

    var fractionLeft: Double { max(0, min(1, (100.0 - utilization) / 100.0)) }
    var percentLeft: Int { Int(max(0, min(100, (100.0 - utilization).rounded()))) }
}

/// Result of a usage fetch, as rendered by the HUD.
struct UsageSnapshot: Equatable {
    enum State: Equatable {
        case ok            // at least one window present
        case authError     // missing token / 401 / 403 — needs re-auth
        case unavailable   // transient/network/parse failure and no prior good data
    }
    var fiveHour: UsageWindow?
    var sevenDay: UsageWindow?
    var state: State = .ok
}
