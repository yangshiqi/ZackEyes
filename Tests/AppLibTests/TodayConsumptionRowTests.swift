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
        #expect(TodayConsumptionRow.costString(4.25, floor: false, compact: true) == "$4.2")
        #expect(TodayConsumptionRow.costString(4.25, floor: true, compact: true) == "≥$4.2")
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
