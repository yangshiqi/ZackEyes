import Foundation

/// Predicted time-to-cap for one rate-limit window (the 5h window), derived
/// purely from successive `used_percentage` readings — **no token cap, no
/// token-rate pipeline**.
///
/// The percentage IS the quantity Anthropic / Codex actually enforce, computed
/// by an opaque weighted formula we don't have. Extrapolating that ground-truth
/// signal directly avoids the two layers of guesswork a token-based estimate
/// needs (an unknown per-plan token cap, plus the mismatch between our token
/// count and the server's `used%`). See #86.
public enum CapETA: Sendable, Equatable {
    /// Not enough recent signal yet — cold start, just-resumed, or an idle gap
    /// where readings went stale. UI shows "—", never a jumpy number.
    case computing
    /// The window resets before the current burn would reach the cap, so there
    /// is nothing to count down to. UI keeps the normal "resets in …" text.
    case safe
    /// Estimated minutes until `used%` reaches 100 at the recent burn rate.
    /// Already bucketed + hysteresis-stabilized when produced by
    /// `BurnRateEstimator.estimate`; raw (unrounded) when produced by `rawETA`.
    case minutes(Double)
}

/// Coarse display buckets. Two jobs: (1) keep the shown value calm — a real
/// burn rate jitters, so we quantize; (2) give hysteresis a discrete state to
/// debounce. `representativeMinutes` is the single value each bucket renders as,
/// so the estimate and the label can never disagree.
enum ETABucket: Int, Sendable, Comparable {
    case m5, m10, m15, m20, m30, m45, h1, h1_5, h2, over2h

    static func < (a: ETABucket, b: ETABucket) -> Bool { a.rawValue < b.rawValue }

    static func from(minutes m: Double) -> ETABucket {
        switch m {
        case ..<7.5:  return .m5
        case ..<12.5: return .m10
        case ..<17.5: return .m15
        case ..<25:   return .m20
        case ..<37.5: return .m30
        case ..<52.5: return .m45
        case ..<75:   return .h1
        case ..<105:  return .h1_5
        case ..<150:  return .h2
        default:      return .over2h
        }
    }

    var representativeMinutes: Double {
        switch self {
        case .m5:     return 5
        case .m10:    return 10
        case .m15:    return 15
        case .m20:    return 20
        case .m30:    return 30
        case .m45:    return 45
        case .h1:     return 60
        case .h1_5:   return 90
        case .h2:     return 120
        case .over2h: return 999   // sentinel → formatter renders ">2h"
        }
    }
}

/// Rolling estimator: feed it `(timestamp, used%)` readings as they arrive
/// (Claude hooks / Codex rollout scans); ask it for a `CapETA`.
///
/// Value type — one instance per agent, stored on `UsageTracker` (@MainActor).
/// Deterministic: every method takes an explicit `now`, with no internal clock,
/// so the whole algorithm is unit-testable end to end.
public struct BurnRateEstimator: Sendable {
    /// Trailing window the burn rate is measured over.
    static let window: TimeInterval = 10 * 60
    /// Need at least this many readings spanning `minSpan` before emitting a
    /// number — a short span makes the rate (and thus the ETA) meaningless.
    static let minSamples = 3
    static let minSpan: TimeInterval = 3 * 60
    /// Below this %/min the window is effectively idle → `.safe` (not burning).
    static let minRatePerMin = 0.01
    /// Ring-buffer cap. Readings older than `window` are dropped first; this is
    /// only a backstop against a pathological burst of readings.
    static let capacity = 64
    /// A new bucket must persist this many consecutive estimates before it is
    /// shown, so a small denominator doesn't make the label flap between buckets.
    static let stableCount = 2

    private struct Sample: Sendable { var t: Date; var pct: Double }
    private var samples: [Sample] = []

    // Hysteresis state.
    private var committed: ETABucket?
    private var pending: ETABucket?
    private var pendingHits = 0

    public init() {}

