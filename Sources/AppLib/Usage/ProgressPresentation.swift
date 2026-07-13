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

    public init(usedFraction: Double, mode: ProgressMode, leftDirection: LeftProgressDirection) {
        let used = min(1, max(0, usedFraction))
        self.mode = mode

        switch mode {
        case .used:
            fraction = used
            anchor = .leading
        case .left:
            fraction = 1 - used
            anchor = leftDirection == .leftToRight ? .leading : .trailing
        }

        percent = Int((fraction * 100).rounded())
    }

    public var explicitLabel: String {
        switch mode {
        case .used: return "\(percent)% used"
        case .left: return "\(percent)% remaining"
        }
    }
}
