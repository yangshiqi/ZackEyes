import SwiftUI

enum PressureLevel: Equatable {
    case activity
    case attention
    case critical
}

enum UsagePressure {
    static let attentionThreshold = 50.0
    static let criticalThreshold = 85.0

    static func level(for usedPct: Double) -> PressureLevel {
        switch usedPct {
        case ..<attentionThreshold: return .activity
        case ..<criticalThreshold: return .attention
        default: return .critical
        }
    }
}

enum ContextPressure {
    static let attentionThreshold = 60.0
    static let criticalThreshold = 85.0

    static func level(for usedPct: Double) -> PressureLevel {
        switch usedPct {
        case ..<attentionThreshold: return .activity
        case ..<criticalThreshold: return .attention
        default: return .critical
        }
    }
}

extension Color {
    /// Shared traffic-light color scale used by every usage indicator
    /// (5h/7d progress bars in the expanded panel, remaining-% chips in
    /// the compact pill, matching simulated-notch). Thresholds match
    /// Anthropic's rate-limit warning levels: Activity well below quota,
    /// Attention as it gets tight, and Critical when nearly out.
    static func usageLevelColor(usedPct: Double) -> Color {
        switch UsagePressure.level(for: usedPct) {
        case .activity: return AppColors.activity.color
        case .attention: return AppColors.attention.color
        case .critical: return AppColors.critical.color
        }
    }

    /// Critical color used for an exhausted / "limit reached" usage cell.
    /// Matches the top of the pressure scale and the session error banner so a
    /// blocked agent reads consistently across the app.
    static let usageLimitRed = AppColors.critical.color
}
