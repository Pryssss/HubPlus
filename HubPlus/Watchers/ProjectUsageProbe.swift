import Foundation

/// Real tokens are what a human means by "tokens" (input + output); cache
/// creation/read tokens inflate raw sums ~500× and are tracked separately.
struct TokenCount: Equatable {
    var real: Int = 0
    var cache: Int = 0
    var total: Int { real + cache }

    static func += (l: inout TokenCount, r: TokenCount) {
        l.real += r.real
        l.cache += r.cache
    }
}

struct ProjectUsage: Equatable, Identifiable {
    let id: String
    let name: String
    /// Today's tokens; nil means "scan yielded nothing usable" → the view
    /// falls back to the session count.
    let tokens: TokenCount?
    let sessionCount: Int
}

enum ProjectUsageProbe {
    private static let realKeys = ["input_tokens", "output_tokens"]
    private static let cacheKeys = ["cache_creation_input_tokens", "cache_read_input_tokens"]

    private static func decodeLine(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func tokenCount(in obj: [String: Any]) -> TokenCount {
        let usage = ((obj["message"] as? [String: Any])?["usage"] as? [String: Any])
            ?? (obj["usage"] as? [String: Any])
        guard let u = usage else { return TokenCount() }
        func sum(_ keys: [String]) -> Int { keys.reduce(0) { $0 + ((u[$1] as? NSNumber)?.intValue ?? 0) } }
        return TokenCount(real: sum(realKeys), cache: sum(cacheKeys))
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
            total += tokenCount(in: obj).total
        }
        return total
    }

    // MARK: - Bounded streaming scan

    private struct FileScanResult {
        let boundaryByDay: [Double: TokenCount]  // day-start epoch → tokens, "\n"-terminated lines
        let tailByDay: [Double: TokenCount]      // final unterminated line (scan completed only)
        let bytesConsumed: Int64                 // absolute offset just past the last consumed "\n"
        let cwd: String?
        let hitDeadline: Bool
    }

    /// Streams a transcript from `offset` in `chunkSize`-byte chunks (default 1 MB) instead
    /// of loading the whole file, so peak memory is O(chunk), not O(file). Lines that
    /// straddle a chunk boundary are reassembled via `carry`. The deadline is re-checked
    /// after every consumed line — and between chunks in case a chunk holds no newline —
    /// so one huge file can't blow the scan budget; when it fires, the result carries the
    /// progress made so far so the caller can persist it and resume next tick.
    ///
    /// Tokens are bucketed by the local day of each line's timestamp (lines older than
    /// `windowStart` are dropped) and reported in two buckets: `boundaryByDay` covers
    /// lines fully terminated by "\n" (safe to resume after — the offset is a real line
    /// boundary), while a final unterminated line goes in `tailByDay` and is *not*
    /// included in `bytesConsumed`. That way, if the file grows later, resuming from
    /// `bytesConsumed` re-reads the old tail (possibly now extended into a complete line)
    /// exactly once — no double count, no mid-line split.
    private static func scanFile(at url: URL, startingAt offset: Int64, windowStart: Double,
                                 calendar: Calendar, deadline: Date, chunkSize: Int) -> FileScanResult? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        if offset > 0, (try? handle.seek(toOffset: UInt64(offset))) == nil { return nil }

        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()
        let newline = UInt8(ascii: "\n")
        var boundaryByDay: [Double: TokenCount] = [:]
        var bytesConsumed = offset
        var cwd: String?
        var carry = Data()

        func consume(_ lineData: Data) -> (day: Double, tokens: TokenCount)? {
            guard !lineData.isEmpty, let line = String(data: lineData, encoding: .utf8),
                  let obj = decodeLine(line) else { return nil }
            if cwd == nil, let c = obj["cwd"] as? String, !c.isEmpty { cwd = c }
            guard let ts = obj["timestamp"] as? String,
                  let date = iso.date(from: ts) ?? isoPlain.date(from: ts),
                  date.timeIntervalSince1970 >= windowStart else { return nil }
            let day = calendar.startOfDay(for: date).timeIntervalSince1970
            return (day, tokenCount(in: obj))
        }

