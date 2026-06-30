import SwiftUI

struct Sparkline: View {
    let values: [Double]            // already 0...1 normalized OR raw; see normalize
    var color: Color = .green
    var body: some View {
        GeometryReader { geo in
            let pts = downsample(values, to: 80)
            let maxV = max(pts.max() ?? 1, 0.0001)
            Path { p in
                for (i, v) in pts.enumerated() {
                    let x = pts.count <= 1 ? 0 : geo.size.width * CGFloat(i) / CGFloat(pts.count - 1)
                    let y = geo.size.height * (1 - CGFloat(v / maxV))
                    i == 0 ? p.move(to: CGPoint(x: x, y: y)) : p.addLine(to: CGPoint(x: x, y: y))
                }
            }.stroke(color, lineWidth: 1.5)
        }
    }
    private func downsample(_ v: [Double], to n: Int) -> [Double] {
        guard v.count > n else { return v }
        let strideLen = Double(v.count) / Double(n)
        return (0..<n).map { v[min(v.count - 1, Int(Double($0) * strideLen))] }
    }
}
