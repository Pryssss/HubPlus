import SwiftUI

/// Collapsed pill — compact but informative: logo, a status dot per agent, and the
/// tightest usage window. Horizontal when docked top/bottom, vertical on a side.
struct NotchPillView: View {
    @ObservedObject var store: AppStore
    var vertical: Bool = false

    var body: some View {
        Group {
            if vertical { verticalBody } else { horizontalBody }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
    }

    private var horizontalBody: some View {
        HStack(spacing: 7) {
            Text("✳").font(.system(size: 13)).foregroundColor(.orange)
            dots(spacing: 4)
            if let u = tightestUsage {
                Text("\(u.label) \(u.percentLeft)%")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(u.color)
            }
        }
        .padding(.horizontal, 13)
    }

    private var verticalBody: some View {
        VStack(spacing: 7) {
            Text("✳").font(.system(size: 13)).foregroundColor(.orange)
            dots(spacing: 4, vertical: true)
            if let u = tightestUsage {
                Text("\(u.percentLeft)%")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(u.color)
            }
        }
        .padding(.vertical, 11)
    }

    @ViewBuilder
    private func dots(spacing: CGFloat, vertical: Bool = false) -> some View {
        let cap = vertical ? 4 : 6
        let shown = Array(store.rows.prefix(cap))
        let layout = {
            if vertical {
                return AnyView(VStack(spacing: spacing) { dotViews(shown) })
            } else {
                return AnyView(HStack(spacing: spacing) { dotViews(shown) })
            }
        }()
        layout
    }

    @ViewBuilder
    private func dotViews(_ shown: [SessionRow]) -> some View {
        ForEach(shown) { row in
            Circle().fill(dotColor(row)).frame(width: 6, height: 6)
        }
        if store.rows.count > shown.count {
            Text("+\(store.rows.count - shown.count)")
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(.secondary)
        }
    }

    private func dotColor(_ row: SessionRow) -> Color {
        switch row.info.statusKind {
        case .idle:            return .green
        case .busy:            return Color(red: 0.98, green: 0.78, blue: 0.25)
        case .waiting, .error: return .red
        case .unknown:         return .gray
        }
    }

    private var tightestUsage: (label: String, percentLeft: Int, color: Color)? {
        guard let u = store.usage, u.state == .ok else { return nil }
        let windows = [("5h", u.fiveHour), ("7d", u.sevenDay)].compactMap { label, w in
            w.map { (label, $0.percentLeft) }
        }
        guard let tight = windows.min(by: { $0.1 < $1.1 }) else { return nil }
        let pct = tight.1
        let color: Color = pct <= 10 ? .red : (pct <= 25 ? .orange : .green)
        return (tight.0, pct, color)
    }
}
