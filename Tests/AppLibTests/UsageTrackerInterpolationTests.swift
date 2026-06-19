import Testing
@testable import AppLib

/// #116 — between-hook 5h% interpolation scales the last real reading by
/// transcript token growth so a long burst (a Workflow fan-out) moves
/// continuously instead of freezing until the next hook then snapping.
struct UsageTrackerInterpolationTests {

    @Test func scalesWithTokenGrowth() {
        // 50% at 1000 tokens implies a 2000-token budget; at 1500 tokens → 75%.
        #expect(UsageTracker.interpolatedFiveHourPct(
            anchorPct: 50, anchorTokens: 1000, currentTokens: 1500, floor: 50) == 75)
    }

    @Test func capsAt100() {
        #expect(UsageTracker.interpolatedFiveHourPct(
            anchorPct: 80, anchorTokens: 1000, currentTokens: 5000, floor: 80) == 100)
    }

    // Codex review #145: the rolling token window can dip; the monotonic floor
    // (last displayed value) must hold so the % never moves backwards mid-turn.
    @Test func floorKeepsItMonotonic() {
        // raw would be 60×1100/1000 = 66, but the last displayed 72 floors it.
        #expect(UsageTracker.interpolatedFiveHourPct(
            anchorPct: 60, anchorTokens: 1000, currentTokens: 1100, floor: 72) == 72)
    }

    @Test func nilWhenTokensDidNotGrow() {
        // No new tokens past the baseline → keep the last displayed value (nil).
        #expect(UsageTracker.interpolatedFiveHourPct(
            anchorPct: 50, anchorTokens: 1000, currentTokens: 1000, floor: 50) == nil)
        #expect(UsageTracker.interpolatedFiveHourPct(
            anchorPct: 50, anchorTokens: 1000, currentTokens: 900, floor: 50) == nil)
    }

    @Test func nilWithoutUsableAnchor() {
        #expect(UsageTracker.interpolatedFiveHourPct(
            anchorPct: nil, anchorTokens: 1000, currentTokens: 1500, floor: 0) == nil)
        #expect(UsageTracker.interpolatedFiveHourPct(
            anchorPct: 50, anchorTokens: nil, currentTokens: 1500, floor: 50) == nil)
        #expect(UsageTracker.interpolatedFiveHourPct(
            anchorPct: 50, anchorTokens: 0, currentTokens: 1500, floor: 50) == nil)
        #expect(UsageTracker.interpolatedFiveHourPct(
            anchorPct: 0, anchorTokens: 1000, currentTokens: 1500, floor: 0) == nil)
    }
}
