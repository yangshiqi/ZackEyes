import Testing
import Foundation
@testable import AppLib

struct UsageCellStateTests {

    @Test func normalUsageShowsRemaining() {
        let cell = UsageCellState.make(usedPct: 37, limitReached: false)
        #expect(cell.isExhausted == false)
        #expect(cell.remainingPct == 63)
        #expect(abs(cell.fillFraction - 0.37) < 0.0001)
    }

    @Test func noDataIsCalmFullRemaining() {
        let cell = UsageCellState.make(usedPct: nil, limitReached: false)
        #expect(cell.isExhausted == false)
        #expect(cell.remainingPct == 100)
        #expect(cell.fillFraction == 0)
    }

    @Test func limitReachedOverridesToExhausted() {
        // The codex case: window used% reads ~0 (looks fully available) but the
        // account is blocked. limitReached forces the exhausted treatment.
        let cell = UsageCellState.make(usedPct: 0, limitReached: true)
        #expect(cell.isExhausted)
        #expect(cell.remainingPct == 0)
        #expect(cell.fillFraction == 1)
    }

    @Test func windowAt100IsExhaustedWithoutFlag() {
        let cell = UsageCellState.make(usedPct: 100, limitReached: false)
        #expect(cell.isExhausted)
        #expect(cell.fillFraction == 1)
    }

    @Test func overTracksClampToFull() {
        let cell = UsageCellState.make(usedPct: 130, limitReached: false)
        #expect(cell.isExhausted)
        #expect(cell.fillFraction == 1)
        #expect(cell.remainingPct == 0)
    }
}
