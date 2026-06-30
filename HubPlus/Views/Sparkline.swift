import SwiftUI

struct Sparkline: View {
    let values: [Double]            // raw values on a fixed 0...domainMax scale
    var color: Color = .green
    var domainMax: Double = 100     // utilization is a percent, so steady low ≠ "maxed"
    private let lineWidth: CGFloat = 1.5
    var body: some View {
        GeometryReader { geo in
            let pts = downsample(values, to: 80)
            let maxV = max(domainMax, 0.0001)
            let inset = lineWidth / 2                       // keep a flat line off the edges
            let h = max(geo.size.height - lineWidth, 0.0001)
            Path { p in
                for (i, v) in pts.enumerated() {
                    let x = pts.count <= 1 ? geo.size.width / 2 : geo.size.width * CGFloat(i) / CGFloat(pts.count - 1)
                    let clamped = min(max(v, 0), maxV)
                    let y = inset + h * (1 - CGFloat(clamped / maxV))
                    i == 0 ? p.move(to: CGPoint(x: x, y: y)) : p.addLine(to: CGPoint(x: x, y: y))
                }
            }.stroke(color, lineWidth: lineWidth)
        }
    }
    private func downsample(_ v: [Double], to n: Int) -> [Double] {
        guard v.count > n else { return v }
        let strideLen = Double(v.count) / Double(n)
        return (0..<n).map { v[min(v.count - 1, Int(Double($0) * strideLen))] }
    }
}
