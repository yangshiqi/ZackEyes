import Foundation

/// A timestamped account-level reading from one local rollout, before display
/// scopes are merged. Source identity remains in memory and is never persisted.
public struct CodexQuotaReading: Sendable {
    let sourceID: String
    let observedAt: Date
    let quota: UsageTracker.CodexRateLimitObservation
    var recoveredAt: Date? = nil
}

enum CodexQuotaRecovery {
    static let freshness: TimeInterval = 15 * 60

    static func occurred(from previous: CodexQuotaReading, to current: CodexQuotaReading) -> Bool {
        let elapsed = current.observedAt.timeIntervalSince(previous.observedAt)
        guard previous.sourceID == current.sourceID,
              elapsed > 0,
              !current.quota.limitReached else { return false }
        return restored(previous.quota.fiveHourUsedPct, previous.quota.fiveHourResetsAt,
                        current.quota.fiveHourUsedPct, current.quota.fiveHourResetsAt,
                        at: current.observedAt)
            || restored(previous.quota.sevenDayUsedPct, previous.quota.sevenDayResetsAt,
                        current.quota.sevenDayUsedPct, current.quota.sevenDayResetsAt,
                        at: current.observedAt)
    }

    private static func restored(_ oldUsed: Double?, _ oldReset: Date?,
                                 _ newUsed: Double?, _ newReset: Date?, at observedAt: Date) -> Bool {
        guard let oldUsed, let newUsed, let oldReset, let newReset,
              oldUsed.isFinite, newUsed.isFinite,
              (0...100).contains(oldUsed), (0...100).contains(newUsed),
              newUsed <= 5, oldUsed - newUsed >= 10,
              // Keep a minute of slack around the regular reset boundary.
              oldReset > observedAt.addingTimeInterval(60),
              newReset >= oldReset else { return false }
        return true
    }
}
