import Foundation

struct ProjectUsage: Equatable { let name: String; let tokensToday: Int?; let sessionCount: Int }

enum ProjectUsageProbe {
    static func sumTokens(jsonlLines: [String], sinceEpoch: Double) -> Int {
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()
        var total = 0
        for line in jsonlLines {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let ts = obj["timestamp"] as? String,
                  let date = iso.date(from: ts) ?? isoPlain.date(from: ts),
                  date.timeIntervalSince1970 >= sinceEpoch else { continue }
            let usage = ((obj["message"] as? [String: Any])?["usage"] as? [String: Any])
                ?? (obj["usage"] as? [String: Any])
            guard let u = usage else { continue }
            for k in ["input_tokens", "output_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"] {
                total += (u[k] as? NSNumber)?.intValue ?? 0
            }
        }
        return total
    }

    static func compute(now: Date, budget: TimeInterval = 1.5, root: URL = ClaudePaths.projectsDir) -> (projects: [ProjectUsage], partial: Bool) {
        let deadline = now.addingTimeInterval(budget)
        let since = Calendar.current.startOfDay(for: now).timeIntervalSince1970
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return ([], false)
        }
        var out: [ProjectUsage] = []
        var partial = false
        for dir in dirs where (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            if Date() > deadline { partial = true; break }
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            let jsonl = files.filter { $0.pathExtension == "jsonl" }
            let touchedToday = jsonl.contains {
                ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate?.timeIntervalSince1970 ?? 0) >= since
            }
            guard touchedToday else { continue }
            var tokens = 0
            for f in jsonl {
                if Date() > deadline { partial = true; break }
                if let text = try? String(contentsOf: f, encoding: .utf8) {
                    tokens += sumTokens(jsonlLines: text.split(separator: "\n").map(String.init), sinceEpoch: since)
                }
            }
            out.append(ProjectUsage(name: SessionRow.projectName(forEncodedDir: dir.lastPathComponent),
                                    tokensToday: tokens, sessionCount: jsonl.count))
        }
        return (out.sorted { ($0.tokensToday ?? 0) > ($1.tokensToday ?? 0) }, partial)
    }
}
