import Testing
import Foundation
@testable import AppLib

/// #169 — per-session cooldown gate for blocked-waiting alerts.
struct WaitingAlertGateTests {
    static let base = Date(timeIntervalSince1970: 1_000_000)

    @Test func firesWhenNeverAlerted() {
        #expect(WaitingAlertGate.shouldAlert(lastAlertedAt: nil, now: Self.base, cooldown: 12) == true)
    }

    @Test func suppressedWithinCooldown() {
        let now = Self.base.addingTimeInterval(5)   // < 12s since last
        #expect(WaitingAlertGate.shouldAlert(lastAlertedAt: Self.base, now: now, cooldown: 12) == false)
    }

    @Test func firesAfterCooldown() {
        let now = Self.base.addingTimeInterval(13)   // > 12s since last
        #expect(WaitingAlertGate.shouldAlert(lastAlertedAt: Self.base, now: now, cooldown: 12) == true)
    }

    @Test func firesExactlyAtCooldownBoundary() {
        let now = Self.base.addingTimeInterval(12)   // == 12s, boundary is inclusive (>=)
        #expect(WaitingAlertGate.shouldAlert(lastAlertedAt: Self.base, now: now, cooldown: 12) == true)
    }
}
