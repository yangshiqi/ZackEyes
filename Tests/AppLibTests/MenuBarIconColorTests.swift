import Testing
import AppKit
@testable import AppLib
import Shared

/// Color rules for the menu-bar star (issue #27). Pure functions of
/// (primary agent, snapshot) → NSColor / AgentKind, so we can pin the rule
/// down without spinning AppKit.
@MainActor
struct MenuBarIconColorTests {

    private func snapshot(claude: Double? = nil, codex: Double? = nil) -> UsageTracker.Snapshot {
        var s = UsageTracker.Snapshot.empty
        s.fiveHourUsedPct = claude
        s.codexFiveHourUsedPct = codex
        return s
    }

    private func rgb(_ color: NSColor) -> (Double, Double, Double) {
        // Palette colors come back tagged sRGB; convertedColor would also work
        // but going via components avoids any subtle gamma round-trip.
        let c = color.usingColorSpace(.sRGB) ?? color
        return (Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent))
    }

    private func approxEqual(_ a: (Double, Double, Double), _ b: (Double, Double, Double)) -> Bool {
        abs(a.0 - b.0) < 0.01 && abs(a.1 - b.1) < 0.01 && abs(a.2 - b.2) < 0.01
    }

    // MARK: - resolveAgent

    @Test func resolveAgentReturnsPrimaryWhenItHasData() {
        let snap = snapshot(claude: 30, codex: 80)
        #expect(MenuBarIconColor.resolveAgent(primaryAgent: .codex, snapshot: snap) == .codex)
        #expect(MenuBarIconColor.resolveAgent(primaryAgent: .claude, snapshot: snap) == .claude)
    }

    @Test func resolveAgentFallsBackToOtherWhenPrimaryMissing() {
        // primary is codex but only claude has data → use claude
        let snap = snapshot(claude: 42, codex: nil)
        #expect(MenuBarIconColor.resolveAgent(primaryAgent: .codex, snapshot: snap) == .claude)
    }

    @Test func resolveAgentNilWhenNoData() {
        let snap = snapshot(claude: nil, codex: nil)
        #expect(MenuBarIconColor.resolveAgent(primaryAgent: .claude, snapshot: snap) == nil)
        #expect(MenuBarIconColor.resolveAgent(primaryAgent: nil, snapshot: snap) == nil)
    }

    @Test func resolveAgentDefaultsClaudeFirstWhenNoPrimary() {
        // No active session, both have data → claude wins (matches the
        // "claude is the canonical agent for legacy entries" convention).
        let snap = snapshot(claude: 10, codex: 90)
        #expect(MenuBarIconColor.resolveAgent(primaryAgent: nil, snapshot: snap) == .claude)
    }

    // MARK: - tint

    @Test func tintTealUnder50() {
        let tint = MenuBarIconColor.tint(primaryAgent: .claude, snapshot: snapshot(claude: 49.9))
        #expect(approxEqual(rgb(tint), (0.31, 0.80, 0.77)))
    }

    @Test func tintOrangeBetween50And85() {
        let tint = MenuBarIconColor.tint(primaryAgent: .claude, snapshot: snapshot(claude: 70))
        #expect(approxEqual(rgb(tint), (0.96, 0.65, 0.14)))
    }

    @Test func tintRedAt85AndAbove() {
        let tint = MenuBarIconColor.tint(primaryAgent: .claude, snapshot: snapshot(claude: 85))
        #expect(approxEqual(rgb(tint), (0.95, 0.30, 0.30)))
        let extreme = MenuBarIconColor.tint(primaryAgent: .claude, snapshot: snapshot(claude: 99))
        #expect(approxEqual(rgb(extreme), (0.95, 0.30, 0.30)))
    }

    @Test func tintWhiteWhenNoData() {
        let tint = MenuBarIconColor.tint(primaryAgent: .claude, snapshot: snapshot())
        // .white is calibrated, so map through sRGB before comparing.
        let comps = rgb(tint)
        #expect(comps.0 > 0.99 && comps.1 > 0.99 && comps.2 > 0.99)
    }

    @Test func tintFollowsActiveAgentWhenBothRunning() {
        // Issue #27 acceptance criterion: claude at 30% (teal), codex at 90% (red).
        // If codex is the active agent the star is red, not teal.
        let snap = snapshot(claude: 30, codex: 90)
        let codexTint = MenuBarIconColor.tint(primaryAgent: .codex, snapshot: snap)
        #expect(approxEqual(rgb(codexTint), (0.95, 0.30, 0.30)))

        let claudeTint = MenuBarIconColor.tint(primaryAgent: .claude, snapshot: snap)
        #expect(approxEqual(rgb(claudeTint), (0.31, 0.80, 0.77)))
    }
}
