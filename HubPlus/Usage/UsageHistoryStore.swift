import Foundation

struct UsageSample: Codable, Equatable { let t: Double; let five: Double; let seven: Double }

/// Persists usage samples to disk, capped to a time ring. The pure trim logic is
/// exercised by tests via an injected clock + temp file.
final class UsageHistoryStore {
    private(set) var samples: [UsageSample] = []
    private let fileURL: URL
    private let ringSeconds: Double
    private let now: () -> Double
    private let io = DispatchQueue(label: "com.hubplus.usagehistory")

    init(fileURL: URL, ringSeconds: Double = 48 * 3600, now: @escaping () -> Double = { Date().timeIntervalSince1970 }) {
        self.fileURL = fileURL
        self.ringSeconds = ringSeconds
        self.now = now
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([UsageSample].self, from: data) {
            samples = decoded
        }
    }

    func record(five: Double, seven: Double) {
        let t = now()
        samples.append(UsageSample(t: t, five: five, seven: seven))
        let cutoff = t - ringSeconds
        samples.removeAll { $0.t < cutoff }
        let snapshot = samples
        io.async { [fileURL] in
            if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: fileURL, options: .atomic) }
        }
    }

    func fiveSeries() -> [(t: Double, util: Double)] { samples.map { ($0.t, $0.five) } }
    func sevenSeries() -> [(t: Double, util: Double)] { samples.map { ($0.t, $0.seven) } }

    /// Blocks until all pending async IO operations have completed.
    /// Intended for use in tests to synchronize against the write path.
    func waitForPendingIO() { io.sync {} }

    /// Default on-disk location.
    static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HubPlus", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("usage-history.json")
    }
}
