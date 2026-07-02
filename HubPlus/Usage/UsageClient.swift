import Foundation

/// Outcome of a usage fetch. Distinguishes a real auth problem from a transient
/// blip so the UI can keep last-good data instead of flickering to "—".
enum UsageResult {
    case ok(UsageSnapshot)
    case authError      // missing token / 401 / 403
    case transient      // network error, non-2xx, unparseable, or schema drift
}

/// Fetches subscription usage (5h / 7d windows) from the same endpoint the Claude
/// Code CLI uses for `/usage`. The OAuth token is sent only to api.anthropic.com.
enum UsageClient {
    private static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    /// Token acquisition moved out to the provider (`ClaudeOAuthUsageProvider`) so a
    /// future local-estimation provider needs no token; the caller passes an already-read
    /// OAuth token here.
    static func fetch(token: String) async -> UsageResult {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "GET"
        req.timeoutInterval = 15
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("HubPlus", forHTTPHeaderField: "User-Agent")

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            // Non-HTTP responses (not expected in practice) fall through to 200 so the
            // status-code gate is a no-op and parsing proceeds — the same behavior the
            // original `resp as? HTTPURLResponse` optional-bind produced.
            let statusCode = (resp as? HTTPURLResponse)?.statusCode ?? 200
            return parse(statusCode: statusCode, data: data)
        } catch {
            NSLog("HubPlus: usage fetch error \(error.localizedDescription)")
            return .transient
        }
    }

    /// Pure response-handling seam, split out of `fetch()` so fixture tests can drive
    /// every status-code/JSON-shape branch without a live network call. No behavior
    /// change from the inline logic it replaces.
    static func parse(statusCode: Int, data: Data) -> UsageResult {
        if statusCode == 401 || statusCode == 403 { return .authError }
        if !(200..<300).contains(statusCode) {
            NSLog("HubPlus: usage HTTP \(statusCode)")
            return .transient
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            NSLog("HubPlus: usage body was not a JSON object")
            return .transient
        }
        let five = window(obj["five_hour"])
        let seven = window(obj["seven_day"])
        guard five != nil || seven != nil else {
            NSLog("HubPlus: usage response missing five_hour/seven_day")
            return .transient
        }
        return .ok(UsageSnapshot(fiveHour: five, sevenDay: seven, state: .ok))
    }

    private static func window(_ any: Any?) -> UsageWindow? {
        guard let d = any as? [String: Any] else { return nil }
        let util: Double
        if let v = d["utilization"] as? Double { util = v }
        else if let v = d["utilization"] as? Int { util = Double(v) }
        else { return nil }
        return UsageWindow(utilization: util, resetsAt: parseDate(d["resets_at"]))
    }

    private static func parseDate(_ any: Any?) -> Date? {
        func fromEpoch(_ n: Double) -> Date {
            Date(timeIntervalSince1970: n > 1_000_000_000_000 ? n / 1000 : n)
        }
        if let n = any as? Double { return fromEpoch(n) }
        if let n = any as? Int { return fromEpoch(Double(n)) }
        if let s = any as? String {
            let isoF = ISO8601DateFormatter()
            isoF.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = isoF.date(from: s) { return d }
            if let d = ISO8601DateFormatter().date(from: s) { return d }
            // Strip sub-second precision the formatters reject (e.g. ".877499").
            if let r = s.range(of: "\\.[0-9]+", options: .regularExpression) {
                let stripped = s.replacingCharacters(in: r, with: "")
                if let d = ISO8601DateFormatter().date(from: stripped) { return d }
            }
            if let n = Double(s) { return fromEpoch(n) }
        }
        return nil
    }
}
