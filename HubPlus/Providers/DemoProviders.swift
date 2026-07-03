import Foundation

/// HUBPLUS_DEMO=1 fixtures: a fully mocked data set for screenshots and demos, so the
/// app can render every UI state without touching ~/.claude, the Keychain, or the
/// network — and without leaking real project names or transcript text.
///
/// Coherence contract (enforced by DemoModeTests): per-project shares sum to the last
/// daily bar, and the seeded 48h history ends at the usage snapshot's utilizations, so
/// no two demo widgets ever contradict each other.
enum DemoData {
    /// Utilization the demo pretends we're at right now (percent used).
    static let fiveUsed = 11.0
    static let sevenUsed = 56.0

    struct Project {
        let dir: String            // last path component of cwd == repo name
        let branch: String
        let ahead: Int
        let behind: Int
        let dirty: Bool
        let status: String
        let statusAge: TimeInterval
        let model: String
        let contextTokens: Int
        let lastText: String
        let todayTokens: Int
        let sessions: Int
    }

    static let projects: [Project] = [
        Project(dir: "checkout-service", branch: "feat/payment-retries",
                ahead: 2, behind: 0, dirty: true,
                status: "waiting", statusAge: 3 * 60,
                model: "claude-fable-5", contextTokens: 124_000,
                lastText: "The migration is ready — approve running `psql -f migrate.sql` against staging to continue.",
                todayTokens: 640_000, sessions: 3),
        Project(dir: "mobile-app", branch: "feat/onboarding-redesign",
                ahead: 5, behind: 1, dirty: true,
                status: "busy", statusAge: 12 * 60,
                model: "claude-sonnet-4-6", contextTokens: 54_000,
                lastText: "Splitting OnboardingFlowView into per-step views, then re-running the snapshot tests.",
                todayTokens: 480_000, sessions: 2),
        Project(dir: "docs-site", branch: "main",
                ahead: 0, behind: 0, dirty: false,
                status: "idle", statusAge: 25 * 60,
                model: "claude-haiku-4-5", contextTokens: 16_000,
                lastText: "Published the API reference update — 42 pages regenerated and all cross-links verified.",
                todayTokens: 210_000, sessions: 1),
        Project(dir: "infra", branch: "fix/alert-noise",
                ahead: 1, behind: 2, dirty: false,
                status: "idle", statusAge: 64 * 60,
                model: "claude-opus-4-8", contextTokens: 82_000,
                lastText: "Tuned the paging thresholds; staging false-positive rate is down about 80%.",
                todayTokens: 90_000, sessions: 1),
    ]

    static func cwd(_ p: Project) -> String { "/Users/demo/\(p.dir)" }

    static func git(cwd: String) -> GitInfo? {
        guard let p = projects.first(where: { self.cwd($0) == cwd }) else { return nil }
        return GitInfo(branch: p.branch, repoName: p.dir,
                       isDirty: p.dirty, ahead: p.ahead, behind: p.behind)
    }

    static func usageSnapshot(now: Date) -> UsageSnapshot {
        UsageSnapshot(
            fiveHour: UsageWindow(utilization: fiveUsed,
                                  resetsAt: now.addingTimeInterval(2.3 * 3600)),
            sevenDay: UsageWindow(utilization: sevenUsed,
                                  resetsAt: now.addingTimeInterval(26 * 3600)),
            state: .ok)
    }

    /// 7 daily bars (today last) + today's per-project shares. Cache dwarfs real
    /// tokens the way raw transcript sums do (~40×).
    static func stats(now: Date)
        -> (projects: [ProjectUsage], daily: [(date: Date, tokens: TokenCount)], partial: Bool) {
        let cal = Calendar.current
        let today = projects.reduce(0) { $0 + $1.todayTokens }
        let pastReal = [2_100_000, 380_000, 3_400_000, 5_200_000, 4_600_000, 3_800_000]
        let daily = (0..<7).map { i -> (date: Date, tokens: TokenCount) in
            let date = cal.startOfDay(for: now.addingTimeInterval(Double(i - 6) * 86_400))
            let real = i == 6 ? today : pastReal[i]
            return (date: date, tokens: TokenCount(real: real, cache: real * 40))
        }
        let shares = projects.map {
            ProjectUsage(id: cwd($0), name: $0.dir,
                         tokens: TokenCount(real: $0.todayTokens, cache: $0.todayTokens * 40),
                         sessionCount: $0.sessions)
        }
        return (projects: shares, daily: daily, partial: false)
    }

