import Foundation

struct BurnProjection: Equatable { let hoursLeft: Double; let label: String }

/// Projects time-to-limit from recent usage samples. Pure + unit-tested.
enum BurnRate {
    static func project(_ samples: [(t: Double, util: Double)], now: Double, window: Double = 1800) -> BurnProjection? {
        let win = samples.filter { now - $0.t <= window }.sorted { $0.t < $1.t }
        guard win.count >= 2, let first = win.first, let last = win.last else { return nil }
        if last.util < first.util { return nil }                 // reset guard
        // least-squares slope (util per second), fall back to first/last for <3
        let slopePerSec: Double
        if win.count >= 3 {
            let n = Double(win.count)
            let sx = win.reduce(0) { $0 + $1.t }
            let sy = win.reduce(0) { $0 + $1.util }
            let sxx = win.reduce(0) { $0 + $1.t * $1.t }
            let sxy = win.reduce(0) { $0 + $1.t * $1.util }
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
        let hoursLeft = max(0, (100 - last.util) / perHour)
        return BurnProjection(hoursLeft: hoursLeft, label: label(hoursLeft))
    }

    static func label(_ hours: Double) -> String {
        if hours >= 1 { return "~\(Int(hours))h" }
        return "~\(Int((hours * 60).rounded()))m"
    }
}
