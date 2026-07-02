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

    private struct FileScanResult {
        let boundaryTokens: Int   // tokens from fully "\n"-terminated lines consumed this pass
        let tailTokens: Int       // tokens from a final unterminated line (only when the scan completed)
        let bytesConsumed: Int64  // absolute offset just past the last consumed "\n"
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
    /// Tokens are reported in two buckets: `boundaryTokens` covers lines fully terminated
    /// by "\n" (safe to resume after — the offset is a real line boundary), while a final
    /// unterminated line goes in `tailTokens` and is *not* included in `bytesConsumed`.
    /// That way, if the file grows later, resuming from `bytesConsumed` re-reads the old
    /// tail (possibly now extended into a complete line) exactly once — no double count,
    /// no mid-line split.
    private static func scanFile(at url: URL, startingAt offset: Int64, sinceEpoch: Double,
                                 deadline: Date, chunkSize: Int) -> FileScanResult? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        if offset > 0, (try? handle.seek(toOffset: UInt64(offset))) == nil { return nil }

        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()
        let newline = UInt8(ascii: "\n")
        var boundaryTokens = 0
        var bytesConsumed = offset
        var cwd: String?
        var carry = Data()

        func consume(_ lineData: Data) -> Int {
            guard !lineData.isEmpty, let line = String(data: lineData, encoding: .utf8),
                  let obj = decodeLine(line) else { return 0 }
            if cwd == nil, let c = obj["cwd"] as? String, !c.isEmpty { cwd = c }
            guard let ts = obj["timestamp"] as? String,
                  let date = iso.date(from: ts) ?? isoPlain.date(from: ts),
                  date.timeIntervalSince1970 >= sinceEpoch else { return 0 }
            return tokenCount(in: obj)
        }

        while true {
            let chunk = handle.readData(ofLength: chunkSize)
            if chunk.isEmpty {
                let tail = consume(carry)   // final line has no trailing "\n"
                return FileScanResult(boundaryTokens: boundaryTokens, tailTokens: tail,
                                      bytesConsumed: bytesConsumed, cwd: cwd, hitDeadline: false)
            }
            carry.append(chunk)
            while let idx = carry.firstIndex(of: newline) {
                let lineBytes = carry.distance(from: carry.startIndex, to: idx)
                boundaryTokens += consume(carry.subdata(in: carry.startIndex..<idx))
                carry.removeSubrange(carry.startIndex...idx)
                bytesConsumed += Int64(lineBytes + 1)
                // Checked *after* consuming, so every call makes at least one line of
                // progress even under a nearly-spent budget — that guarantees an
                // oversized file converges across ticks instead of livelocking.
                if Date() > deadline {
                    return FileScanResult(boundaryTokens: boundaryTokens, tailTokens: 0,
                                          bytesConsumed: bytesConsumed, cwd: cwd, hitDeadline: true)
                }
            }
            // No newline in this chunk (one very long line): still honor the budget
            // between chunks; the partial carry is simply re-read on the next tick.
            if Date() > deadline {
                return FileScanResult(boundaryTokens: boundaryTokens, tailTokens: 0,
                                      bytesConsumed: bytesConsumed, cwd: cwd, hitDeadline: true)
            }
        }
    }

    // MARK: - Per-file cache

    /// Resumable per-file progress, keyed by (path, day):
    ///  - a `complete` entry whose size+mtime still match is reused without opening the file;
    ///  - an entry interrupted by the deadline (`complete == false`) resumes scanning at
    ///    `bytesConsumed` on the next tick — JSONL transcripts are append-only, so bytes
    ///    before a consumed line boundary never change — which gives a transcript too big
    ///    for one 1.5 s budget a convergence path instead of restarting from byte 0 forever;
    ///  - a grown file resumes from the boundary too (appended lines only); a shrunken or
    ///    same-size-but-rewritten file invalidates the prefix assumption → rescan from 0;
    ///  - `dayKey` scopes totals to the day they were computed for, so a day rollover
    ///    naturally misses and the stale day's entries are pruned on the next merge.
    private struct FileCacheKey: Hashable { let path: String; let dayKey: Double }
    private struct FileCacheEntry {
        let size: Int64          // file size when this entry was written
        let mtime: Double        // mtime when this entry was written
        let bytesConsumed: Int64 // offset just past the last fully-consumed line
        let boundaryTokens: Int  // tokens from lines up to bytesConsumed (resume base)
        let totalTokens: Int     // tokens reported for the file (boundary + unterminated tail)
        let cwd: String?
        let complete: Bool       // false when the deadline interrupted the scan
    }

    /// `compute` stays a pure static func (keeps its signature directly testable, per
    /// the existing fixture-based tests) with the cache held behind a lock in the type
    /// itself, rather than promoting the probe to an instance owned by AppStore — the
    /// smaller diff for the same result.
    private static let cacheLock = NSLock()
    private static var fileCache: [FileCacheKey: FileCacheEntry] = [:]

    static func compute(now: Date, budget: TimeInterval = 1.5, root: URL = ClaudePaths.projectsDir,
                        calendar: Calendar = .current, chunkSize: Int = 1_048_576) -> (projects: [ProjectUsage], partial: Bool) {
        let deadline = now.addingTimeInterval(budget)
        let since = calendar.startOfDay(for: now).timeIntervalSince1970
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return ([], false)
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
        var partial = false
        for dir in dirs where (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            if Date() > deadline { partial = true; break }
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else { continue }
            let jsonl = files.filter { $0.pathExtension == "jsonl" }
            seenByDir[dir.path] = Set(jsonl.map(\.path))
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
                let size = Int64(rv.fileSize ?? 0)

                let key = FileCacheKey(path: f.path, dayKey: since)
                var startOffset: Int64 = 0
                var baseTokens = 0
                var baseCwd: String?
                if let e = cacheSnapshot[key] {
                    if e.complete, e.size == size, e.mtime == mtimeEpoch {
                        tokens += e.totalTokens   // unchanged file: no read at all
                        if cwd == nil { cwd = e.cwd }
                        continue
                    }
                    // Append-only growth → resume from the stored line boundary.
                    // Shrink/rotation (or a same-size rewrite of a complete file)
                    // invalidates the scanned prefix → rescan from byte 0.
                    let appendOnly = e.complete ? size > e.size : size >= e.bytesConsumed
                    if appendOnly {
                        startOffset = e.bytesConsumed
                        baseTokens = e.boundaryTokens
                        baseCwd = e.cwd
                    }
                }

                guard let r = scanFile(at: f, startingAt: startOffset, sinceEpoch: since,
                                       deadline: deadline, chunkSize: chunkSize) else { continue }
                let boundary = baseTokens + r.boundaryTokens
                let total = boundary + r.tailTokens
                let fileCwd = baseCwd ?? r.cwd
                tokens += total
                if cwd == nil { cwd = fileCwd }
                // Store progress even when the deadline interrupted this file: the next
                // tick resumes at bytesConsumed instead of restarting from byte 0 — this
                // is what lets a transcript too big for one budget converge over ticks.
                updates[key] = FileCacheEntry(size: size, mtime: mtimeEpoch, bytesConsumed: r.bytesConsumed,
                                              boundaryTokens: boundary, totalTokens: total,
                                              cwd: fileCwd, complete: !r.hitDeadline)
                if r.hitDeadline { partial = true; break }
            }
            let name = cwd.map { ($0 as NSString).lastPathComponent }
                ?? SessionRow.projectName(forEncodedDir: dir.lastPathComponent)
            out.append(ProjectUsage(id: dir.lastPathComponent, name: name,
                                    tokensToday: tokens, sessionCount: jsonl.count))
        }

        // Merge-forward, not wholesale replace: entries for directories this run never
        // reached (deadline hit first) stay warm — dropping them would force full rescans
        // of unchanged files next tick. An entry is pruned only when its day is stale, or
        // when its directory *was* enumerated and the file is provably gone. That keeps
        // growth bounded to one day's worth of actually-existing transcript files.
        cacheLock.lock()
        fileCache = fileCache.filter { item in
            guard item.key.dayKey == since else { return false }
            guard let present = seenByDir[(item.key.path as NSString).deletingLastPathComponent] else { return true }
            return present.contains(item.key.path)
        }
        for (k, v) in updates { fileCache[k] = v }
        cacheLock.unlock()

        return (out.sorted { ($0.tokensToday ?? 0) > ($1.tokensToday ?? 0) }, partial)
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
    /// `bytesConsumed` with `boundaryTokens` counted so far. Lets tests exercise the
    /// resume path deterministically (a real mid-scan deadline expiry is wall-clock
    /// dependent and thus untestable without sleeps).
    static func _seedIncompleteEntryForTesting(path: String, day: Date, calendar: Calendar = .current,
                                               size: Int64, mtime: Double,
                                               bytesConsumed: Int64, boundaryTokens: Int) {
        let key = FileCacheKey(path: canonicalForTesting(path), dayKey: calendar.startOfDay(for: day).timeIntervalSince1970)
        let entry = FileCacheEntry(size: size, mtime: mtime, bytesConsumed: bytesConsumed,
                                   boundaryTokens: boundaryTokens, totalTokens: boundaryTokens,
                                   cwd: nil, complete: false)
        cacheLock.lock(); fileCache[key] = entry; cacheLock.unlock()
    }
}
