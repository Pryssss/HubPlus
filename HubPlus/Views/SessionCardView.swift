import SwiftUI

/// One compact session card: a meta line (name · branch · status capsules) and a
/// single-line last message.
struct SessionCardView: View {
    let row: SessionRow
    var onJump: (SessionRow) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            metaLine
            if let text = row.transcript?.lastText {
                Text(text)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.62))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var metaLine: some View {
        HStack(spacing: 6) {
            Text(row.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(1)
            if let branch = row.git?.branch {
                HStack(spacing: 2) {
                    Image(systemName: "arrow.triangle.branch").font(.system(size: 8))
                    Text(branch).font(.system(size: 10, design: .monospaced))
                    if row.git?.isDirty == true {
                        Circle().fill(Color.yellow).frame(width: 4, height: 4)
                    }
                }
                .foregroundColor(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 6)
            statusCapsule
            if let model = row.transcript?.modelShortName, model != "—" {
                capsule(model, color: .gray, prominent: false)
            }
            if let pct = row.transcript?.contextPercent {
                capsule("\(Int(pct * 100))%", color: contextColor(pct), prominent: false)
                    .help("Context window used")
            }
            Text(ageString).font(.system(size: 9)).foregroundColor(.secondary.opacity(0.7))
            Button { onJump(row) } label: {
                Image(systemName: "arrow.up.forward.app").font(.system(size: 11))
            }
            .buttonStyle(.plain).foregroundColor(.white.opacity(0.5))
            .help("Jump to this agent's terminal window")
        }
    }

    // MARK: Capsules

    private var statusCapsule: some View {
        HStack(spacing: 4) {
            Circle().fill(statusColor).frame(width: 5, height: 5)
            Text(statusLabel).font(.system(size: 9, weight: .semibold))
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(Capsule().fill(statusColor.opacity(0.16)))
        .overlay(Capsule().stroke(statusColor.opacity(0.30), lineWidth: 0.5))
        .foregroundColor(statusColor)
    }

    private func capsule(_ text: String, color: Color, prominent: Bool) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(prominent ? 0.16 : 0.10)))
            .foregroundColor(prominent ? color : .white.opacity(0.7))
    }

    // MARK: Status

    private var statusColor: Color {
        switch row.info.statusKind {
        case .idle:    return .green
        case .busy:    return Color(red: 0.98, green: 0.78, blue: 0.25)   // amber
        case .waiting: return isBlocked ? .red : .orange
        case .error:   return .red
        case .unknown: return .gray
        }
    }

    private var statusLabel: String {
        switch row.info.statusKind {
        case .idle:    return "IDLE"
        case .busy:    return "BUSY"
        case .waiting: return isBlocked ? "BLOCKED" : (isApproval ? "APPROVE" : "WAITING")
        case .error:   return "ERROR"
        case .unknown:
            let raw = (row.info.status ?? "").uppercased()
            return raw.isEmpty ? "—" : raw
        }
    }

    private var isBlocked: Bool { (row.info.status ?? "").lowercased().contains("block") }
    private var isApproval: Bool {
        (row.info.status ?? "").lowercased().contains("approv")
    }

    private func contextColor(_ pct: Double) -> Color {
        if pct >= 0.9 { return .red }
        if pct >= 0.75 { return .orange }
        return .gray
    }

    private var ageString: String {
        guard let ms = row.info.updatedAt ?? row.info.statusUpdatedAt else { return "" }
        let date = Date(timeIntervalSince1970: ms / 1000.0)
        if abs(date.timeIntervalSinceNow) < 5 { return "now" }
        let rel = RelativeDateTimeFormatter()
        rel.unitsStyle = .abbreviated
        return rel.localizedString(for: date, relativeTo: Date())
    }
}