    /// 48h of samples every 10 min, written to a temp file and loaded through the
    /// normal store initializer: the 5h series is a sawtooth (climb, reset on the
    /// window boundary), the 7d series a slow rise — both ending at today's values.
    static func seededHistory(now: Date) -> UsageHistoryStore {
        let step = 600.0
        let end = now.timeIntervalSince1970
        let start = end - 48 * 3600
        // Place 5h window boundaries so the current window is 20% elapsed at `end`,
        // which puts the final sawtooth sample exactly at fiveUsed.
        let windowLen = 5 * 3600.0
        let elapsedInWindow = 0.2 * windowLen
        let finalPeak = fiveUsed / 0.2

        var samples: [UsageSample] = []
        for t in stride(from: start, through: end, by: step) {
            let sinceEnd = end - t
            let windowIndex = Int((sinceEnd + elapsedInWindow) / windowLen)
            let phase = 1.0 - ((sinceEnd + elapsedInWindow)
                .truncatingRemainder(dividingBy: windowLen)) / windowLen
            let peak = windowIndex == 0 ? finalPeak
                                        : 45 + 40 * abs(sin(Double(windowIndex) * 2.4))
            let five = min(100, phase * peak)
            let x = (t - start) / (end - start)
            let seven = min(100, max(0, sevenUsed - 16 * (1 - x) + 1.5 * sin(x * 20)))
            samples.append(UsageSample(t: t, five: five, seven: seven))
        }
        // Pin the endpoints so the sparkline meets the usage bars exactly.
        samples[samples.count - 1] = UsageSample(t: end, five: fiveUsed, seven: sevenUsed)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hubplus-demo-history-\(UUID().uuidString).json")
        if let data = try? JSONEncoder().encode(samples) { try? data.write(to: url) }
        return UsageHistoryStore(fileURL: url)
    }
}

/// Four fake sessions covering every status the UI renders (waiting, busy, idle ×2).
/// Timestamps are anchored at provider creation, so ages read naturally and keep
/// aging while the demo runs.
struct DemoAgentProvider: AgentProvider {
    let id = "claude"
    private let anchor: Date

    init(now: Date = Date()) { anchor = now }

    func liveSessions() -> [SessionInfo] {
        DemoData.projects.enumerated().map { i, p in
            let statusMs = (anchor.timeIntervalSince1970 - p.statusAge) * 1000
            return SessionInfo(pid: 90_001 + i,
                               sessionId: "demo-\(p.dir)",
                               cwd: DemoData.cwd(p),
                               name: nil,
                               status: p.status,
                               kind: "interactive",
                               entrypoint: "cli",
                               version: "2.0.0",
                               peerProtocol: nil,
                               startedAt: statusMs - 3_600_000,
                               updatedAt: statusMs,
                               statusUpdatedAt: statusMs)
        }
    }

    func transcriptSnapshot(cwd: String, sessionId: String) -> TranscriptSnapshot? {
        guard let p = DemoData.projects.first(where: { DemoData.cwd($0) == cwd }) else { return nil }
        return TranscriptSnapshot(lastText: p.lastText,
                                  model: p.model,
                                  contextTokens: p.contextTokens,
                                  lastActivity: anchor.addingTimeInterval(-p.statusAge),
                                  cwd: cwd)
    }
}

/// Always-ok usage snapshot; reset times are computed per fetch so they stay ahead
/// of "now" however long the demo runs.
struct DemoUsageProvider: UsageProvider {
    func fetch() async -> UsageResult { .ok(DemoData.usageSnapshot(now: Date())) }
}

extension AppStore {
    /// The fully mocked store behind HUBPLUS_DEMO=1.
    static func demo() -> AppStore {
        AppStore(agents: [DemoAgentProvider()],
                 usage: DemoUsageProvider(),
                 history: DemoData.seededHistory(now: Date()),
                 gitProbe: { DemoData.git(cwd: $0) },
                 stats: { DemoData.stats(now: $0) })
    }
}
