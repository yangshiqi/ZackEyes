import SwiftUI

extension Color {
    /// Shared traffic-light color scale used by every usage indicator
    /// (5h/7d progress bars in the expanded panel, remaining-% chips in
    /// the compact pill, matching simulated-notch). Thresholds match
    /// Anthropic's rate-limit warning levels: Activity well below quota,
    /// Attention as it gets tight, and Critical when nearly out.
    static func usageLevelColor(usedPct: Double) -> Color {
        switch usedPct {
        case ..<50: return AppColors.activity.color
        case ..<85: return AppColors.attention.color
        default:    return AppColors.critical.color
        }
    }

    /// Critical color used for an exhausted / "limit reached" usage cell.
    /// Matches the top of the pressure scale and the session error banner so a
    /// blocked agent reads consistently across the app.
    static let usageLimitRed = AppColors.critical.color
}
