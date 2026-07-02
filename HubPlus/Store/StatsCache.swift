import Foundation

/// Derives "tokens today" from `~/.claude/stats-cache.json`.
/// Shape is best-effort: `dailyModelTokens[<yyyy-MM-dd>]` is either a number or a
/// `{ model: tokens }` map. Returns nil if absent/unrecognized.
enum StatsCache {
    /// `statsCache` defaults to the real `~/.claude/stats-cache.json` file so every call
    /// site is unchanged; tests point it at a fixture file. (Named for the file it reads
    /// rather than "root", since this static reads a single file, not a directory tree —
    /// the "or equivalent" injectable requested for testability.)
    static func tokensToday(statsCache: URL = ClaudePaths.statsCache) -> Int? {
        guard let data = try? Data(contentsOf: statsCache),
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
        // The cache keys are always Gregorian ASCII ("2026-06-30"); format the lookup
        // key the same way regardless of the user's system calendar/locale (a Buddhist
        // or Arabic-digit locale would otherwise never match and the chart reads 0).
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = calendar.timeZone
        f.dateFormat = "yyyy-MM-dd"
        var perDay: [String: Int] = [:]
        if let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
           let daily = root["dailyModelTokens"] as? [String: Any] {
            for (day, models) in daily {
                if let m = models as? [String: Any] {
                    perDay[day] = m.values.reduce(0) { $0 + ((($1 as? NSNumber)?.intValue) ?? 0) }
                } else if let n = (models as? NSNumber)?.intValue {
                    // scalar shape: "YYYY-MM-DD": 12345  (Int or Double)
                    perDay[day] = n
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
