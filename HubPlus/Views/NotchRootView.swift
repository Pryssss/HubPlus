import SwiftUI

/// Expanded state: header · tab switcher · content. Background/shape come from the
/// container, so this just lays out content and fills the width.
struct NotchRootView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var ui: NotchUIModel
    var onClose: () -> Void = {}
    var onJump: (SessionRow) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            divider
            UsageHeaderView(usage: store.usage, burn5h: store.burn5h, burn7d: store.burn7d)
            divider
            tabSwitcher
            tabContent
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("✳").font(.system(size: 14))
            Text("\(store.rows.count) agent\(store.rows.count == 1 ? "" : "s")")
                .font(.system(size: 14, weight: .semibold))
            Spacer()
            if let today = store.tokensToday {
                Label("\(formatK(today)) today", systemImage: "bolt.fill")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.4))
            }
            .buttonStyle(.plain)
            .help("Collapse")
        }
        .foregroundColor(.white)
        .padding(.bottom, 7)
    }

    private var tabSwitcher: some View {
        HStack {
            Picker("", selection: $ui.tab) {
                Text("Agents").tag(NotchTab.agents)
                Text("Stats").tag(NotchTab.stats)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 180)
            Spacer()
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder private var tabContent: some View {
        switch ui.tab {
        case .agents:
            agentsContent
        case .stats:
            StatsView(store: store)
        }
    }

    @ViewBuilder private var agentsContent: some View {
        if store.rows.isEmpty {
            Text("No live Claude Code sessions")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 16)
        } else {
            VStack(spacing: 0) {
                ForEach(store.rows) { row in
                    SessionCardView(row: row, onJump: onJump)
                    if row.id != store.rows.last?.id {
                        Divider().overlay(Color.white.opacity(0.06))
                    }
                }
            }
        }
    }

    private var divider: some View { Divider().overlay(Color.white.opacity(0.08)) }
    private func formatK(_ n: Int) -> String { n >= 1000 ? "\(n / 1000)k" : "\(n)" }
}
