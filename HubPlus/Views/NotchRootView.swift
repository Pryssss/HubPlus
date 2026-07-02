import SwiftUI

/// Reports the expanded content's natural height so the panel can size itself
/// instead of the controller re-deriving the layout with hand-tuned constants.
struct ExpandedContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Expanded state: header · tab switcher · content. Background/shape come from the
/// container, so this just lays out content and fills the width.
struct NotchRootView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var ui: NotchUIModel
    /// The panel's fixed expanded width; the height follows the content.
    var expandedWidth: CGFloat = 560
    var onClose: () -> Void = {}
    var onJump: (SessionRow) -> Void = { _ in }
    /// Called with the content's natural height at `expandedWidth` whenever it changes.
    var onHeightChange: (CGFloat) -> Void = { _ in }

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(heightProbe)
            .onPreferenceChange(ExpandedContentHeightKey.self) { onHeightChange($0) }
    }

    /// The laid-out expanded content. Rendered visibly (filling the panel width) and
    /// again inside `heightProbe` (pinned to `expandedWidth`) purely to measure height.
    @ViewBuilder private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            divider
            UsageHeaderView(usage: store.usage, burn5h: store.burn5h, burn7d: store.burn7d)
            divider
            tabSwitcher
            tabContent
        }
        .padding(12)
    }

    /// A hidden copy laid out at the true expanded width, so the reported height
    /// matches the settled panel rather than the narrower width mid expand-animation.
    private var heightProbe: some View {
        content
            .frame(width: expandedWidth, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .background(GeometryReader { proxy in
                Color.clear.preference(key: ExpandedContentHeightKey.self, value: proxy.size.height)
            })
            .hidden()
            .allowsHitTesting(false)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("✳").font(.system(size: 14))
            Text("\(store.rows.count) agent\(store.rows.count == 1 ? "" : "s")")
                .font(.system(size: 14, weight: .semibold))
            Spacer()
            if let today = store.tokensToday {
                Label("\(TokenFormat.compact(today)) today", systemImage: "bolt.fill")
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
            VStack(spacing: 3) {
                Text("No live Claude Code sessions")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                Text("Sessions appear when `claude` runs in a terminal")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary.opacity(0.6))
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 16)
        } else {
            let rows = SessionRow.urgencySorted(store.rows)
            VStack(spacing: 0) {
                ForEach(rows) { row in
                    SessionCardView(row: row, onJump: onJump)
                    if row.id != rows.last?.id {
                        Divider().overlay(Color.white.opacity(0.06))
                    }
                }
            }
            .animation(.default, value: rows.map(\.id))
        }
    }

    private var divider: some View { Divider().overlay(Color.white.opacity(0.08)) }
}
