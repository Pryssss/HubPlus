import Foundation

struct BurnProjection: Equatable { let hoursLeft: Double; let label: String }

/// Projects time-to-limit from recent usage samples. Pure + unit-tested.
enum BurnRate {
    static func project(_ samples: [(t: Double, util: Double)], now: Double, window: Double = 1800) -> BurnProjection? {
        var win = samples.filter { now - $0.t <= window }.sorted { $0.t < $1.t }
        // If the window reset (utilization dropped), project only from the post-reset
        // climb — keep the samples after the most recent decrease.
        for i in stride(from: win.count - 1, through: 1, by: -1) where win[i].util < win[i - 1].util {
            win = Array(win[i...]); break
        }
        guard win.count >= 2, let first = win.first, let last = win.last else { return nil }
        // Center timestamps on the first sample: raw epoch values (~1.75e9) in the
        // least-squares normal equations cause catastrophic cancellation.
        let t0 = first.t
        let slopePerSec: Double
        if win.count >= 3 {
            let n = Double(win.count)
            let xs = win.map { $0.t - t0 }
            let ys = win.map { $0.util }
            let sx = xs.reduce(0, +)
            let sy = ys.reduce(0, +)
            let sxx = xs.reduce(0) { $0 + $1 * $1 }
            let sxy = zip(xs, ys).reduce(0) { $0 + $1.0 * $1.1 }
            let denom = n * sxx - sx * sx
            guard denom != 0 else { return nil }
            slopePerSec = (n * sxy - sx * sy) / denom
        } else {
            let dt = last.t - first.t
            guard dt > 0 else { return nil }
            slopePerSec = (last.util - first.util) / dt
        }
        let perHour = slopePerSec * 3600
        guard perHour > 0.0001 else { return nil }               // not burning
        let hoursLeft = (100 - last.util) / perHour
        guard hoursLeft > 0, hoursLeft <= 48 else { return nil }  // beyond 48h the pace is negligible
        return BurnProjection(hoursLeft: hoursLeft, label: label(hoursLeft))
    }

    static func label(_ hours: Double) -> String {
        if hours >= 1 { return "~\(Int(hours))h" }
        return "~\(Int((hours * 60).rounded()))m"
    }
}
