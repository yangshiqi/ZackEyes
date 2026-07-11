import Testing
@testable import AppLib

struct ProgressPresentationTests {
    @Test
    func spentUsesConsumedFractionFromLeadingEdge() {
        let presentation = ProgressPresentation(
            spentFraction: 0.46,
            mode: .spent,
            leftDirection: .rightToLeft
        )

        #expect(presentation.fraction == 0.46)
        #expect(presentation.percent == 46)
        #expect(presentation.anchor == .leading)
        #expect(presentation.explicitLabel == "46% spent")
    }

    @Test
    func leftUsesRemainingFractionFromSelectedEdge() {
        let leading = ProgressPresentation(
            spentFraction: 0.46,
            mode: .left,
            leftDirection: .leftToRight
        )
        let trailing = ProgressPresentation(
            spentFraction: 0.46,
            mode: .left,
            leftDirection: .rightToLeft
        )

        #expect(leading.fraction == 0.54)
        #expect(leading.percent == 54)
        #expect(leading.anchor == .leading)
        #expect(leading.explicitLabel == "54% remaining")
        #expect(trailing.anchor == .trailing)
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
