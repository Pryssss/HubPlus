import SwiftUI

/// A thin capsule progress bar.
struct MeterBar: View {
    let fraction: Double
    var color: Color = .green

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12))
                Capsule().fill(color.opacity(0.85))
                    .frame(width: max(0, min(1, fraction)) * geo.size.width)
            }
        }
    }
}
