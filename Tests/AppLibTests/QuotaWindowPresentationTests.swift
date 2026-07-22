import Testing
@testable import AppLib

struct QuotaWindowPresentationTests {
    @Test func dualWindowKeepsFiveThenSevenOrder() {
        let presentation = QuotaWindowPresentation(
            fiveHourUsedPct: 24,
            sevenDayUsedPct: 6
        )

        #expect(presentation.windows == [.fiveHour, .sevenDay])
        #expect(presentation.primary == .fiveHour)
        #expect(presentation.secondary == .sevenDay)
    }

    @Test func fiveHourOnlyUsesFiveHourAsPrimary() {
        let presentation = QuotaWindowPresentation(
            fiveHourUsedPct: 24,
            sevenDayUsedPct: nil
        )

        #expect(presentation.windows == [.fiveHour])
        #expect(presentation.primary == .fiveHour)
        #expect(presentation.secondary == nil)
    }

    @Test func sevenDayOnlyPromotesSevenDayToPrimary() {
        let presentation = QuotaWindowPresentation(
            fiveHourUsedPct: nil,
            sevenDayUsedPct: 6
        )

        #expect(presentation.windows == [.sevenDay])
        #expect(presentation.primary == .sevenDay)
        #expect(presentation.secondary == nil)
    }

    @Test func noWindowsProducesOneEmptyPresentationState() {
        let presentation = QuotaWindowPresentation(
            fiveHourUsedPct: nil,
            sevenDayUsedPct: nil
        )

        #expect(presentation.windows.isEmpty)
        #expect(presentation.primary == nil)
        #expect(presentation.secondary == nil)
    }

    @Test func unionKeepsWindowWhenEitherAgentExposesIt() {
        let claude = QuotaWindowPresentation(fiveHourUsedPct: 10, sevenDayUsedPct: nil)
        let codex = QuotaWindowPresentation(fiveHourUsedPct: nil, sevenDayUsedPct: 20)

        #expect(QuotaWindowPresentation.union(claude, codex).windows == [.fiveHour, .sevenDay])
    }
}
