import Foundation

public enum ProgressFillAnchor: Equatable, Sendable {
    case leading
    case trailing
}

/// Pure display conversion shared by quota and elapsed-window progress.
public struct ProgressPresentation: Equatable, Sendable {
    public let fraction: Double
    public let percent: Int
    public let anchor: ProgressFillAnchor
    public let mode: ProgressMode

    public init(spentFraction: Double, mode: ProgressMode, leftDirection: LeftProgressDirection) {
        let spent = min(1, max(0, spentFraction))
        self.mode = mode

        switch mode {
        case .spent:
            fraction = spent
            anchor = .leading
        case .left:
            fraction = 1 - spent
            anchor = leftDirection == .leftToRight ? .leading : .trailing
        }

        percent = Int((fraction * 100).rounded())
    }

    public var explicitLabel: String {
        switch mode {
        case .spent: return "\(percent)% spent"
        case .left: return "\(percent)% remaining"
        }
    }
}
