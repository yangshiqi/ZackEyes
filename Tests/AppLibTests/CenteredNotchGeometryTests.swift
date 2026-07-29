import Testing
import CoreGraphics
@testable import AppLib

struct CenteredNotchGeometryTests {
    @Test func asymmetricSidesKeepExclusionExactlyCentered() {
        let geometry = CenteredNotchGeometry.make(
            leadingSize: CGSize(width: 92, height: 14),
            trailingSize: CGSize(width: 38, height: 14),
            exclusionWidth: 201,
            outerPadding: 14,
            proposedHeight: 32
        )

        #expect(geometry.exclusionFrame.midX == geometry.size.width / 2)
        #expect(geometry.leadingFrame.maxX == geometry.exclusionFrame.minX)
        #expect(geometry.trailingFrame.minX == geometry.exclusionFrame.maxX)
        #expect(geometry.leadingFrame.minX >= 14)
        #expect(geometry.trailingFrame.maxX <= geometry.size.width - 14)
    }

    @Test(arguments: [CGFloat(170), CGFloat(185), CGFloat(220)])
    func runtimeNotchWidthsRemainCentered(_ notchWidth: CGFloat) {
        let geometry = CenteredNotchGeometry.make(
            leadingSize: CGSize(width: 110, height: 14),
            trailingSize: CGSize(width: 0, height: 0),
            exclusionWidth: notchWidth + 16,
            outerPadding: 14
        )

        #expect(geometry.exclusionFrame.width == notchWidth + 16)
        #expect(geometry.exclusionFrame.midX == geometry.size.width / 2)
        #expect(geometry.leadingFrame.maxX <= geometry.exclusionFrame.minX)
        #expect(geometry.trailingFrame.minX >= geometry.exclusionFrame.maxX)
    }
}
