import Testing
import Foundation
@testable import AppLib

struct TodayConsumptionRowTests {
    @Test func humanizeTokens() {
        #expect(TodayConsumptionRow.humanizeTokens(1_400_000) == "1.4M")
        #expect(TodayConsumptionRow.humanizeTokens(12_000_000) == "12M")
        #expect(TodayConsumptionRow.humanizeTokens(1_000_000) == "1M")
        #expect(TodayConsumptionRow.humanizeTokens(340_000) == "340K")
        #expect(TodayConsumptionRow.humanizeTokens(12_000) == "12K")
        #expect(TodayConsumptionRow.humanizeTokens(1234) == "1234")
        #expect(TodayConsumptionRow.humanizeTokens(0) == "0")
        #expect(TodayConsumptionRow.humanizeTokens(999_999) == "999K")
    }

    @Test func costString() {
        #expect(TodayConsumptionRow.costString(4.2, floor: false) == "$4.20")
        #expect(TodayConsumptionRow.costString(4.2, floor: true) == "≥$4.20")
        #expect(TodayConsumptionRow.costString(nil, floor: false) == nil)
    }

    @Test func sparklineFractions() {
        #expect(TodayConsumptionRow.sparklineFractions([0, 5, 10]) == [0, 0.5, 1.0])
        #expect(TodayConsumptionRow.sparklineFractions([0, 0, 0]) == [0, 0, 0])
        #expect(TodayConsumptionRow.sparklineFractions([]) == [])
    }

    @Test func combinedCost() {
        let d = Date(timeIntervalSince1970: 0)
        #expect(TodayConsumptionRow.combinedCost(DayUsage(dayStart: d, claudeCostUSD: 1.0, codexCostUSD: 2.0)) == 3.0)
        #expect(TodayConsumptionRow.combinedCost(DayUsage(dayStart: d, claudeCostUSD: 1.5, codexCostUSD: nil)) == 1.5)
        #expect(TodayConsumptionRow.combinedCost(DayUsage(dayStart: d, claudeCostUSD: nil, codexCostUSD: nil)) == nil)
        #expect(TodayConsumptionRow.combinedCost(DayUsage(dayStart: d, claudeCostUSD: nil, codexCostUSD: 2.5)) == 2.5)
    }

    @Test func compositionLine() {
        let d = Date(timeIntervalSince1970: 0)
        // all four present (Claude-typical): cache write ↑ / cache read ↓
        let full = DayUsage(dayStart: d, inputTokens: 320_000, outputTokens: 45_000,
                            cacheWriteTokens: 120_000, cacheReadTokens: 4_100_000)
        #expect(TodayConsumptionRow.compositionLine(for: full) == "in 320K · out 45K · cache 120K↑/4.1M↓")
        // in/out only (no cache activity)
        let plain = DayUsage(dayStart: d, inputTokens: 700, outputTokens: 50)
        #expect(TodayConsumptionRow.compositionLine(for: plain) == "in 700 · out 50")
        // cache read only → single ↓ segment
        let readOnly = DayUsage(dayStart: d, cacheReadTokens: 42_000)
        #expect(TodayConsumptionRow.compositionLine(for: readOnly) == "cache 42K↓")
        // all zero → nil
        #expect(TodayConsumptionRow.compositionLine(for: DayUsage(dayStart: d)) == nil)
    }

    @Test func hasConsumption() {
        let d = Date(timeIntervalSince1970: 0)
        var snap = UsageTracker.Snapshot.empty
        #expect(snap.hasConsumption == false)
        snap.dailyUsage = [DayUsage(dayStart: d, claudeTokens: 0, codexTokens: 0)]
        #expect(snap.hasConsumption == false)
        snap.dailyUsage = [DayUsage(dayStart: d, claudeTokens: 100, codexTokens: 0)]
        #expect(snap.hasConsumption == true)
    }
}
