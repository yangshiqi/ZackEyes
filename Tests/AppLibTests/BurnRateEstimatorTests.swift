import Testing
import Foundation
import Shared
@testable import AppLib

/// #86 — burn-rate cap ETA. The estimator extrapolates the live `used_percentage`
/// directly (no token cap, no token-rate pipeline). These pin the rate math,
/// the calm states (cold start / not-burning / reset-wins), the reset-cliff
/// reset, staleness, bucketing, and hysteresis.
struct BurnRateEstimatorTests {
    private static let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private static func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }

    // MARK: - rawETA (pure core)

    @Test func steadyBurnGivesLinearETA() {
        // 20% → 28% over 4 min = 2%/min. (100-28)/2 = 36 min to cap.
        let samples = [(t: Self.at(0), pct: 20.0),
                       (t: Self.at(2), pct: 24.0),
                       (t: Self.at(4), pct: 28.0)]
        let eta = BurnRateEstimator.rawETA(samples: samples, now: Self.at(4),
                                           currentPct: 28, resetsAt: nil)
        guard case let .minutes(m) = eta else { Issue.record("expected .minutes, got \(eta)"); return }
        #expect(abs(m - 36) < 0.001)
    }

    @Test func resetBeforeCapIsSafe() {
        // Same 2%/min burn (36 min to cap) but the window resets in 10 min.
        let samples = [(t: Self.at(0), pct: 20.0),
                       (t: Self.at(2), pct: 24.0),
                       (t: Self.at(4), pct: 28.0)]
        let eta = BurnRateEstimator.rawETA(samples: samples, now: Self.at(4),
                                           currentPct: 28, resetsAt: Self.at(14))
        #expect(eta == .safe)
    }

    @Test func flatUsageIsSafe() {
        // Not burning: % unchanged across the window → no impending cap.
        let samples = [(t: Self.at(0), pct: 50.0),
                       (t: Self.at(2), pct: 50.0),
                       (t: Self.at(4), pct: 50.0)]
        let eta = BurnRateEstimator.rawETA(samples: samples, now: Self.at(4),
                                           currentPct: 50, resetsAt: nil)
        #expect(eta == .safe)
    }

    @Test func tooFewSamplesIsComputing() {
        let samples = [(t: Self.at(0), pct: 20.0), (t: Self.at(2), pct: 24.0)]
        let eta = BurnRateEstimator.rawETA(samples: samples, now: Self.at(2),
                                           currentPct: 24, resetsAt: nil)
        #expect(eta == .computing)
    }

    @Test func shortSpanIsComputing() {
        // 3 samples but spanning only 1 min (< minSpan 3 min) → no signal.
        let samples = [(t: Self.at(0), pct: 20.0),
                       (t: Self.at(0.5), pct: 22.0),
                       (t: Self.at(1), pct: 24.0)]
        let eta = BurnRateEstimator.rawETA(samples: samples, now: Self.at(1),
                                           currentPct: 24, resetsAt: nil)
        #expect(eta == .computing)
    }

    @Test func staleLatestSampleIsComputing() {
        // Last reading is 16 min old (> 10 min window) → idle, no fresh signal.
        let samples = [(t: Self.at(0), pct: 20.0),
                       (t: Self.at(2), pct: 24.0),
                       (t: Self.at(4), pct: 28.0)]
        let eta = BurnRateEstimator.rawETA(samples: samples, now: Self.at(20),
                                           currentPct: 28, resetsAt: nil)
        #expect(eta == .computing)
    }

    @Test func atCapIsZeroMinutes() {
        let eta = BurnRateEstimator.rawETA(samples: [], now: Self.at(4),
                                           currentPct: 100, resetsAt: nil)
        #expect(eta == .minutes(0))
    }

    @Test func nilCurrentPctIsComputing() {
        let eta = BurnRateEstimator.rawETA(samples: [], now: Self.at(4),
                                           currentPct: nil, resetsAt: nil)
        #expect(eta == .computing)
    }

    // MARK: - record() / reset cliff

    @Test func resetCliffClearsHistory() {
        var est = BurnRateEstimator()
        est.record(Self.at(0), pct: 20)
        est.record(Self.at(2), pct: 24)
        est.record(Self.at(4), pct: 28)
        // Window rolled over: % drops back toward 0. Pre-cliff history must go.
        est.record(Self.at(4.1), pct: 2)
        // Only the single post-reset sample remains → not enough to estimate.
        let eta = est.estimate(now: Self.at(4.1), currentPct: 2, resetsAt: nil)
        #expect(eta == .computing)
    }

    @Test func recordPrunesOutsideWindow() {
        var est = BurnRateEstimator()
        est.record(Self.at(0), pct: 10)    // 12 min before the latest → pruned
        est.record(Self.at(9), pct: 20)
        est.record(Self.at(11), pct: 24)
        est.record(Self.at(12), pct: 28)
        // Surviving window is 9→12 min: (28-20)/3 = 2.67%/min, (100-28)/2.67 ≈ 27 min.
        let eta = est.estimate(now: Self.at(12), currentPct: 28, resetsAt: nil)
        guard case let .minutes(m) = eta else { Issue.record("expected .minutes, got \(eta)"); return }
        #expect(m == 30)   // 27 min → m30 bucket representative
    }

    // MARK: - bucketing + display

    @Test func bucketLabelsRenderExpectedStrings() {
        #expect(CapETA.bucketLabel(0) == "now")
        #expect(CapETA.bucketLabel(5) == "~5min")
        #expect(CapETA.bucketLabel(30) == "~30min")
        #expect(CapETA.bucketLabel(45) == "~45min")
        #expect(CapETA.bucketLabel(60) == "~1h")
        #expect(CapETA.bucketLabel(90) == "~1.5h")
        #expect(CapETA.bucketLabel(120) == "~2h")
        #expect(CapETA.bucketLabel(999) == ">2h")
    }

    @Test func panelLabelHidesCalmStates() {
        #expect(CapETA.computing.panelLabel == nil)
        #expect(CapETA.safe.panelLabel == nil)
        #expect(CapETA.minutes(30).panelLabel == "~30min")
    }

    @Test func pillSurfacesOnlyWhenUrgent() {
        #expect(CapETA.minutes(20).pillUrgentLabel == "~20min")
        #expect(CapETA.minutes(30).pillUrgentLabel == "~30min")
        #expect(CapETA.minutes(45).pillUrgentLabel == nil)   // > 30 → pill quiet
        #expect(CapETA.minutes(60).pillUrgentLabel == nil)
        #expect(CapETA.safe.pillUrgentLabel == nil)
        #expect(CapETA.minutes(20).isUrgent == true)
        #expect(CapETA.minutes(60).isUrgent == false)
    }

    // MARK: - hysteresis

    @Test func bucketDoesNotFlapOnSingleDivergentReading() {
        var est = BurnRateEstimator()
        est.record(Self.at(0), pct: 20)
        est.record(Self.at(2), pct: 24)
        est.record(Self.at(4), pct: 28)   // rate ≈ 2%/min, fixed

        // currentPct is the lever here: (100-pct)/2 picks the bucket.
        // pct 28 → 36 min → m30. Two reads commit m30.
        _ = est.estimate(now: Self.at(4), currentPct: 28, resetsAt: nil)
        let committed = est.estimate(now: Self.at(4), currentPct: 28, resetsAt: nil)
        #expect(committed == .minutes(30))

        // pct 10 → 45 min → m45. ONE divergent read must NOT switch the label.
        let held = est.estimate(now: Self.at(4), currentPct: 10, resetsAt: nil)
        #expect(held == .minutes(30))

        // A second consistent m45 read commits the switch.
        let switched = est.estimate(now: Self.at(4), currentPct: 10, resetsAt: nil)
        #expect(switched == .minutes(45))
    }

    @Test func firstNumberShowsImmediately() {
        // No warm-up: the very first estimate that yields a number shows it
        // (we only debounce *changes*, not the initial appearance).
        var est = BurnRateEstimator()
        est.record(Self.at(0), pct: 20)
        est.record(Self.at(2), pct: 24)
        est.record(Self.at(4), pct: 28)
        let eta = est.estimate(now: Self.at(4), currentPct: 28, resetsAt: nil)
        #expect(eta == .minutes(30))
    }
}

/// Wiring smoke test: a hook reading must populate `snapshot.fiveHourETA`.
/// (The rate math itself is covered above; `updateFromHook` stamps its own
/// `now`, so a single call yields `.computing` — enough to prove it's wired.)
@MainActor
struct BurnRateTrackerWiringTests {
    @Test func hookReadingPopulatesFiveHourETA() {
        let tracker = UsageTracker(projectsDir: URL(fileURLWithPath: "/nonexistent"),
                                   codexSessionsDir: nil)
        #expect(tracker.snapshot.fiveHourETA == nil)
        tracker.updateFromHook(rateLimits: [
            "five_hour": AnyCodable(["used_percentage": 30.0, "resets_at": 4_000_000_000.0])
        ])
        // One reading → not enough span yet, but the field is now set (wired).
        #expect(tracker.snapshot.fiveHourETA == .computing)
        #expect(tracker.snapshot.fiveHourUsedPct == 30.0)
    }
}
