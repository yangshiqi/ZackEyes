import AppKit
import Shared

/// Pure logic for picking the menu-bar star color from current sessions +
/// rate-limit data. Extracted from `MenuBarFallback` so it's unit-testable
/// without spinning up AppKit.
///
/// **Rule** (issue #27): the star color encodes the 5-hour subscriber-window
/// usage of whichever agent the user is currently working with —
///   <50% used → teal  (plenty of headroom)
///   <85% used → orange (tight)
///   ≥85% used → red    (about to throttle)
/// When no rate-limit data is available the star falls back to white.
///
/// "Currently working" mirrors `SessionStore.primarySession`'s priority
/// (pendingPermission > working/waiting > most recent). When that agent has
/// no quota data we fall back to the *other* agent before giving up — any
/// real signal beats a blank star.
public enum MenuBarIconColor {
    /// Resolve which agent's 5h pct should drive the color, given the
    /// primary session's agent (if any) and the current snapshot.
    /// Returns nil only when neither agent has rate-limit data.
    public static func resolveAgent(
        primaryAgent: AgentKind?,
        snapshot: UsageTracker.Snapshot
    ) -> AgentKind? {
        let preference: [AgentKind]
        if let primary = primaryAgent {
            preference = [primary, primary == .claude ? .codex : .claude]
        } else {
            preference = [.claude, .codex]
        }
        return preference.first { snapshot.fiveHourUsedPct(for: $0) != nil }
    }

    /// Traffic-light tints. RGB matches `Color.usageLevelColor` (SwiftUI
    /// variant used by the notch) so the menu bar and notch never disagree
    /// on what "tight" looks like. The same triad shows up in
    /// NotchViewModel and SimulatedNotchView; unifying across the four
    /// sites needs a shared `(NSColor, Color)` pair on one type — separate
    /// refactor.
    private static let teal   = NSColor(red: 0.31, green: 0.80, blue: 0.77, alpha: 1.0)
    private static let orange = NSColor(red: 0.96, green: 0.65, blue: 0.14, alpha: 1.0)
    private static let red    = NSColor(red: 0.95, green: 0.30, blue: 0.30, alpha: 1.0)

    /// Color for the menu-bar star. White when no agent has quota data.
    public static func tint(
        primaryAgent: AgentKind?,
        snapshot: UsageTracker.Snapshot
    ) -> NSColor {
        guard let agent = resolveAgent(primaryAgent: primaryAgent, snapshot: snapshot),
              let pct = snapshot.fiveHourUsedPct(for: agent) else {
            return .white
        }
        switch pct {
        case ..<50: return teal
        case ..<85: return orange
        default:    return red
        }
    }
}
