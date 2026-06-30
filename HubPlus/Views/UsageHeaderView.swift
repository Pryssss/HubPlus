import SwiftUI

/// Subscription usage rows (5h / 7d) from `oauth/usage`.
struct UsageHeaderView: View {
    let usage: UsageSnapshot?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("✳").font(.system(size: 12)).foregroundColor(.orange)
            Text("Claude")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white)
            VStack(alignment: .leading, spacing: 6) {
                switch usage?.state {
                case .authError:
                    note("re-auth in terminal (run `claude`)")
                case .unavailable:
                    note("usage unavailable")
                case .ok:
                    row(label: "5h", window: usage?.fiveHour)
                    row(label: "7d", window: usage?.sevenDay)
                case nil:
                    row(label: "5h", window: nil)   // loading (no data yet)
                    row(label: "7d", window: nil)
                }
            }
            Spacer()
        }
        .padding(.vertical, 8)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundColor(.orange.opacity(0.9))
    }

    private func row(label: String, window: UsageWindow?) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .frame(width: 18, alignment: .leading)
            MeterBar(fraction: window?.fractionLeft ?? 0, color: barColor(window))
                .frame(width: 110, height: 6)
            if let window {
                Text("\(window.percentLeft)% left")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                if let reset = resetLabel(window.resetsAt) {
                    Text("· \(reset)")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary.opacity(0.8))
                }
            } else {
                Text("—").font(.system(size: 11)).foregroundColor(.secondary)
            }
        }
    }

    /// Bar is green with room, yellow when low, red when nearly exhausted.
    private func barColor(_ window: UsageWindow?) -> Color {
        guard let u = window?.utilization else { return .green }   // percent used, 0...100
        if u >= 90 { return .red }
        if u >= 70 { return .yellow }
        return .green
    }

    private func resetLabel(_ date: Date?) -> String? {
        // Only render an upcoming reset; a past/stale value must not look current.
        guard let date, date.timeIntervalSinceNow > 0 else { return nil }
        let f = DateFormatter()
        if Calendar.current.isDateInToday(date) || date.timeIntervalSinceNow < 12 * 3600 {
            f.dateFormat = "h:mm a"
        } else {
            f.dateFormat = "MMM d"
        }
        return "resets \(f.string(from: date))"
    }
}
