import Foundation

/// Whether quota windows show consumed capacity or remaining capacity.
public enum ProgressMode: String, Codable, CaseIterable, Sendable {
    case spent
    case left

    public var displayName: String {
        switch self {
        case .spent: return "Spent"
        case .left: return "Left"
        }
    }
}

/// Direction available when `ProgressMode.left` presents the remaining fill.
public enum LeftProgressDirection: String, Codable, CaseIterable, Sendable {
    case leftToRight
    case rightToLeft
}

public enum TimeOverlayOpacity {
    public static let defaultValue = 0.4

    public static func normalized(_ value: Double) -> Double {
        let clamped = min(1, max(0, value.isFinite ? value : defaultValue))
        return (clamped * 10).rounded() / 10
    }

    /// The one-pixel time boundary and endpoint are intentionally subtler than
    /// the translucent interior. Zero opacity hides all time-overlay marks.
    public static func boundaryOpacity(for overlayOpacity: Double) -> Double {
        let opacity = normalized(overlayOpacity)
        guard opacity > 0 else { return 0 }
        return max(0, opacity - 0.15)
    }
}
