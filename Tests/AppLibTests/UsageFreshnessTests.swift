import Testing
import Foundation
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
