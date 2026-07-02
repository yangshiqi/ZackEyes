import Testing
@testable import AppLib

@Suite("Hover intent tracker")
struct HoverIntentTrackerTests {
    @Test("begin creates one candidate without restarting it")
    func beginIsIdempotentWhilePending() {
        var tracker = HoverIntentTracker()

        let first = tracker.observe(.init(x: 10, y: 10), movementTolerance: 8)
        let duplicate = tracker.observe(.init(x: 14, y: 13), movementTolerance: 8)

        #expect(first != nil)
        #expect(duplicate == nil)
        #expect(tracker.pendingToken == first)
    }

    @Test("current candidate is consumed exactly once")
    func consumeCurrentCandidate() throws {
        var tracker = HoverIntentTracker()
        let candidate = tracker.observe(.zero, movementTolerance: 8)
        let token = try #require(candidate)
        let firstConsume = tracker.consume(token)
        let secondConsume = tracker.consume(token)

        #expect(firstConsume)
        #expect(!secondConsume)
        #expect(tracker.pendingToken == nil)
    }

    @Test("cancel invalidates a delayed callback")
    func cancelInvalidatesStaleToken() throws {
        var tracker = HoverIntentTracker()
        let candidate = tracker.observe(.zero, movementTolerance: 8)
        let stale = try #require(candidate)

        tracker.cancel()
        let consumed = tracker.consume(stale)

        #expect(!consumed)
        #expect(tracker.pendingToken == nil)
    }

    @Test("new candidate differs from a cancelled candidate")
    func newCandidateHasFreshToken() throws {
        var tracker = HoverIntentTracker()
        let firstCandidate = tracker.observe(.zero, movementTolerance: 8)
        let stale = try #require(firstCandidate)
        tracker.cancel()
        let secondCandidate = tracker.observe(.zero, movementTolerance: 8)
        let current = try #require(secondCandidate)
        let consumedStale = tracker.consume(stale)
        let consumedCurrent = tracker.consume(current)

        #expect(current != stale)
        #expect(!consumedStale)
        #expect(consumedCurrent)
    }

    @Test("movement beyond tolerance restarts the dwell candidate")
    func movementRestartsCandidate() throws {
        var tracker = HoverIntentTracker()
        let firstCandidate = tracker.observe(.zero, movementTolerance: 8)
        let first = try #require(firstCandidate)

        let secondCandidate = tracker.observe(.init(x: 9, y: 0), movementTolerance: 8)
        let second = try #require(secondCandidate)
        let consumedFirst = tracker.consume(first)
        let consumedSecond = tracker.consume(second)

        #expect(second != first)
        #expect(!consumedFirst)
        #expect(consumedSecond)
    }
}
