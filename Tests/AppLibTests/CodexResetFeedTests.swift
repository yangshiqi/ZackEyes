import Foundation
import Testing
@testable import AppLib

struct CodexResetFeedTests {
    private let now = ISO8601DateFormatter().date(from: "2026-10-23T06:00:00Z")!

    @Test func scheduledInstantStaysSeparateFromAccountQuota() throws {
        let notice = try #require(CodexResetFeed.latest(from: fixture(
            scheduled: """
            {"certainty":"announced","day":"2026-10-24","scheduled_for":"2026-10-23T17:00:00Z","when_text":"before 10am Pacific","url":"https://x.com/thsottiaux/status/123","source":"@thsottiaux","announced_at":"2026-10-23T05:00:00Z"}
            """
        ), now: now))
        #expect(notice.kind == .automatic)
        #expect(notice.phase == .scheduled)
        #expect(notice.expectedAt == ISO8601DateFormatter().date(from: "2026-10-23T17:00:00Z"))
        #expect(notice.sourceURL.absoluteString == "https://x.com/thsottiaux/status/123")
        #expect(notice.notificationKey == "https://x.com/thsottiaux/status/123:scheduled")
        #expect(notice.countdown(at: now) == "in 11h")
    }

    @Test func dayOnlyScheduleDoesNotInventClockTime() throws {
        let notice = try #require(CodexResetFeed.latest(from: fixture(
            scheduled: """
            {"certainty":"announced","day":"2026-10-24","scheduled_for":null,"when_text":"Tomorrow before 10am Pacific","url":"https://x.com/thsottiaux/status/123","announced_at":"2026-10-23T05:00:00Z"}
            """
        ), now: now))
        #expect(notice.expectedAt == nil)
        #expect(notice.expectedDay == "2026-10-24")
        #expect(notice.expectedWindowText == "Tomorrow before 10am Pacific")
        #expect(notice.countdown(at: now) == nil)
    }

    @Test func recentBankedEventIsNotAnAutomaticReset() throws {
        let notice = try #require(CodexResetFeed.latest(from: fixture(events: """
            [{"id":"456","kind":"banked","scope":"paid","url":"https://x.com/thsottiaux/status/456","announced_at":"2026-10-23T04:00:00Z","delivered_at":null,"seeded":false}]
            """), now: now))
        #expect(notice.kind == .banked)
        #expect(notice.phase == .announced)
        #expect(notice.scope == "Paid plans")
    }

    @Test func deliveryIsReportedButNeverClaimedForThisAccount() throws {
        let notice = try #require(CodexResetFeed.latest(from: fixture(events: """
            [{"id":"456","kind":"regular","scope":"all","url":"https://x.com/thsottiaux/status/456","announced_at":"2026-10-23T04:00:00Z","delivered_at":"2026-10-23T05:30:00Z","seeded":false}]
            """), now: now))
        #expect(notice.phase == .reportedComplete)
        #expect(notice.reportedDeliveredAt == ISO8601DateFormatter().date(from: "2026-10-23T05:30:00Z"))
        #expect(notice.notificationKey.hasSuffix(":reportedComplete"))
    }

    @Test func newlyReportedCompletionBeatsNewerOldAnnouncement() throws {
        let notice = try #require(CodexResetFeed.latest(from: fixture(events: """
            [
              {"kind":"regular","scope":"paid","url":"https://x.com/thsottiaux/status/111","announced_at":"2026-10-23T01:00:00Z","delivered_at":"2026-10-23T05:50:00Z","seeded":false},
              {"kind":"regular","scope":"paid","url":"https://x.com/thsottiaux/status/222","announced_at":"2026-10-23T04:00:00Z","delivered_at":null,"seeded":false}
            ]
            """), now: now))
        #expect(notice.sourceURL.absoluteString.hasSuffix("/111"))
        #expect(notice.phase == .reportedComplete)
    }

    @Test func reportedCompletionBeatsAnOlderScheduledNotice() throws {
        let notice = try #require(CodexResetFeed.latest(from: fixture(
            scheduled: """
            {"certainty":"announced","day":"2026-10-23","scheduled_for":"2026-10-23T07:00:00Z","url":"https://x.com/thsottiaux/status/123","announced_at":"2026-10-23T02:00:00Z"}
            """,
            events: """
            [{"kind":"regular","scope":"all","url":"https://x.com/thsottiaux/status/123","announced_at":"2026-10-23T02:00:00Z","delivered_at":"2026-10-23T05:30:00Z","seeded":false}]
            """
        ), now: now))
        #expect(notice.phase == .reportedComplete)
    }

    @Test func lateCompletionCanNotifyButElapsedScheduleCannot() throws {
        let later = ISO8601DateFormatter().date(from: "2026-10-23T12:00:00Z")!
        let completed = try #require(CodexResetFeed.latest(from: fixture(
            events: """
            [{"kind":"regular","scope":"all","url":"https://x.com/thsottiaux/status/456","announced_at":"2026-10-23T02:00:00Z","delivered_at":"2026-10-23T11:50:00Z","seeded":false}]
            """,
            generatedAt: "2026-10-23T11:55:00Z"
        ), now: later))
        #expect(CodexResetAlertPolicy.shouldNotify(completed, activeCodex: true, enabled: true,
            notificationsEnabled: true, lastKey: nil, now: later))

        let elapsed = try #require(CodexResetFeed.latest(from: fixture(
            scheduled: """
            {"certainty":"announced","day":"2026-10-23","scheduled_for":"2026-10-23T05:30:00Z","url":"https://x.com/thsottiaux/status/789","announced_at":"2026-10-23T05:00:00Z"}
            """
        ), now: now))
        #expect(!CodexResetAlertPolicy.shouldNotify(elapsed, activeCodex: true, enabled: true,
            notificationsEnabled: true, lastKey: nil, now: now))
    }

    @Test func staleOrUnsupportedRecordsAreIgnored() {
        #expect(CodexResetFeed.latest(from: fixture(generatedAt: "2026-10-22T00:00:00Z"), now: now) == nil)
        #expect(CodexResetFeed.latest(from: fixture(scheduled: """
            {"certainty":"hinted","day":"2026-10-24","url":"https://x.com/thsottiaux/status/123","announced_at":"2026-10-23T05:00:00Z"}
            """), now: now) == nil)
        #expect(CodexResetFeed.latest(from: fixture(events: """
            [{"id":"456","kind":"regular","scope":"all","url":"https://evil.example/status/456","announced_at":"2026-10-23T04:00:00Z"}]
            """), now: now) == nil)
    }

    @Test func notificationGateUsesActivityAndPersistentIdentity() throws {
        let notice = try #require(CodexResetFeed.latest(from: fixture(
            scheduled: """
            {"certainty":"announced","day":"2026-10-24","scheduled_for":"2026-10-23T17:00:00Z","url":"https://x.com/thsottiaux/status/123","announced_at":"2026-10-23T05:00:00Z"}
            """
        ), now: now))
        #expect(!CodexResetAlertPolicy.shouldNotify(notice, activeCodex: false, enabled: true, notificationsEnabled: true, lastKey: nil, now: now))
        #expect(!CodexResetAlertPolicy.shouldNotify(notice, activeCodex: true, enabled: false, notificationsEnabled: true, lastKey: nil, now: now))
        #expect(!CodexResetAlertPolicy.shouldNotify(notice, activeCodex: true, enabled: true, notificationsEnabled: false, lastKey: nil, now: now))
        #expect(CodexResetAlertPolicy.shouldNotify(notice, activeCodex: true, enabled: true, notificationsEnabled: true, lastKey: nil, now: now))
        #expect(!CodexResetAlertPolicy.shouldNotify(notice, activeCodex: true, enabled: true, notificationsEnabled: true, lastKey: notice.notificationKey, now: now))
    }

    private func fixture(scheduled: String = "null", events: String = "[]", generatedAt: String = "2026-10-23T05:55:00Z") -> Data {
        Data("""
        {"schema_version":1,"generated_at":"\(generatedAt)","scheduled":\(scheduled),"events":\(events)}
        """.utf8)
    }
}

extension CodexResetFeedTests {
    @Test func originalPostSurvivesWithoutResetTime() throws {
        let original = String(repeating: "Original wording — not a guessed reset time. ", count: 12)
        let json = try JSONSerialization.data(withJSONObject: [
            "schema_version": 1, "generated_at": "2026-10-23T05:55:00Z",
            "events": [["kind": "regular", "url": "https://x.com/thsottiaux/status/123",
                        "announced_at": "2026-10-23T05:00:00Z", "summary": original]]
        ])
        let notice = try #require(CodexResetFeed.latest(from: json, now: now))
        #expect(notice.originalText == original.trimmingCharacters(in: .whitespacesAndNewlines))
        #expect(CodexResetNoticeView(announcement: notice).header(at: now) == "Extra Codex reset - Reset time not announced")
    }

    @Test func scheduledHeaderAndOriginalUseTheSameSource() throws {
        let notice = try #require(CodexResetFeed.latest(from: fixture(
            scheduled: """
            {"certainty":"announced","day":"2026-10-23","scheduled_for":"2026-10-23T07:00:00Z","url":"https://x.com/thsottiaux/status/123","announced_at":"2026-10-23T05:00:00Z"}
            """, events: """
            [{"kind":"regular","url":"https://x.com/thsottiaux/status/123","announced_at":"2026-10-23T05:00:00Z","summary":"Reset announcement original."},
             {"kind":"regular","url":"https://x.com/thsottiaux/status/456","announced_at":"2026-10-23T04:00:00Z","summary":"Unrelated announcement."}]
            """), now: now))
        #expect(notice.originalText == "Reset announcement original.")
        let header = CodexResetNoticeView(announcement: notice).header(at: now)
        #expect(header.hasPrefix("Extra Codex reset - Expected "))
        #expect(header.contains("UTC"))
        #expect(header.contains("in 1h"))
    }

    @Test func missingOrUnavailableOriginalIsNotInvented() throws {
        for event in [
            #"{"kind":"regular","url":"https://x.com/thsottiaux/status/123","announced_at":"2026-10-23T05:00:00Z"}"#,
            #"{"kind":"regular","url":"https://x.com/thsottiaux/status/123","announced_at":"2026-10-23T05:00:00Z","summary":"   "}"#,
            #"{"kind":"regular","url":"https://x.com/thsottiaux/status/123","announced_at":"2026-10-23T05:00:00Z","summary":"Placeholder","summary_unavailable":true}"#
        ] {
            let notice = try #require(CodexResetFeed.latest(from: fixture(events: "[\(event)]"), now: now))
            #expect(notice.originalText == nil)
        }
    }
}
