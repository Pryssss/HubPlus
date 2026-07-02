import Foundation

struct ProjectUsage: Equatable, Identifiable { let id: String; let name: String; let tokensToday: Int?; let sessionCount: Int }

enum ProjectUsageProbe {
    private static let tokenKeys = ["input_tokens", "output_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"]

    private static func decodeLine(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func tokenCount(in obj: [String: Any]) -> Int {
        let usage = ((obj["message"] as? [String: Any])?["usage"] as? [String: Any])
            ?? (obj["usage"] as? [String: Any])
        guard let u = usage else { return 0 }
        return tokenKeys.reduce(0) { $0 + ((u[$1] as? NSNumber)?.intValue ?? 0) }
    }

    /// The real absolute cwd recorded in the transcript, so we never have to decode
    /// the lossy encoded dir name (which collapses hyphens in "my-cool-app" → "app").
    static func extractCwd(jsonlLines: [String]) -> String? {
        for line in jsonlLines {
            if let obj = decodeLine(line), let cwd = obj["cwd"] as? String, !cwd.isEmpty { return cwd }
        }
        return nil
    }

    static func sumTokens(jsonlLines: [String], sinceEpoch: Double) -> Int {
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()
        var total = 0
        for line in jsonlLines {
            guard let obj = decodeLine(line),
                  let ts = obj["timestamp"] as? String,
                  let date = iso.date(from: ts) ?? isoPlain.date(from: ts),
                  date.timeIntervalSince1970 >= sinceEpoch else { continue }
            total += tokenCount(in: obj)
        }
        return total
    }

    // MARK: - Bounded streaming scan

    private struct FileScanResult { let tokens: Int; let cwd: String?; let hitDeadline: Bool }

    /// Streams a transcript in `chunkSize`-byte chunks (default 1 MB) instead of loading
    /// the whole file, so peak memory is O(chunk) even for the tens/hundreds-of-MB
    /// transcripts these can grow to. Lines that straddle a chunk boundary are
    /// reassembled via `carry`. The deadline is re-checked after every line (not just
    /// between files) so one huge file can't blow the scan budget.
    private static func scanFile(at url: URL, sinceEpoch: Double, deadline: Date, chunkSize: Int) -> FileScanResult {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return FileScanResult(tokens: 0, cwd: nil, hitDeadline: false)
        }
        defer { try? handle.close() }
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()
        let newline = UInt8(ascii: "\n")
        var tokens = 0
        var cwd: String?
        var carry = Data()

        func consume(_ lineData: Data) {
            guard !lineData.isEmpty, let line = String(data: lineData, encoding: .utf8),
                  let obj = decodeLine(line) else { return }
            if cwd == nil, let c = obj["cwd"] as? String, !c.isEmpty { cwd = c }
            if let ts = obj["timestamp"] as? String,
               let date = iso.date(from: ts) ?? isoPlain.date(from: ts),
               date.timeIntervalSince1970 >= sinceEpoch {
                tokens += tokenCount(in: obj)
            }
        }

        while true {
            if Date() > deadline { return FileScanResult(tokens: tokens, cwd: cwd, hitDeadline: true) }
            let chunk = handle.readData(ofLength: chunkSize)
            if chunk.isEmpty {
                consume(carry)   // final line has no trailing "\n"
                return FileScanResult(tokens: tokens, cwd: cwd, hitDeadline: false)
            }
            carry.append(chunk)
            while let idx = carry.firstIndex(of: newline) {
                consume(carry.subdata(in: carry.startIndex..<idx))
                carry.removeSubrange(carry.startIndex...idx)
                if Date() > deadline { return FileScanResult(tokens: tokens, cwd: cwd, hitDeadline: true) }
            }
        }
    }

    // MARK: - Per-file cache

