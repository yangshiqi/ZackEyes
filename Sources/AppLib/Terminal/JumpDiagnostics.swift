import Foundation

/// Why a click-to-jump did not land (#42).
///
/// Clicking a session card used to be able to do nothing at all: the pid path
/// failed, the cwd fallback failed, `activateTerminalDirectly`'s `Bool` was
/// discarded by the caller, and no trace was written. The user saw a click
/// that did nothing and had no way — and gave us no way — to find out why.
///
/// The issue also proposed multi-window/split-pane/cross-Space matching
/// improvements. Those are not here on purpose: they came from a competitor's
/// changelog rather than from a reproducible failure, and speculative
/// matching heuristics are exactly what "复杂度需要证明" is meant to stop. This
/// makes failures observable first, so the next change can be aimed at a real
/// case instead of an imagined one.
public enum JumpFailureReason: String, Sendable, Equatable {
    /// No pid and no cwd — nothing to match a window against.
    case noTarget
    /// Accessibility is not granted, so the AX-driven terminals (Ghostty,
    /// Warp, kitty, WezTerm, VS Code, Cursor) cannot be searched at all.
    /// By far the most actionable cause, and invisible until now.
    case accessibilityDenied
    /// We had a target and permission, but no window matched it.
    case noMatchingWindow

    /// User-facing one-liner. Short enough for a session card.
    public var shortLabel: String {
        switch self {
        case .noTarget:            return "Can't locate this session"
        case .accessibilityDenied: return "Needs Accessibility permission"
        case .noMatchingWindow:    return "Couldn't find its terminal"
        }
    }

    /// The line that goes in the event trace / diagnostics export.
    public var traceLabel: String {
        switch self {
        case .noTarget:            return "jump: no pid and no cwd"
        case .accessibilityDenied: return "jump: accessibility not trusted"
        case .noMatchingWindow:    return "jump: no matching window"
        }
    }
}

public enum JumpDiagnostics {
    /// Classify a failed jump.
    ///
    /// Pure so the ordering is testable: permission is reported ahead of
    /// "no matching window" because when AX is denied the search could not
    /// have succeeded regardless of how good the matching is — reporting the
    /// symptom over the cause would send the user hunting the wrong thing.
    public static func classify(
        hadPid: Bool,
        hadCwd: Bool,
        accessibilityTrusted: Bool
    ) -> JumpFailureReason {
        guard hadPid || hadCwd else { return .noTarget }
        guard accessibilityTrusted else { return .accessibilityDenied }
        return .noMatchingWindow
    }
}
