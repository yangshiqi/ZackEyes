import Foundation

extension Date {
    /// Compact countdown from now to this date, used for rate-limit
    /// reset indicators across every usage surface (expanded usage bars,
    /// compact pill chip, simulated-notch stats). Returns "now" when the
    /// interval is non-positive, days for ≥24h, `Nh Mm` for sub-day
    /// intervals, or just `Mm` otherwise.
    var usageResetDisplay: String {
        let interval = timeIntervalSinceNow
        if interval <= 0 { return "now" }
        let hours = Int(interval) / 3600
        let mins = (Int(interval) % 3600) / 60
        if hours >= 24 { return "\(hours / 24)d" }
        if hours > 0 { return "\(hours)h \(mins)m" }
        return "\(mins)m"
    }
}
