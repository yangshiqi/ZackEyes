import SwiftUI

extension Color {
    /// Shared traffic-light color scale used by every usage indicator
    /// (5h/7d progress bars in the expanded panel, remaining-% chips in
    /// the compact pill, matching simulated-notch). Thresholds match
    /// Anthropic's rate-limit warning levels: green well below quota,
    /// orange as it gets tight, red when nearly out.
    static func usageLevelColor(usedPct: Double) -> Color {
        switch usedPct {
        case ..<50: return Color(red: 0.31, green: 0.80, blue: 0.77)  // teal
        case ..<85: return Color(red: 0.96, green: 0.65, blue: 0.14)  // orange
        default:    return Color(red: 0.95, green: 0.30, blue: 0.30)  // red
        }
    }
}
