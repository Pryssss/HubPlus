import SwiftUI

struct Sparkline: View {
    let values: [Double]            // raw values on a fixed 0...domainMax scale
    var color: Color = .green
    var domainMax: Double = 100     // utilization is a percent, so steady low ≠ "maxed"
    var fill: Bool = false          // soft gradient under the line
    var showGuide: Bool = false     // dotted guide at the domain top (= the limit)
    var endDot: Bool = false        // marks the most-recent sample
    private let lineWidth: CGFloat = 1.5

    var body: some View {
        GeometryReader { geo in
            let pts = points(in: geo.size)
            ZStack {
                if showGuide {
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: lineWidth / 2))
                        p.addLine(to: CGPoint(x: geo.size.width, y: lineWidth / 2))
                    }
                    .stroke(Color.white.opacity(0.12), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                }
                if fill, pts.count >= 2, let first = pts.first, let last = pts.last {
                    Path { p in
                        p.move(to: CGPoint(x: first.x, y: geo.size.height))
                        pts.forEach { p.addLine(to: $0) }
                        p.addLine(to: CGPoint(x: last.x, y: geo.size.height))
                        p.closeSubpath()
                    }
                    .fill(LinearGradient(colors: [color.opacity(0.22), color.opacity(0.02)],
                                         startPoint: .top, endPoint: .bottom))
                }
                Path { p in
                    for (i, pt) in pts.enumerated() {
                        i == 0 ? p.move(to: pt) : p.addLine(to: pt)
                    }
                }
                .stroke(color, lineWidth: lineWidth)
                if endDot, let last = pts.last {
                    Circle().fill(color)
                        .frame(width: 5, height: 5)
                        .position(last)
                }
            }
        }
    }

    private func points(in size: CGSize) -> [CGPoint] {
        let pts = downsample(values, to: 80)
        let maxV = max(domainMax, 0.0001)
        let inset = lineWidth / 2                       // keep a flat line off the edges
        let h = max(size.height - lineWidth, 0.0001)
        return pts.enumerated().map { i, v in
            let x = pts.count <= 1 ? size.width / 2 : size.width * CGFloat(i) / CGFloat(pts.count - 1)
            let clamped = min(max(v, 0), maxV)
            return CGPoint(x: x, y: inset + h * (1 - CGFloat(clamped / maxV)))
        }
    }

    private func downsample(_ v: [Double], to n: Int) -> [Double] {
        guard v.count > n else { return v }
        let strideLen = Double(v.count) / Double(n)
        return (0..<n).map { v[min(v.count - 1, Int(Double($0) * strideLen))] }
    }
}
