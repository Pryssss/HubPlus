import Foundation

/// Compact human token counts: "512", "9.4k", "604k", "1.2M", "604M", "1.2B".
/// One decimal below 10× of each unit, integers above; rounding that would
/// print "1000k" promotes to the next unit instead.
enum TokenFormat {
    static func compact(_ n: Int) -> String {
        let v = Double(max(n, 0))
        if v < 999.5 { return "\(max(n, 0))" }
        for (unit, divisor) in [("k", 1e3), ("M", 1e6), ("B", 1e9)] {
            let scaled = v / divisor
            if scaled < 9.95 { return trimmed(scaled, unit) }
            if scaled < 999.5 { return "\(Int(scaled.rounded()))\(unit)" }
        }
        return "\(Int((v / 1e9).rounded()))B"
    }

    /// "9.4k", but "9k" rather than "9.0k".
    private static func trimmed(_ value: Double, _ unit: String) -> String {
        let s = String(format: "%.1f", value)
        return (s.hasSuffix(".0") ? String(s.dropLast(2)) : s) + unit
    }
}
