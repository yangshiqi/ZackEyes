import AppKit
import Shared

/// Pure logic for picking the menu-bar star color from current sessions +
/// rate-limit data. Extracted from `MenuBarFallback` so it's unit-testable
/// without spinning up AppKit.
///
/// **Rule** (issue #27): the star color encodes the 5-hour subscriber-window
/// usage of whichever agent the user is currently working with —
///   <50% used → Activity  (plenty of headroom)
///   <85% used → Attention (tight)
///   ≥85% used → Critical  (about to throttle)
/// When no rate-limit data is available the star falls back to white.
///
/// "Currently working" mirrors `SessionStore.primarySession`'s priority
/// (pendingPermission > working/waiting > most recent). When that agent has
/// no quota data we fall back to the *other* agent before giving up — any
/// real signal beats a blank star.
public enum MenuBarIconColor {
    public struct Presentation {
        public let symbolName: String
        public let accessibilityDescription: String
        public let tint: NSColor
    }

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

    /// Color for the menu-bar star. White when no agent has quota data.
    public static func tint(
        primaryAgent: AgentKind?,
        snapshot: UsageTracker.Snapshot
    ) -> NSColor {
        presentation(primaryAgent: primaryAgent, snapshot: snapshot).tint
    }

    /// Menu-bar pressure uses both shape and hue so amber and red are never
    /// the only distinction available to the user.
    public static func presentation(
        primaryAgent: AgentKind?,
        snapshot: UsageTracker.Snapshot
    ) -> Presentation {
        guard let agent = resolveAgent(primaryAgent: primaryAgent, snapshot: snapshot),
              let pct = snapshot.fiveHourUsedPct(for: agent) else {
            return Presentation(
                symbolName: "star",
                accessibilityDescription: "ZackEyes, quota unavailable",
                tint: AppColors.noData.nsColor
            )
        }
        switch UsagePressure.level(for: pct) {
        case .activity:
            return Presentation(
                symbolName: "star.fill",
                accessibilityDescription: "ZackEyes, quota healthy",
                tint: AppColors.activity.nsColor
            )
        case .attention:
            return Presentation(
                symbolName: "exclamationmark.circle.fill",
                accessibilityDescription: "ZackEyes, quota elevated",
                tint: AppColors.attention.nsColor
            )
        case .critical:
            return Presentation(
                symbolName: "exclamationmark.triangle.fill",
                accessibilityDescription: "ZackEyes, quota critical",
                tint: AppColors.critical.nsColor
            )
        }
    }
}
