import Foundation

/// A timestamped account-level reading from one local rollout, before display
/// scopes are merged. Source identity remains in memory and is never persisted.
public struct CodexQuotaReading: Sendable {
    let sourceID: String
    let observedAt: Date
    let quota: UsageTracker.CodexRateLimitObservation
    var recoveredAt: Date? = nil
    var hasCompleteHistory = true
    private var originalFiveHourReset: Date? = nil
    private var originalSevenDayReset: Date? = nil

    init(sourceID: String, observedAt: Date, quota: UsageTracker.CodexRateLimitObservation) {
        self.sourceID = sourceID
        self.observedAt = observedAt
        self.quota = quota
    }

    var plannedFiveHourReset: Date? { originalFiveHourReset ?? quota.fiveHourResetsAt }
    var plannedSevenDayReset: Date? { originalSevenDayReset ?? quota.sevenDayResetsAt }

    /// Usage can grow while a provider revises its dates. Keep the original
    /// deadlines until they expire, separately from the latest actual reading.
    func retainingOriginalPlan(from previous: CodexQuotaReading?) -> CodexQuotaReading {
        var reading = self
        func deadline(_ known: Date?, _ incoming: Date?) -> Date? {
            if let known, known > observedAt { return known }
            return incoming
        }
        reading.originalFiveHourReset = deadline(previous?.plannedFiveHourReset, plannedFiveHourReset)
        reading.originalSevenDayReset = deadline(previous?.plannedSevenDayReset, plannedSevenDayReset)
        return reading
    }
}

enum CodexQuotaRecovery {
    static let freshness: TimeInterval = 15 * 60

    static func occurred(from previous: CodexQuotaReading, to current: CodexQuotaReading) -> Bool {
        let elapsed = current.observedAt.timeIntervalSince(previous.observedAt)
        guard previous.sourceID == current.sourceID,
              elapsed > 0,
              !current.quota.limitReached else { return false }
        return restored(
            oldUsed: previous.quota.fiveHourUsedPct,
            originalReset: previous.plannedFiveHourReset,
            latestReset: previous.quota.fiveHourResetsAt,
            newUsed: current.quota.fiveHourUsedPct,
            newReset: current.quota.fiveHourResetsAt, at: current.observedAt
        ) || restored(
            oldUsed: previous.quota.sevenDayUsedPct,
            originalReset: previous.plannedSevenDayReset,
            latestReset: previous.quota.sevenDayResetsAt,
            newUsed: current.quota.sevenDayUsedPct,
            newReset: current.quota.sevenDayResetsAt, at: current.observedAt
        )
    }

    private static func restored(oldUsed: Double?, originalReset: Date?, latestReset: Date?,
                                 newUsed: Double?, newReset: Date?, at observedAt: Date) -> Bool {
        guard let oldUsed, let newUsed, let originalReset, let latestReset, let newReset,
              oldUsed.isFinite, newUsed.isFinite,
              (0...100).contains(oldUsed), (0...100).contains(newUsed),
              newUsed <= 5, oldUsed - newUsed >= 10,
              // Keep a minute of slack around the regular reset boundary.
              originalReset > observedAt.addingTimeInterval(60),
              newReset > observedAt, newReset >= latestReset else { return false }
        return true
    }
}
