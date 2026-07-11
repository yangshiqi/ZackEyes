import Testing
@testable import AppLib

struct SimulatedNotchVisibleContentTests {
    @Test
    func compactAndHoverWideMountOnlyCompactContent() {
        #expect(SimulatedNotchVisibleContent(mode: .compact) == .compact)
        #expect(SimulatedNotchVisibleContent(mode: .hoverWide) == .compact)
    }

    @Test
    func fullMountsOnlyFullContent() {
        #expect(SimulatedNotchVisibleContent(mode: .full) == .full)
    }
}
