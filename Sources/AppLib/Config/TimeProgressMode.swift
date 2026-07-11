import Foundation

/// How elapsed quota-window time is drawn over the existing usage track.
public enum TimeProgressMode: String, Codable, CaseIterable, Sendable {
    case off
    case icon
    case overlap

    public var displayName: String {
        switch self {
        case .off: return "Off"
        case .icon: return "Icon"
        case .overlap: return "Overlap"
        }
    }
}
