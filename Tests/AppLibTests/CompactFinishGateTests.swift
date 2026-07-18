import Testing
import Foundation
@testable import AppLib

/// #181 — decide whether a PostCompact event should fire the "compact
/// finished" notification. Manual /compact only: auto-compact happens
/// mid-turn and the turn's own Stop notification follows anyway. Replay
/// suppression (#89) lives inline at the AppDelegate call site, matching
/// the error/Stop notification blocks and WaitingAlertGate's caller-owned
/// convention.
struct CompactFinishGateTests {

    @Test func resolvedTrigger_eventWinsOverStored() {
        #expect(CompactFinishGate.resolvedTrigger(
            eventTrigger: "auto", storedTrigger: "manual") == "auto")
        #expect(CompactFinishGate.resolvedTrigger(
            eventTrigger: "manual", storedTrigger: "auto") == "manual")
    }

    @Test func resolvedTrigger_fallsBackToStored() {
        #expect(CompactFinishGate.resolvedTrigger(
            eventTrigger: nil, storedTrigger: "manual") == "manual")
        #expect(CompactFinishGate.resolvedTrigger(
            eventTrigger: nil, storedTrigger: nil) == nil)
    }

    @Test func manualTriggerOnEventNotifies() {
        #expect(CompactFinishGate.shouldNotify(
            eventTrigger: "manual", storedTrigger: nil))
    }

    @Test func manualTriggerFromStoredPreCompactNotifies() {
        // PostCompact payload without trigger — fall back to what PreCompact
        // stored on the session.
        #expect(CompactFinishGate.shouldNotify(
            eventTrigger: nil, storedTrigger: "manual"))
    }

    @Test func eventTriggerWinsOverStoredTrigger() {
        // A stale stored "manual" must not promote an auto compaction.
        #expect(!CompactFinishGate.shouldNotify(
            eventTrigger: "auto", storedTrigger: "manual"))
    }

    @Test func autoCompactionStaysSilent() {
        #expect(!CompactFinishGate.shouldNotify(
            eventTrigger: "auto", storedTrigger: nil))
        #expect(!CompactFinishGate.shouldNotify(
            eventTrigger: nil, storedTrigger: "auto"))
    }

    @Test func unknownTriggerStaysSilent() {
        // No trigger anywhere → can't prove it was manual → no chime.
        // (The SessionStore state flip is deliberately laxer — see
        // postCompactWithUnknownTrigger_stillEndsTheTurn.)
        #expect(!CompactFinishGate.shouldNotify(
            eventTrigger: nil, storedTrigger: nil))
    }
}
