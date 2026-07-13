import Testing
@testable import AppLib

struct ProgressPresentationTests {
    @Test
    func usedUsesConsumedFractionFromLeadingEdge() {
        let presentation = ProgressPresentation(
            usedFraction: 0.46,
            mode: .used,
            leftDirection: .rightToLeft
        )

        #expect(presentation.fraction == 0.46)
        #expect(presentation.percent == 46)
        #expect(presentation.anchor == .leading)
        #expect(presentation.explicitLabel == "46% used")
        #expect(presentation.mode.displayName == "Used")
    }

    @Test
    func leftUsesRemainingFractionFromSelectedEdge() {
        let leading = ProgressPresentation(
            usedFraction: 0.46,
            mode: .left,
            leftDirection: .leftToRight
        )
        let trailing = ProgressPresentation(
            usedFraction: 0.46,
            mode: .left,
            leftDirection: .rightToLeft
        )

        #expect(leading.fraction == 0.54)
        #expect(leading.percent == 54)
        #expect(leading.anchor == .leading)
        #expect(leading.explicitLabel == "54% remaining")
        #expect(trailing.anchor == .trailing)
        #expect(trailing.mode.displayName == "Left")
    }

    @Test
    func opacityUsesTenthStepsAndEmphasizedBorder() {
        #expect(TimeOverlayOpacity.normalized(0.44) == 0.4)
        #expect(TimeOverlayOpacity.normalized(-1) == 0)
        #expect(TimeOverlayOpacity.normalized(2) == 1)
        #expect(TimeOverlayOpacity.boundaryOpacity(for: 0) == 0)
        #expect(TimeOverlayOpacity.boundaryOpacity(for: 0.4) == 0.25)
        #expect(TimeOverlayOpacity.boundaryOpacity(for: 0.8) == 0.65)
    }
}
