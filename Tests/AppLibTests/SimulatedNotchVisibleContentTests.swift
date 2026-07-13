import Testing
@testable import AppLib

struct SimulatedNotchVisibleContentTests {
    @Test
    func compactAndHoverWideActivateOnlyCompactContent() {
        #expect(SimulatedNotchContentActivity(mode: .compact) == .compact)
        #expect(SimulatedNotchContentActivity(mode: .hoverWide) == .compact)
        #expect(!SimulatedNotchContentActivity(mode: .compact).fullIsActive)
    }

    @Test
    func fullActivatesFullContent() {
        #expect(SimulatedNotchContentActivity(mode: .full) == .full)
        #expect(SimulatedNotchContentActivity(mode: .full).fullIsActive)
    }
}
