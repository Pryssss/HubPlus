import SwiftUI

/// Aggregates the monitor data and publishes it to the UI. v1 refresh model is a
/// short timer that re-reads the registry and per-session transcript/git off-main;
/// FSEvents-driven updates are a later optimization.
@MainActor
final class AppStore: ObservableObject {
    @Published private(set) var rows: [SessionRow] = []
    @Published private(set) var tokensToday: Int?
    @Published private(set) var usage: UsageSnapshot?

    private var timer: Timer?
    private var usageTimer: Timer?
    private var usageFailures = 0
    private var prevStatus: [String: SessionStatusKind] = [:]
    private var prevExhausted: [String: Bool] = [:]
    private let work = DispatchQueue(label: "com.hubplus.refresh", qos: .utility)
    private let refreshInterval: TimeInterval = 3.0
    private let usageInterval: TimeInterval = 60.0

    func start() {
        refresh()
        refreshUsage()
        // `.common` mode so polling keeps firing during menu/scroll/resize tracking.
        timer = makeTimer(refreshInterval) { [weak self] in self?.refresh() }
        usageTimer = makeTimer(usageInterval) { [weak self] in self?.refreshUsage() }
    }

    func stop() {
        timer?.invalidate()
        usageTimer?.invalidate()
        timer = nil
        usageTimer = nil
    }

    private func makeTimer(_ interval: TimeInterval, _ fire: @escaping () -> Void) -> Timer {
        let t = Timer(timeInterval: interval, repeats: true) { _ in
            MainActor.assumeIsolated { fire() }
        }
        RunLoop.main.add(t, forMode: .common)
        return t
    }

    /// Fetch subscription usage off-main (the Keychain read may prompt and the
    /// network call must not block the UI), then publish on the main actor.
    func refreshUsage() {
        Task.detached { [weak self] in
            let result = await UsageClient.fetch()
            await MainActor.run { self?.applyUsage(result) }
        }
    }

    private func applyUsage(_ result: UsageResult) {
        switch result {
        case .ok(let snapshot):
            usageFailures = 0
            notifyUsageTransitions(snapshot)
            usage = snapshot
        case .authError:
            usageFailures = 0
            usage = UsageSnapshot(state: .authError)
        case .transient:
            if usage?.state == .ok { return }   // keep last-good values on a blip
            // No fast retry: the endpoint rate-limits (429), so we wait for the next
            // scheduled poll. First blip stays in the loading state; only repeated
            // failures surface "unavailable".
            usageFailures += 1
            if usageFailures >= 2 { usage = UsageSnapshot(state: .unavailable) }
        }
    }

    /// Notify when a window is newly exhausted, or newly available again after being
    /// exhausted. Baseline is set silently on first successful fetch.
    private func notifyUsageTransitions(_ snapshot: UsageSnapshot) {
        check(snapshot.fiveHour, label: "5h")
        check(snapshot.sevenDay, label: "7d")
    }

    private func check(_ window: UsageWindow?, label: String) {
        guard let window else { return }
        let exhausted = window.percentLeft <= 0
        if let prev = prevExhausted[label] {
            if prev, !exhausted {
                Notifier.notify("Claude \(label) limit is available again")
            } else if !prev, exhausted {
                Notifier.notify("Claude \(label) limit reached")
            }
        }
        prevExhausted[label] = exhausted
    }

    /// Menu-bar badge next to the icon: surface what needs attention first (an agent
    /// waiting on approval), then a near-limit warning, else the agent count.
    /// `alert` drives the icon tint (red vs orange).
    func compactBadge() -> (text: String, alert: Bool) {
        if rows.contains(where: { $0.info.statusKind == .waiting }) {
            return ("waiting", true)
        }
        if let u = usage, u.state == .ok {
            let windows = [("5h", u.fiveHour), ("7d", u.sevenDay)].compactMap { label, w in
                w.map { (label, $0.percentLeft) }
            }
            if let tight = windows.min(by: { $0.1 < $1.1 }), tight.1 <= 15 {
                return ("\(tight.0) \(tight.1)%", true)
            }
        }
        return (rows.isEmpty ? "" : "\(rows.count)", false)
    }

    func refresh() {
        work.async { [weak self] in
            guard self != nil else { return }
            let sessions = SessionWatcher.readLiveSessions()
            let rows = sessions.map { s -> SessionRow in
                let transcript = TranscriptReader.snapshot(cwd: s.cwd, sessionId: s.sessionId)
                let effectiveCwd = transcript?.cwd ?? s.cwd
                return SessionRow(info: s, transcript: transcript, git: GitProbe.probe(cwd: effectiveCwd))
            }
            let today = StatsCache.tokensToday()
            DispatchQueue.main.async {
                self?.applyRows(rows)
                self?.tokensToday = today
            }
        }
    }

    private func applyRows(_ newRows: [SessionRow]) {
        notifySessionTransitions(newRows)
        rows = newRows
    }

    /// Notify when an agent newly finishes (busy/waiting → idle) or newly needs
    /// the user (→ waiting). Baseline is set silently on first sight of a session.
    private func notifySessionTransitions(_ newRows: [SessionRow]) {
        for row in newRows {
            let kind = row.info.statusKind
            if let prev = prevStatus[row.id], prev != kind {
                if kind == .idle, prev == .busy || prev == .waiting {
                    Notifier.notify("✳ \(row.title) finished — ready for input")
                } else if kind == .waiting, prev != .waiting {
                    Notifier.notify("✳ \(row.title) is waiting for you")
                }
            }
            prevStatus[row.id] = kind
        }
        let live = Set(newRows.map { $0.id })
        prevStatus = prevStatus.filter { live.contains($0.key) }
    }
}