    /// Record a fresh reading. A LARGE drop in `pct` means the window rolled
    /// over (used% reset toward 0), so we discard the pre-reset history —
    /// otherwise the rate would be computed across the cliff. The threshold is
    /// generous (5 pts): minor downward jitter must NOT wipe history, or the ETA
    /// would keep flapping back to cold-start `—`. A real reset is a drop of
    /// tens of points; a small gradual decline instead yields a negative rate,
    /// which `rawETA` already reports as `.safe` (not burning).
    public mutating func record(_ now: Date, pct: Double) {
        if let last = samples.last, pct < last.pct - 5.0 {
            samples.removeAll()
            committed = nil; pending = nil; pendingHits = 0
        }
        samples.append(Sample(t: now, pct: pct))
        let cutoff = now.addingTimeInterval(-Self.window)
        samples.removeAll { $0.t < cutoff }
        if samples.count > Self.capacity {
            samples.removeFirst(samples.count - Self.capacity)
        }
    }

    /// Current ETA. `currentPct` / `resetsAt` come from the live snapshot — the
    /// authoritative latest %, which can be fresher than the last recorded
    /// sample. Applies hysteresis to the bucketed result; `computing` / `safe`
    /// (the calm states) pass through immediately.
    public mutating func estimate(now: Date, currentPct: Double?, resetsAt: Date?) -> CapETA {
        let raw = Self.rawETA(samples: samples.map { (t: $0.t, pct: $0.pct) },
                              now: now, currentPct: currentPct, resetsAt: resetsAt)
        guard case let .minutes(m) = raw, m > 0 else {
            committed = nil; pending = nil; pendingHits = 0
            return raw
        }
        let bucket = ETABucket.from(minutes: m)
        if bucket == committed {
            pending = nil; pendingHits = 0
        } else if bucket == pending {
            pendingHits += 1
            if pendingHits >= Self.stableCount {
                committed = bucket; pending = nil; pendingHits = 0
            }
        } else {
            pending = bucket; pendingHits = 1
        }
        // Until a new bucket commits, keep showing the last committed one. With
        // nothing committed yet (first number), show the raw bucket immediately.
        let shown = committed ?? bucket
        return .minutes(shown.representativeMinutes)
    }

    /// PURE core: fully determined by its inputs, no stored state. Kept separate
    /// so the rate / cap / reset math is tested in isolation from the ring
    /// buffer + hysteresis wrapper above.
    static func rawETA(samples: [(t: Date, pct: Double)],
                       now: Date, currentPct: Double?, resetsAt: Date?) -> CapETA {
        guard let pct = currentPct else { return .computing }
        if pct >= 100 { return .minutes(0) }            // already at cap
        // Latest reading must be recent, else the signal is stale (idle gap).
        guard let last = samples.last,
              now.timeIntervalSince(last.t) <= window,
              let first = samples.first else { return .computing }
        let span = last.t.timeIntervalSince(first.t)
        guard samples.count >= minSamples, span >= minSpan else { return .computing }
        let ratePerMin = (last.pct - first.pct) / (span / 60)
        guard ratePerMin >= minRatePerMin else { return .safe }   // not burning
        let minsToCap = (100 - pct) / ratePerMin
        if let reset = resetsAt {
            let etaDate = now.addingTimeInterval(minsToCap * 60)
            if etaDate >= reset { return .safe }        // reset wins → no countdown
        }
        return .minutes(max(0, minsToCap))
    }
}

// MARK: - Display

public extension CapETA {
    /// Expanded-panel label — coarse + calm. `nil` for `computing` / `safe`,
    /// where the row keeps its normal "resets in …" text instead of a countdown.
    var panelLabel: String? {
        guard case let .minutes(m) = self else { return nil }
        return Self.bucketLabel(m)
    }

    /// Pill label, shown ONLY when urgent (≤ 30 min). `nil` otherwise → the
    /// collapsed pill stays quota-only, honoring the minimal-pill convention.
    var pillUrgentLabel: String? {
        guard case let .minutes(m) = self, m <= 30 else { return nil }
        return Self.bucketLabel(m)
    }

    /// True while a countdown is being shown — drives pill urgency styling.
    var isUrgent: Bool { pillUrgentLabel != nil }

    static func bucketLabel(_ m: Double) -> String {
        if m <= 0 { return "now" }
        if m < 52.5 { return "~\(Int(m))min" }   // 5 / 10 / 15 / 20 / 30 / 45
        if m < 75 { return "~1h" }
        if m < 105 { return "~1.5h" }
        if m < 150 { return "~2h" }
        return ">2h"
    }
}
