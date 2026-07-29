import SwiftUI

/// Pure geometry for a compact physical-notch row. Both sides receive an equal
/// layout extent based on the wider side, so the exclusion frame stays centered
/// even when status icons, percentages, or ETA text make one side wider.
struct CenteredNotchGeometry: Equatable {
    let size: CGSize
    let leadingFrame: CGRect
    let exclusionFrame: CGRect
    let trailingFrame: CGRect

    static func make(
        leadingSize: CGSize,
        trailingSize: CGSize,
        exclusionWidth: CGFloat,
        outerPadding: CGFloat,
        proposedHeight: CGFloat? = nil
    ) -> CenteredNotchGeometry {
        let sideWidth = max(leadingSize.width, trailingSize.width)
        let contentHeight = max(leadingSize.height, trailingSize.height)
        let height = max(contentHeight, proposedHeight ?? 0)
        let safeExclusionWidth = max(0, exclusionWidth)
        let safeOuterPadding = max(0, outerPadding)
        let exclusionX = safeOuterPadding + sideWidth
        let totalWidth = safeOuterPadding * 2 + sideWidth * 2 + safeExclusionWidth

        return CenteredNotchGeometry(
            size: CGSize(width: totalWidth, height: height),
            leadingFrame: CGRect(
                x: exclusionX - leadingSize.width,
                y: (height - leadingSize.height) / 2,
                width: leadingSize.width,
                height: leadingSize.height
            ),
            exclusionFrame: CGRect(
                x: exclusionX,
                y: 0,
                width: safeExclusionWidth,
                height: height
            ),
            trailingFrame: CGRect(
                x: exclusionX + safeExclusionWidth,
                y: (height - trailingSize.height) / 2,
                width: trailingSize.width,
                height: trailingSize.height
            )
        )
    }
}
struct CenteredNotchLayout: Layout {
    let exclusionWidth: CGFloat
    let outerPadding: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let sizes = measuredSizes(subviews)
        return CenteredNotchGeometry.make(
            leadingSize: sizes.leading,
            trailingSize: sizes.trailing,
            exclusionWidth: exclusionWidth,
            outerPadding: outerPadding,
            proposedHeight: proposal.height
        ).size
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        guard subviews.count >= 2 else { return }
        let sizes = measuredSizes(subviews)
        let geometry = CenteredNotchGeometry.make(
            leadingSize: sizes.leading,
            trailingSize: sizes.trailing,
            exclusionWidth: exclusionWidth,
            outerPadding: outerPadding,
            proposedHeight: bounds.height
        )

        subviews[0].place(
            at: CGPoint(
                x: bounds.minX + geometry.leadingFrame.minX,
                y: bounds.minY + geometry.leadingFrame.minY
            ),
            anchor: .topLeading,
            proposal: ProposedViewSize(geometry.leadingFrame.size)
        )
        subviews[1].place(
            at: CGPoint(
                x: bounds.minX + geometry.trailingFrame.minX,
                y: bounds.minY + geometry.trailingFrame.minY
            ),
            anchor: .topLeading,
            proposal: ProposedViewSize(geometry.trailingFrame.size)
        )
    }

    private func measuredSizes(_ subviews: Subviews) -> (leading: CGSize, trailing: CGSize) {
        let leading = subviews.indices.contains(0)
            ? subviews[0].sizeThatFits(.unspecified)
            : .zero
        let trailing = subviews.indices.contains(1)
            ? subviews[1].sizeThatFits(.unspecified)
            : .zero
        return (leading, trailing)
    }
}
