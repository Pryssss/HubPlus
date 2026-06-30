import SwiftUI

struct SettingsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Hub+").font(.title2).bold()
            Text("Monitors local Claude Code sessions in the notch.")
                .foregroundColor(.secondary)
            Spacer()
        }
        .padding(20)
        .frame(width: 420, height: 220)
    }
}
