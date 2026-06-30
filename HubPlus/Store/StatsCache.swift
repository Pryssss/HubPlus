import Foundation

/// Derives "tokens today" from `~/.claude/stats-cache.json`.
/// Shape is best-effort: `dailyModelTokens[<yyyy-MM-dd>]` is either a number or a
/// `{ model: tokens }` map. Returns nil if absent/unrecognized.
enum StatsCache {
    static func tokensToday() -> Int? {
        guard let data = try? Data(contentsOf: ClaudePaths.statsCache),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let daily = obj["dailyModelTokens"] as? [String: Any]
        else { return nil }

        guard let todays = daily[todayKey()] else { return nil }
        if let n = todays as? Int { return n }
        if let d = todays as? Double { return Int(d) }
        if let perModel = todays as? [String: Any] {
            return perModel.values.reduce(0) { acc, v in
                if let i = v as? Int { return acc + i }
                if let d = v as? Double { return acc + Int(d) }
                return acc
            }
        }
        return nil
    }

    private static func todayKey() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }
}