    /// Keyed by file identity (path, size, mtime) plus the day the scan is for:
    ///  - an unchanged file is never re-parsed on the next 30 s tick (cache hit);
    ///  - an appended/rotated file gets a new key (mtime and/or size differ) and is
    ///    reparsed from scratch;
    ///  - once `since` rolls over to a new day, yesterday's entries are never looked up
    ///    again and are dropped the next time the cache is rebuilt below, so nothing
    ///    from a previous day lingers.
    private struct FileCacheKey: Hashable { let path: String; let size: Int64; let mtime: Double; let dayKey: Double }
    private struct FileCacheValue { let tokens: Int; let cwd: String? }

    /// `compute` stays a pure static func (keeps its signature directly testable, per
    /// the existing fixture-based tests) with the cache held behind a lock in the type
    /// itself, rather than promoting the probe to an instance owned by AppStore — the
    /// smaller diff for the same result.
    private static let cacheLock = NSLock()
    private static var fileCache: [FileCacheKey: FileCacheValue] = [:]

    static func compute(now: Date, budget: TimeInterval = 1.5, root: URL = ClaudePaths.projectsDir,
                         calendar: Calendar = .current, chunkSize: Int = 1_048_576) -> (projects: [ProjectUsage], partial: Bool) {
        let deadline = now.addingTimeInterval(budget)
        let since = calendar.startOfDay(for: now).timeIntervalSince1970
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return ([], false)
        }

        // Snapshot the cache once up front (a cheap dict copy under the lock) so the
        // scan itself needs no further locking; the whole cache is rebuilt from what
        // this run actually touches and swapped back in one shot at the end. That swap
        // is also what bounds the cache's size: entries for files not re-seen this run
        // (deleted, rotated to a new key, or simply not reached before the deadline)
        // are dropped rather than accumulating forever.
        let cacheSnapshot: [FileCacheKey: FileCacheValue] = {
            cacheLock.lock(); defer { cacheLock.unlock() }
            return fileCache
        }()
        var newCache: [FileCacheKey: FileCacheValue] = [:]

        var out: [ProjectUsage] = []
        var partial = false
        for dir in dirs where (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            if Date() > deadline { partial = true; break }
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else { continue }
            let jsonl = files.filter { $0.pathExtension == "jsonl" }
            let touchedToday = jsonl.contains {
                ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate?.timeIntervalSince1970 ?? 0) >= since
            }
            guard touchedToday else { continue }
            var tokens = 0
            var cwd: String?
            for f in jsonl {
                if Date() > deadline { partial = true; break }
                guard let rv = try? f.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                      let mtime = rv.contentModificationDate else { continue }
                let mtimeEpoch = mtime.timeIntervalSince1970
                // A file not written today cannot contain a line timestamped today —
                // skip it before ever opening it.
                guard mtimeEpoch >= since else { continue }

                let key = FileCacheKey(path: f.path, size: Int64(rv.fileSize ?? 0), mtime: mtimeEpoch, dayKey: since)
                if let hit = cacheSnapshot[key] {
                    tokens += hit.tokens
                    if cwd == nil { cwd = hit.cwd }
                    newCache[key] = hit
                    continue
                }

                let result = scanFile(at: f, sinceEpoch: since, deadline: deadline, chunkSize: chunkSize)
                tokens += result.tokens
                if cwd == nil { cwd = result.cwd }
                if result.hitDeadline {
                    // Incomplete read: don't cache it, so the next tick retries in full.
                    partial = true
                    break
                }
                newCache[key] = FileCacheValue(tokens: result.tokens, cwd: result.cwd)
            }
            let name = cwd.map { ($0 as NSString).lastPathComponent }
                ?? SessionRow.projectName(forEncodedDir: dir.lastPathComponent)
            out.append(ProjectUsage(id: dir.lastPathComponent, name: name,
                                    tokensToday: tokens, sessionCount: jsonl.count))
        }

        cacheLock.lock(); fileCache = newCache; cacheLock.unlock()
        return (out.sorted { ($0.tokensToday ?? 0) > ($1.tokensToday ?? 0) }, partial)
    }
}
