import Testing
import Foundation
import Shared
@testable import AppLib

/// #205 item 3 — the trace exists to answer "why didn't my notification pop?",
/// so these test the two properties that make it trustworthy: it stays bounded,
/// and it never quietly claims something it doesn't know.
@MainActor
struct EventTraceTests {

    private func trace(_ n: Int, from: Int = 0) -> EventTrace {
        let t = EventTrace()
        for i in from..<(from + n) {
            t.record(
                agent: "claude", event: "PreToolUse", tool: "Bash",
                session: "sess\(i)", replayed: false,
                at: Date(timeIntervalSince1970: 1_700_000_000 + Double(i))
            )
        }
        return t
    }

    @Test func keepsTheNewestEntriesAndEvictsTheOldest() {
        let t = trace(EventTrace.capacity + 5)
        #expect(t.entries.count == EventTrace.capacity)
        // The first 5 are gone; the buffer starts at #5 and ends at the newest.
        #expect(t.entries.first?.session == "sess5")
        #expect(t.entries.last?.session == "sess\(EventTrace.capacity + 4)")
    }

    @Test func arrivingEventsStartUnclassified() {
        let t = trace(1)
        #expect(t.entries.first?.disposition == .received)
    }

    @Test func noteClassifiesOnlyTheEventBeingRouted() {
        let t = trace(3)
        t.note(.dropped("no responder"))
        #expect(t.entries[0].disposition == .received)
        #expect(t.entries[1].disposition == .received)
        #expect(t.entries[2].disposition == .dropped("no responder"))
    }

    /// The routing switch refines its verdict as it learns more (applied →
    /// notified), so the last write has to win.
    @Test func noteOverwritesAnEarlierVerdictForTheSameEvent() {
        let t = trace(1)
        t.note(.applied)
        t.note(.notified("finished"))
        #expect(t.entries[0].disposition == .notified("finished"))
    }

    /// A diagnostic aid must never be the thing that crashes the app.
    @Test func noteOnAnEmptyBufferIsHarmless() {
        let t = EventTrace()
        t.note(.applied)
        #expect(t.entries.isEmpty)
    }

    @Test func replayedFlagSurvivesIntoTheEntry() {
        let t = EventTrace()
        t.record(
            agent: "codex", event: "Stop", tool: nil,
            session: "abc", replayed: true
        )
        #expect(t.entries.first?.replayed == true)
    }

    @Test func bridgeEventIsRecordedWithAShortSessionPrefix() throws {
        let json = """
        {"_bridge_event":"Stop","_bridge_agent":"codex",\
        "session_id":"0123456789abcdef","cwd":"/tmp/x"}
        """
        let event = try JSONDecoder().decode(BridgeEvent.self, from: Data(json.utf8))
        let t = EventTrace()
        t.record(event)
        let entry = try #require(t.entries.first)
        #expect(entry.agent == "codex")
        #expect(entry.event == "Stop")
        // Only a prefix — enough to group a turn, useless as an identifier.
        #expect(entry.session == "01234567")
    }
}
