/// Tracks one pending hover intent and invalidates delayed callbacks safely.
///
/// The tracker is deliberately independent of AppKit and wall-clock time. The
/// controllers own the delay and geometry checks; this type only guarantees
/// that duplicate mouse-move events do not restart the dwell timer and that a
/// callback scheduled before cancellation can no longer expand the panel.
import Foundation

public struct HoverIntentTracker: Sendable {
    public typealias Token = UInt64

    private var generation: Token = 0
    public private(set) var pendingToken: Token?
    private var anchor: CGPoint?

    public init() {}

    /// Observes a pointer location. A new token is returned on first entry or
    /// after movement beyond the tolerance; nil means the existing dwell may
    /// continue without restarting its timer.
    public mutating func observe(
        _ location: CGPoint,
        movementTolerance: CGFloat
    ) -> Token? {
        if let anchor, pendingToken != nil {
            let dx = location.x - anchor.x
            let dy = location.y - anchor.y
            if dx * dx + dy * dy <= movementTolerance * movementTolerance {
                return nil
            }
        }

        generation &+= 1
        pendingToken = generation
        anchor = location
        return generation
    }

    /// Invalidates the current candidate and every callback issued before it.
    public mutating func cancel() {
        generation &+= 1
        pendingToken = nil
        anchor = nil
    }

    /// Consumes a still-current candidate exactly once.
    public mutating func consume(_ token: Token) -> Bool {
        guard pendingToken == token else { return false }
        pendingToken = nil
        anchor = nil
        return true
    }
}
