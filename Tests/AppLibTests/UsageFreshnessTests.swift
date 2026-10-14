import Testing
import Foundation
import Shared
@testable import AppLib

/// #45 (staleness slice) — pins the freshness age string + stale threshold so an
/// idle session's pinned usage (and the #86 ETA derived from it) is flagged, not
/// shown as live.
struct UsageFreshnessTests {
    private static let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private static func ago(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(-seconds) }

    @Test func ageStringBuckets() {
        #expect(UsageFreshness.ageString(now: Self.t0, lastUpdated: Self.ago(10)) == "just now")
        #expect(UsageFreshness.ageString(now: Self.t0, lastUpdated: Self.ago(59)) == "just now")
        #expect(UsageFreshness.ageString(now: Self.t0, lastUpdated: Self.ago(60)) == "1m ago")
        #expect(UsageFreshness.ageString(now: Self.t0, lastUpdated: Self.ago(23 * 60)) == "23m ago")
        #expect(UsageFreshness.ageString(now: Self.t0, lastUpdated: Self.ago(60 * 60)) == "1h ago")
        #expect(UsageFreshness.ageString(now: Self.t0, lastUpdated: Self.ago(5 * 3600)) == "5h ago")
        #expect(UsageFreshness.ageString(now: Self.t0, lastUpdated: Self.ago(26 * 3600)) == "1d ago")
    }

    @Test func staleThreshold() {
        // Fresh just under 15 min; stale at/after.
        #expect(UsageFreshness.isStale(now: Self.t0, lastUpdated: Self.ago(14 * 60)) == false)
        #expect(UsageFreshness.isStale(now: Self.t0, lastUpdated: Self.ago(15 * 60)) == true)
        #expect(UsageFreshness.isStale(now: Self.t0, lastUpdated: Self.ago(60 * 60)) == true)
    }

    @Test func ageClampsNegativeToJustNow() {
        // A lastUpdated slightly in the future (clock skew) must not underflow.
        #expect(UsageFreshness.ageString(now: Self.t0, lastUpdated: Self.t0.addingTimeInterval(5)) == "just now")
    }
}

struct QuotaReadingPresentationTests {
    let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func prefixesOnlyStaleReadingsAndExplainsAge() {
        let fresh = QuotaReadingPresentation(text: "42%", lastUpdated: now.addingTimeInterval(-899), now: now)
        #expect(fresh.text == "42%")
        let stale = QuotaReadingPresentation(text: "42%", lastUpdated: now.addingTimeInterval(-900), now: now)
        #expect(stale.text == "~42%")
        #expect(stale.help == "last updated 15m ago")
        #expect(QuotaReadingPresentation(text: "limit reached", lastUpdated: now.addingTimeInterval(-1200), now: now).text == "~limit reached")
    }

    @Test func missingAndFutureDatesStayHonest() {
        let unknown = QuotaReadingPresentation(text: "42%", lastUpdated: nil, now: now)
        #expect(unknown.text == "42%")
        #expect(unknown.help == "last update unavailable")
        #expect(QuotaReadingPresentation(text: "42%", lastUpdated: now.addingTimeInterval(60), now: now).text == "42%")
    }

    @Test func eachAgentKeepsItsOwnFreshness() {
        var snapshot = UsageTracker.Snapshot.empty
        snapshot.lastUpdated = now.addingTimeInterval(-1800)
        snapshot.codexLastUpdated = now
        #expect(QuotaReadingPresentation(text: "20% left", lastUpdated: snapshot.quotaLastUpdated(for: .claude), now: now).text == "~20% left")
        #expect(QuotaReadingPresentation(text: "80% used", lastUpdated: snapshot.quotaLastUpdated(for: .codex), now: now).text == "80% used")
    }
}
