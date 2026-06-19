import SwiftUI

/// The Dynamic Island / notch silhouette, mirroring the shape used by
/// DynamicNotchKit and boring.notch (both share this exact path). Borrowed for
/// issue #64 so ZackEyes' black panel reads as a seamless continuation of the
/// hardware notch instead of a floating bar.
///
/// Geometry (AppKit/SwiftUI top-left origin, y down):
/// - a perfectly **flat top edge** spanning the full width, flush against the
///   screen bezel;
/// - the two **top-outer corners** flare *outward* into the bezel over
///   `topCornerRadius` — the shape is widest at the very top and tucks in as it
///   descends, which is what visually fuses it with the physical notch;
/// - straight sides;
/// - rounded **bottom-inner corners** (`bottomCornerRadius`) forming the
///   Dynamic Island "chin".
struct NotchShape: Shape {
    let topCornerRadius: CGFloat
    let bottomCornerRadius: CGFloat

    init(topCornerRadius: CGFloat = 6, bottomCornerRadius: CGFloat = 14) {
        self.topCornerRadius = topCornerRadius
        self.bottomCornerRadius = bottomCornerRadius
    }

    /// Back-compat initializer: bottom-only rounding with a square top. The
    /// simulated notch (notchless Macs) uses this — it sits in the menu bar,
    /// not against a hardware bezel, so the top-outer flare isn't wanted.
    init(cornerRadius: CGFloat) {
        self.init(topCornerRadius: 0, bottomCornerRadius: cornerRadius)
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let top = min(topCornerRadius, rect.height)
        let bottom = min(bottomCornerRadius, max(0, rect.height - top))

        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        // top-left outer corner: flare from the full-width top down/in
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + top, y: rect.minY + top),
            control: CGPoint(x: rect.minX + top, y: rect.minY)
        )
        // left side
        path.addLine(to: CGPoint(x: rect.minX + top, y: rect.maxY - bottom))
        // bottom-left inner corner
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + top + bottom, y: rect.maxY),
            control: CGPoint(x: rect.minX + top, y: rect.maxY)
        )
        // bottom edge
        path.addLine(to: CGPoint(x: rect.maxX - top - bottom, y: rect.maxY))
        // bottom-right inner corner
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - top, y: rect.maxY - bottom),
            control: CGPoint(x: rect.maxX - top, y: rect.maxY)
        )
        // right side
        path.addLine(to: CGPoint(x: rect.maxX - top, y: rect.minY + top))
        // top-right outer corner: flare back out to the full-width top
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX - top, y: rect.minY)
        )
        path.closeSubpath()
        return path
    }
}