        while true {
            let chunk = handle.readData(ofLength: chunkSize)
            if chunk.isEmpty {
                // Final line has no trailing "\n".
                let tail = consume(carry)
                return FileScanResult(boundaryByDay: boundaryByDay,
                                      tailByDay: tail.map { [$0.day: $0.tokens] } ?? [:],
                                      bytesConsumed: bytesConsumed, cwd: cwd, hitDeadline: false)
            }
            carry.append(chunk)
            while let idx = carry.firstIndex(of: newline) {
                let lineBytes = carry.distance(from: carry.startIndex, to: idx)
                if let r = consume(carry.subdata(in: carry.startIndex..<idx)) {
                    boundaryByDay[r.day, default: TokenCount()] += r.tokens
                }
                carry.removeSubrange(carry.startIndex...idx)
                bytesConsumed += Int64(lineBytes + 1)
                // Checked *after* consuming, so every call makes at least one line of
                // progress even under a nearly-spent budget — that guarantees an
                // oversized file converges across ticks instead of livelocking.
                if Date() > deadline {
                    return FileScanResult(boundaryByDay: boundaryByDay, tailByDay: [:],
                                          bytesConsumed: bytesConsumed, cwd: cwd, hitDeadline: true)
                }
            }
            // No newline in this chunk (one very long line): still honor the budget
            // between chunks; the partial carry is simply re-read on the next tick.
            if Date() > deadline {
                return FileScanResult(boundaryByDay: boundaryByDay, tailByDay: [:],
                                      bytesConsumed: bytesConsumed, cwd: cwd, hitDeadline: true)
            }
        }
    }

    // MARK: - Per-file cache

    /// Resumable per-file progress, keyed by (path, windowStart):
    ///  - a `complete` entry whose size+mtime still match is reused without opening the file;
    ///  - an entry interrupted by the deadline (`complete == false`) resumes scanning at
    ///    `bytesConsumed` on the next tick — JSONL transcripts are append-only, so bytes
    ///    before a consumed line boundary never change — which gives a transcript too big
    ///    for one 1.5 s budget a convergence path instead of restarting from byte 0 forever;
    ///  - a grown file resumes from the boundary too (appended lines only); a shrunken or
    ///    same-size-but-rewritten file invalidates the prefix assumption → rescan from 0;
    ///  - `windowStart` scopes buckets to the window they were computed for, so a day
    ///    rollover (window shift) naturally misses and stale entries are pruned on merge.
    private struct FileCacheKey: Hashable { let path: String; let windowStart: Double }
    private struct FileCacheEntry {
        let size: Int64                          // file size when this entry was written
        let mtime: Double                        // mtime when this entry was written
        let bytesConsumed: Int64                 // offset just past the last fully-consumed line
        let boundaryByDay: [Double: TokenCount]  // per-day tokens up to bytesConsumed (resume base)
        let totalByDay: [Double: TokenCount]     // reported value (boundary + unterminated tail)
        let cwd: String?
        let complete: Bool                       // false when the deadline interrupted the scan
    }

    private static func merged(_ a: [Double: TokenCount], _ b: [Double: TokenCount]) -> [Double: TokenCount] {
        var out = a
        for (k, v) in b { out[k, default: TokenCount()] += v }
        return out
    }

    /// `compute` stays a pure static func (keeps its signature directly testable, per
    /// the existing fixture-based tests) with the cache held behind a lock in the type
    /// itself, rather than promoting the probe to an instance owned by AppStore — the
    /// smaller diff for the same result.
    private static let cacheLock = NSLock()
    private static var fileCache: [FileCacheKey: FileCacheEntry] = [:]

    static func compute(now: Date, budget: TimeInterval = 1.5, root: URL = ClaudePaths.projectsDir,
                        calendar: Calendar = .current, chunkSize: Int = 1_048_576, windowDays: Int = 7)
        -> (projects: [ProjectUsage], daily: [(date: Date, tokens: TokenCount)], partial: Bool) {
        let deadline = now.addingTimeInterval(budget)
        let todayStart = calendar.startOfDay(for: now)
        let windowStart = calendar.date(byAdding: .day, value: -(windowDays - 1), to: todayStart)!
            .timeIntervalSince1970
        let todayKey = todayStart.timeIntervalSince1970
        let zeroDaily: [(date: Date, tokens: TokenCount)] = (0..<windowDays).reversed().map { offset in
            (calendar.date(byAdding: .day, value: -offset, to: todayStart)!, TokenCount())
        }
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return ([], zeroDaily, false)
        }

        // Snapshot the cache once up front (a cheap dict copy under the lock) so the scan
        // itself needs no further locking; fresh results are collected in `updates` and
        // merged back under the lock at the end.
        let cacheSnapshot: [FileCacheKey: FileCacheEntry] = {
            cacheLock.lock(); defer { cacheLock.unlock() }
            return fileCache
        }()
        var updates: [FileCacheKey: FileCacheEntry] = [:]
        // dir path → .jsonl paths currently present, for every directory we managed to
        // enumerate this run. Drives pruning: only a directory we actually listed can
        // prove one of its cached files no longer exists.
        var seenByDir: [String: Set<String>] = [:]

        var out: [ProjectUsage] = []
        var allByDay: [Double: TokenCount] = [:]
        var partial = false
        for dir in dirs where (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            if Date() > deadline { partial = true; break }
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else { continue }
            let jsonl = files.filter { $0.pathExtension == "jsonl" }
            seenByDir[dir.path] = Set(jsonl.map(\.path))
            let touchedInWindow = jsonl.contains {
                ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate?.timeIntervalSince1970 ?? 0) >= windowStart
            }
            guard touchedInWindow else { continue }
            var byDay: [Double: TokenCount] = [:]
            var cwd: String?
            for f in jsonl {
                if Date() > deadline { partial = true; break }
                guard let rv = try? f.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                      let mtime = rv.contentModificationDate else { continue }
                let mtimeEpoch = mtime.timeIntervalSince1970
                // A file not written inside the window cannot contain an in-window
                // line — skip it before ever opening it.
                guard mtimeEpoch >= windowStart else { continue }
                let size = Int64(rv.fileSize ?? 0)

                let key = FileCacheKey(path: f.path, windowStart: windowStart)
                var startOffset: Int64 = 0
                var baseBoundary: [Double: TokenCount] = [:]
                var baseCwd: String?
                if let e = cacheSnapshot[key] {
                    if e.complete, e.size == size, e.mtime == mtimeEpoch {
                        byDay = merged(byDay, e.totalByDay)   // unchanged file: no read at all
                        if cwd == nil { cwd = e.cwd }
                        continue
                    }
                    // Append-only growth → resume from the stored line boundary.
                    // Shrink/rotation (or a same-size rewrite of a complete file)
                    // invalidates the scanned prefix → rescan from byte 0.
                    let appendOnly = e.complete ? size > e.size : size >= e.bytesConsumed
                    if appendOnly {
                        startOffset = e.bytesConsumed
                        baseBoundary = e.boundaryByDay
                        baseCwd = e.cwd
                    }
                }

                guard let r = scanFile(at: f, startingAt: startOffset, windowStart: windowStart,
                                       calendar: calendar, deadline: deadline, chunkSize: chunkSize) else {
                    // Transient open failure (file deleted/unreadable between the
                    // directory listing above and this open attempt): fall back to the
                    // last known totals instead of contributing 0 and dipping the
                    // displayed sum for this tick. A *real* deletion is handled below by
                    // the seenByDir prune, not here, so re-adding the cached entry to
                    // `updates` doesn't mask a genuine removal.
                    if let cached = cacheSnapshot[key] {
                        byDay = merged(byDay, cached.totalByDay)
                        if cwd == nil { cwd = cached.cwd }
                        updates[key] = cached
                    }
                    continue
                }
                let boundary = merged(baseBoundary, r.boundaryByDay)
                let total = merged(boundary, r.tailByDay)
                let fileCwd = baseCwd ?? r.cwd
                byDay = merged(byDay, total)
                if cwd == nil { cwd = fileCwd }
                // Store progress even when the deadline interrupted this file: the next
                // tick resumes at bytesConsumed instead of restarting from byte 0 — this
                // is what lets a transcript too big for one budget converge over ticks.
                updates[key] = FileCacheEntry(size: size, mtime: mtimeEpoch, bytesConsumed: r.bytesConsumed,
                                              boundaryByDay: boundary, totalByDay: total,
                                              cwd: fileCwd, complete: !r.hitDeadline)
                if r.hitDeadline { partial = true; break }
            }
            for (day, t) in byDay { allByDay[day, default: TokenCount()] += t }
            // Only projects with tokens *today* make the list (the whole-window buckets
            // above still feed the daily series); zero rows would just be noise.
            let today = byDay[todayKey] ?? TokenCount()
            if today.total > 0 {
                let name = cwd.map { ($0 as NSString).lastPathComponent }
                    ?? SessionRow.projectName(forEncodedDir: dir.lastPathComponent)
                out.append(ProjectUsage(id: dir.lastPathComponent, name: name,
                                        tokens: today, sessionCount: jsonl.count))
            }
        }

        // Merge-forward, not wholesale replace: entries for directories this run never
        // reached (deadline hit first) stay warm — dropping them would force full rescans
        // of unchanged files next tick. An entry is pruned only when its window is stale,
        // or when its directory *was* enumerated and the file is provably gone. That keeps
        // growth bounded to one window's worth of actually-existing transcript files.
        cacheLock.lock()
        fileCache = fileCache.filter { item in
            guard item.key.windowStart == windowStart else { return false }
            guard let present = seenByDir[(item.key.path as NSString).deletingLastPathComponent] else { return true }
            return present.contains(item.key.path)
        }
        for (k, v) in updates { fileCache[k] = v }
        cacheLock.unlock()

        let daily: [(date: Date, tokens: TokenCount)] = (0..<windowDays).reversed().map { offset in
            let date = calendar.date(byAdding: .day, value: -offset, to: todayStart)!
            return (date, allByDay[date.timeIntervalSince1970] ?? TokenCount())
        }
        return (out.sorted { ($0.tokens?.real ?? 0) > ($1.tokens?.real ?? 0) }, daily, partial)
    }

    // MARK: - Test hooks (no production callers)

    /// Wipe the cache so every test starts cold and stays order-independent — the cache
    /// is process-global static state and would otherwise leak between test cases.
    static func _resetCacheForTesting() {
        cacheLock.lock(); fileCache = [:]; cacheLock.unlock()
    }

    /// Cache keys hold paths exactly as directory enumeration yields them, which on macOS
    /// is the realpath form (NSTemporaryDirectory's "/var/…" enumerates as "/private/var/…").
    /// Hook callers pass constructed paths, so canonicalize the same way before comparing.
    /// Note `resolvingSymlinksInPath()` is the wrong tool here: it *strips* "/private".
    private static func canonicalForTesting(_ path: String) -> String {
        if let rp = realpath(path, nil) { defer { free(rp) }; return String(cString: rp) }
        // The file may already be deleted (pruning tests ask about gone files):
        // canonicalize its still-existing parent and re-append the file name.
        let ns = path as NSString
        if let rp = realpath(ns.deletingLastPathComponent, nil) {
            defer { free(rp) }
            return (String(cString: rp) as NSString).appendingPathComponent(ns.lastPathComponent)
        }
        return path
    }

    /// Whether any entry exists for `path`. Retention/pruning is invisible in compute()'s
    /// output (a pruned entry never affects totals — files are enumerated from disk), so
    /// tests need this to observe the cache's lifecycle directly.
    static func _hasCacheEntryForTesting(path: String) -> Bool {
        let canonical = canonicalForTesting(path)
        cacheLock.lock(); defer { cacheLock.unlock() }
        return fileCache.keys.contains { $0.path == canonical }
    }

    /// Seed an interrupted-scan entry, as if a prior tick's deadline fired just past
    /// `bytesConsumed` with `boundaryTokens` counted so far (bucketed to `day`, real
    /// only). Lets tests exercise the resume path deterministically (a real mid-scan
    /// deadline expiry is wall-clock dependent and thus untestable without sleeps).
    static func _seedIncompleteEntryForTesting(path: String, day: Date, calendar: Calendar = .current,
                                               size: Int64, mtime: Double,
                                               bytesConsumed: Int64, boundaryTokens: Int) {
        let dayStart = calendar.startOfDay(for: day)
        // Mirrors compute()'s default windowDays: 7; the hook has no production callers.
        let windowStart = calendar.date(byAdding: .day, value: -6, to: dayStart)!.timeIntervalSince1970
        let key = FileCacheKey(path: canonicalForTesting(path), windowStart: windowStart)
        let buckets = [dayStart.timeIntervalSince1970: TokenCount(real: boundaryTokens, cache: 0)]
        let entry = FileCacheEntry(size: size, mtime: mtime, bytesConsumed: bytesConsumed,
                                   boundaryByDay: buckets, totalByDay: buckets,
                                   cwd: nil, complete: false)
        cacheLock.lock(); fileCache[key] = entry; cacheLock.unlock()
    }
}
