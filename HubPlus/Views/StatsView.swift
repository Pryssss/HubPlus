import SwiftUI

struct StatsView: View {
    @ObservedObject var store: AppStore
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            sparkRow("5h", store.fiveSeries().map { $0.util }, store.burn5h, .green)
            sparkRow("7d", store.sevenSeries().map { $0.util }, store.burn7d, .blue)
            Divider().opacity(0.2)
            Text("Tokens / day").font(.system(size: 10)).foregroundColor(.secondary)
            HStack(alignment: .bottom, spacing: 3) {
                let maxT = max(store.dailyTokens.map { $0.tokens }.max() ?? 1, 1)
                ForEach(Array(store.dailyTokens.enumerated()), id: \.offset) { _, d in
                    Capsule().fill(Color.orange.opacity(0.8))
                        .frame(width: 10, height: max(2, 34 * CGFloat(d.tokens) / CGFloat(maxT)))
                }
            }.frame(height: 36)
            Divider().opacity(0.2)
            Text("By project today").font(.system(size: 10)).foregroundColor(.secondary)
            ForEach(store.projectUsage.prefix(6), id: \.id) { p in
                HStack {
                    Text(p.name).font(.system(size: 11)).foregroundColor(.white).lineLimit(1)
                    Spacer()
                    Text(p.tokensToday.map(tokenLabel) ?? "\(p.sessionCount) sess")
                        .font(.system(size: 11)).foregroundColor(.secondary)
                }
            }
            if store.partialProjects {
                Text("partial — scanning…").font(.system(size: 9)).foregroundColor(.secondary.opacity(0.7))
            }
        }.padding(.vertical, 6)
    }
    private func sparkRow(_ label: String, _ vals: [Double], _ burn: BurnProjection?, _ c: Color) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 11)).foregroundColor(.secondary).frame(width: 18, alignment: .leading)
            if vals.count < 2 {
                Text("collecting…").font(.system(size: 10)).foregroundColor(.secondary.opacity(0.6))
                    .frame(width: 120, height: 24, alignment: .leading)
            } else {
                Sparkline(values: vals, color: c).frame(width: 120, height: 24)
            }
            if let burn { Text(burn.label).font(.system(size: 10)).foregroundColor(.secondary) }
        }
    }
    private func tokenLabel(_ n: Int) -> String { n >= 1000 ? "\(n/1000)k" : "\(n)" }
}
