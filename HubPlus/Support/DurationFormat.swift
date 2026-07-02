import Foundation

/// Compact "how long has it been" labels for status capsules: "12m", "3h", "2d".
/// Under a minute (or missing/future input) → nil, so fresh statuses stay clean.
enum DurationFormat {
    static func compactSince(_ msEpoch: Double?, now: Date = Date()) -> String? {
        guard let ms = msEpoch else { return nil }
        let secs = now.timeIntervalSince(Date(timeIntervalSince1970: ms / 1000.0))
        guard secs >= 60 else { return nil }
        if secs < 3600 { return "\(Int(secs / 60))m" }
        if secs < 86400 { return "\(Int(secs / 3600))h" }
        return "\(Int(secs / 86400))d"
    }
}
