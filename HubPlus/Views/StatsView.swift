import SwiftUI

/// Consumption-first stats: summary chips, 48h limit history, a 7-day token
/// trend, and today's per-project breakdown. Primary numbers everywhere are
/// real input+output tokens; cache totals (which inflate raw sums ~500×) live
/// in tooltips so they stay inspectable without drowning the signal.
struct StatsView: View {
    @ObservedObject var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            summaryChips
            sectionCaption("LIMITS · 48H")
            limitRow("5h", series: store.fiveSeries().map { $0.util },
                     window: store.usage?.fiveHour, color: .green)
            limitRow("7d", series: store.sevenSeries().map { $0.util },
                     window: store.usage?.sevenDay, color: .blue)
            Divider().opacity(0.2)
            sectionCaption("TOKENS · 7 DAYS")
            dailyChart
            Divider().opacity(0.2)
            sectionCaption("BY PROJECT · TODAY")
            projectRows
        }
        .padding(.vertical, 6)
    }

    // MARK: Summary

    private var todayTokens: TokenCount { store.dailyTokens.last?.tokens ?? TokenCount() }
    private var weekReal: Int { store.dailyTokens.reduce(0) { $0 + $1.tokens.real } }

    private var summaryChips: some View {
        HStack(spacing: 8) {
            chip("TODAY", TokenFormat.compact(todayTokens.real))
                .help("in/out \(TokenFormat.compact(todayTokens.real)) · cache \(TokenFormat.compact(todayTokens.cache))")
            chip("7 DAYS", TokenFormat.compact(weekReal))
            chip("TOP PROJECT", store.projectUsage.first?.name ?? "—")
        }
    }

    private func chip(_ caption: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(caption).font(.system(size: 9, weight: .medium)).kerning(0.5)
                .foregroundColor(.secondary.opacity(0.8))
            Text(value).font(.system(size: 15, weight: .semibold))
                .foregroundColor(.white).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.05)))
    }

    // MARK: Limits

    private func limitRow(_ label: String, series: [Double], window: UsageWindow?, color: Color) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 11)).foregroundColor(.secondary)
                .frame(width: 18, alignment: .leading)
            if series.count < 2 {
                Text("collecting…").font(.system(size: 10))
                    .foregroundColor(.secondary.opacity(0.6))
                    .frame(maxWidth: .infinity, minHeight: 26, alignment: .leading)
            } else {
                Sparkline(values: series, color: color, fill: true, showGuide: true, endDot: true)
                    .frame(maxWidth: .infinity)
                    .frame(height: 26)
            }
            Text(window.map { "\(Int($0.utilization.rounded()))% used" } ?? "—")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(usedColor(window?.utilization))
                .frame(width: 62, alignment: .trailing)
        }
    }

    private func usedColor(_ utilization: Double?) -> Color {
        guard let u = utilization else { return .secondary }
        if u >= 90 { return .red }
        if u >= 70 { return .yellow }
        return .secondary
    }

    // MARK: Daily tokens

    private var dailyChart: some View {
        let days = store.dailyTokens
        let maxReal = max(days.map { $0.tokens.real }.max() ?? 0, 1)
        return HStack(alignment: .bottom, spacing: 6) {
            ForEach(Array(days.enumerated()), id: \.offset) { i, day in
                let isToday = i == days.count - 1
                VStack(spacing: 3) {
                    Text(day.tokens.real > 0 ? TokenFormat.compact(day.tokens.real) : " ")
                        .font(.system(size: 8)).foregroundColor(.secondary)
                        .lineLimit(1).minimumScaleFactor(0.8)
                    if day.tokens.real > 0 {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.orange.opacity(isToday ? 1.0 : 0.55))
                            .frame(height: max(3, 44 * CGFloat(day.tokens.real) / CGFloat(maxReal)))
                    } else {
                        Rectangle().fill(Color.white.opacity(0.15)).frame(height: 1)
                    }
                    Text(weekday(day.date))
                        .font(.system(size: 9, weight: isToday ? .semibold : .regular))
                        .foregroundColor(isToday ? .white : .secondary)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 72, alignment: .bottom)
    }

    private func weekday(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "today" }
        let f = DateFormatter()
        f.dateFormat = "EEE"
        return f.string(from: date)
    }

    // MARK: Projects

    @ViewBuilder private var projectRows: some View {
        let listed = Array(store.projectUsage.prefix(6))
        if listed.isEmpty {
            Text(store.partialProjects ? "scanning transcripts…" : "no activity today yet")
                .font(.system(size: 10)).foregroundColor(.secondary.opacity(0.7))
        } else {
            let maxReal = max(listed.compactMap { $0.tokens?.real }.max() ?? 0, 1)
            VStack(alignment: .leading, spacing: 7) {
                ForEach(listed, id: \.id) { project in
                    projectRow(project, maxReal: maxReal)
                }
                if store.projectUsage.count > listed.count {
                    Text("+\(store.projectUsage.count - listed.count) more")
                        .font(.system(size: 9)).foregroundColor(.secondary.opacity(0.7))
                }
                if store.partialProjects {
                    Text("partial — scanning…")
                        .font(.system(size: 9)).foregroundColor(.secondary.opacity(0.7))
                }
            }
        }
    }

    private func projectRow(_ project: ProjectUsage, maxReal: Int) -> some View {
        HStack(spacing: 8) {
            Text(project.name).font(.system(size: 11)).foregroundColor(.white)
                .lineLimit(1)
                .frame(width: 130, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.07))
                    if let real = project.tokens?.real {
                        Capsule().fill(Color.orange.opacity(0.85))
                            .frame(width: max(3, geo.size.width * CGFloat(real) / CGFloat(maxReal)))
                    }
                }
            }
            .frame(height: 3)
            HStack(spacing: 4) {
                if let tokens = project.tokens {
                    Text(TokenFormat.compact(tokens.real))
                        .font(.system(size: 11)).foregroundColor(.white)
                    Text("· \(project.sessionCount) sess")
                        .font(.system(size: 10)).foregroundColor(.secondary)
                } else {
                    Text("\(project.sessionCount) sess")
                        .font(.system(size: 11)).foregroundColor(.secondary)
                }
            }
            .frame(width: 110, alignment: .trailing)
        }
        .help(helpText(project))
    }

    private func helpText(_ project: ProjectUsage) -> String {
        guard let tokens = project.tokens else { return "\(project.sessionCount) sessions" }
        return "in/out \(TokenFormat.compact(tokens.real)) · cache \(TokenFormat.compact(tokens.cache)) · \(project.sessionCount) sessions"
    }

    // MARK: Shared

    private func sectionCaption(_ title: String) -> some View {
        Text(title).font(.system(size: 9, weight: .medium)).kerning(0.6)
            .foregroundColor(.secondary.opacity(0.8))
    }
}
