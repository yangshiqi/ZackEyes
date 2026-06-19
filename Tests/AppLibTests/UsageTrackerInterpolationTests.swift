import Testing
@testable import AppLib

/// #116 — between-hook 5h% interpolation scales the last real reading by
/// transcript token growth so a long burst (a Workflow fan-out) moves
/// continuously instead of freezing until the next hook then snapping.
struct UsageTrackerInterpolationTests {

    @Test func scalesWithTokenGrowth() {
        // 50% at 1000 tokens implies a 2000-token budget; at 1500 tokens → 75%.
        #expect(UsageTracker.interpolatedFiveHourPct(
            anchorPct: 50, anchorTokens: 1000, currentTokens: 1500) == 75)
    }

    @Test func capsAt100() {
        #expect(UsageTracker.interpolatedFiveHourPct(
            anchorPct: 80, anchorTokens: 1000, currentTokens: 5000) == 100)
    }

    @Test func nilWhenTokensDidNotGrow() {
        // No new tokens → keep the real reading (nil = don't override).
        #expect(UsageTracker.interpolatedFiveHourPct(
            anchorPct: 50, anchorTokens: 1000, currentTokens: 1000) == nil)
        #expect(UsageTracker.interpolatedFiveHourPct(
            anchorPct: 50, anchorTokens: 1000, currentTokens: 900) == nil)
    }

    @Test func nilWithoutUsableAnchor() {
        #expect(UsageTracker.interpolatedFiveHourPct(
            anchorPct: nil, anchorTokens: 1000, currentTokens: 1500) == nil)
        #expect(UsageTracker.interpolatedFiveHourPct(
            anchorPct: 50, anchorTokens: nil, currentTokens: 1500) == nil)
        #expect(UsageTracker.interpolatedFiveHourPct(
            anchorPct: 50, anchorTokens: 0, currentTokens: 1500) == nil)
        #expect(UsageTracker.interpolatedFiveHourPct(
            anchorPct: 0, anchorTokens: 1000, currentTokens: 1500) == nil)
    }
}
