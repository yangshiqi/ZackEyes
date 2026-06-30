import Foundation

/// Pure presentation state for one agent's 5h/7d usage cell.
///
/// Centralizes the "limit reached" override so a blocked agent renders an
/// explicit exhausted badge instead of a misleading "100% remaining". This is
/// the Codex case: on credit-gated plans the rate-limit window `used_percent`
/// stays near 0 even when the account is out of credits, so the bar alone reads
/// as "fully available" while Codex is actually unavailable. `limitReached`
/// (sourced from `UsageTracker.Snapshot.codexLimitReached`) forces the exhausted
/// treatment, identical to how a Claude window at 100% used renders.
public struct UsageCellState: Equatable, Sendable {
    /// Show the red "limit reached" treatment instead of a remaining %.
    public let isExhausted: Bool
    /// Progress-bar fill, 0...1. Exhausted → full.
    public let fillFraction: Double
    /// Remaining-percentage integer for the label (0 when exhausted).
    public let remainingPct: Int

    /// `usedPct` nil = "no data" (caller renders its own placeholder, this still
    /// returns a calm 100%-remaining state). `limitReached` OR used ≥ 100 →
    /// exhausted.
    public static func make(usedPct: Double?, limitReached: Bool) -> UsageCellState {
        let used = usedPct ?? 0
        if limitReached || used >= 100 {
            return UsageCellState(isExhausted: true, fillFraction: 1, remainingPct: 0)
        }
        let clamped = max(0, min(100, used))
        return UsageCellState(
            isExhausted: false,
            fillFraction: clamped / 100,
            remainingPct: Int((100 - clamped).rounded())
        )
    }
}
