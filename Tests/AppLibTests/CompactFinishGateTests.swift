import Testing
import Foundation
@testable import AppLib

/// #181 — decide whether a PostCompact event should fire the "compact
/// finished" notification. Manual /compact only: auto-compact happens
/// mid-turn and the turn's own Stop notification follows anyway.
struct CompactFinishGateTests {

    @Test func manualTriggerOnEventNotifies() {
        #expect(CompactFinishGate.shouldNotify(
            eventTrigger: "manual", storedTrigger: nil, isReplayed: false))
    }

    @Test func manualTriggerFromStoredPreCompactNotifies() {
        // PostCompact payload without trigger — fall back to what PreCompact
        // stored on the session.
        #expect(CompactFinishGate.shouldNotify(
            eventTrigger: nil, storedTrigger: "manual", isReplayed: false))
    }

    @Test func eventTriggerWinsOverStoredTrigger() {
        // A stale stored "manual" must not promote an auto compaction.
        #expect(!CompactFinishGate.shouldNotify(
            eventTrigger: "auto", storedTrigger: "manual", isReplayed: false))
    }

    @Test func autoCompactionStaysSilent() {
        #expect(!CompactFinishGate.shouldNotify(
            eventTrigger: "auto", storedTrigger: nil, isReplayed: false))
        #expect(!CompactFinishGate.shouldNotify(
            eventTrigger: nil, storedTrigger: "auto", isReplayed: false))
    }

    @Test func unknownTriggerStaysSilent() {
        // No trigger anywhere → can't prove it was manual → no chime.
        #expect(!CompactFinishGate.shouldNotify(
            eventTrigger: nil, storedTrigger: nil, isReplayed: false))
    }

    @Test func replayedEventNeverNotifies() {
        // #89 spool replay — the compaction finished while the app was closed.
        #expect(!CompactFinishGate.shouldNotify(
            eventTrigger: "manual", storedTrigger: nil, isReplayed: true))
    }
}
