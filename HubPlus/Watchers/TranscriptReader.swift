import Foundation

/// Reads the tail of a session's JSONL transcript and extracts the last assistant
/// message, the model, and the context-token count. Best-effort; never throws.
/// All extracted text is treated as untrusted and sanitized before display.
enum TranscriptReader {
    static func snapshot(cwd: String, sessionId: String) -> TranscriptSnapshot? {
        let url = ClaudePaths.transcriptURL(cwd: cwd, sessionId: sessionId)
        guard let data = tailData(of: url, maxBytes: 256 * 1024),
              let text = String(data: data, encoding: .utf8)
        else { return nil }

        var snap = TranscriptSnapshot()
        // Lines are oldest-first; overwriting keeps the newest values.
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else { continue }

            if let ts = obj["timestamp"] as? String, let d = parseDate(ts) {
                snap.lastActivity = d
            }
            if let c = obj["cwd"] as? String, !c.isEmpty { snap.cwd = c }  // latest wins
            guard obj["type"] as? String == "assistant",
                  let message = obj["message"] as? [String: Any] else { continue }

            if let model = message["model"] as? String { snap.model = model }
            if let usage = message["usage"] as? [String: Any] {
                let input = intValue(usage["input_tokens"])
                let cacheRead = intValue(usage["cache_read_input_tokens"])
                let cacheCreate = intValue(usage["cache_creation_input_tokens"])
                snap.contextTokens = input + cacheRead + cacheCreate
            }
            if let content = message["content"] as? [[String: Any]] {
                let texts = content.compactMap { block -> String? in
                    (block["type"] as? String) == "text" ? block["text"] as? String : nil
                }
                let joined = texts.joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !joined.isEmpty { snap.lastText = sanitize(joined) }
            }
        }
        return snap
    }

    /// Read up to the last `maxBytes` of a file. The leading partial line (if any)
    /// simply fails JSON parsing and is skipped.
    private static func tailData(of url: URL, maxBytes: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? handle.seek(toOffset: start)
        return try? handle.readToEnd()
    }

    private static func intValue(_ any: Any?) -> Int {
        if let i = any as? Int { return i }
        if let d = any as? Double { return Int(d) }
        return 0
    }

    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain = ISO8601DateFormatter()

    private static func parseDate(_ s: String) -> Date? {
        isoFractional.date(from: s) ?? isoPlain.date(from: s)
    }

    /// Strip control characters and cap length so untrusted text renders inert.
    static func sanitize(_ s: String) -> String {
        let kept = s.unicodeScalars.filter { scalar in
            if scalar == "\n" || scalar == "\t" { return true }
            if scalar.value < 0x20 { return false }
            if scalar.value == 0x7f { return false }
            return true
        }
        var out = String(String.UnicodeScalarView(kept))
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        let cap = 240
        if out.count > cap { out = String(out.prefix(cap)) + "…" }
        return out
    }
}
