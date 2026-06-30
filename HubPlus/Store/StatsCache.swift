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

    /// Pure: sums `dailyModelTokens` per day for `days` days ending at `today`.
    /// Missing days → 0.
    static func dailyTokens(days: Int, json: Data, today: Date, calendar: Calendar = .current) -> [(date: Date, tokens: Int)] {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.calendar = calendar; f.timeZone = calendar.timeZone
        var perDay: [String: Int] = [:]
        if let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
           let daily = root["dailyModelTokens"] as? [String: Any] {
            for (day, models) in daily {
                if let m = models as? [String: Any] {
                    perDay[day] = m.values.reduce(0) { $0 + ((($1 as? NSNumber)?.intValue) ?? 0) }
                }
            }
        }
        return (0..<days).reversed().map { offset in
            let date = calendar.date(byAdding: .day, value: -offset, to: today)!
            return (date, perDay[f.string(from: date)] ?? 0)
        }
    }

    /// Convenience: reads the real stats-cache file.
    static func dailyTokens(days: Int = 7) -> [(date: Date, tokens: Int)] {
        guard let data = try? Data(contentsOf: ClaudePaths.statsCache) else {
            return (0..<days).reversed().map { (Calendar.current.date(byAdding: .day, value: -$0, to: Date())!, 0) }
        }
        return dailyTokens(days: days, json: data, today: Date())
    }
}
