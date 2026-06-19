import AppKit

extension NSScreen {
    public var hasNotch: Bool {
        safeAreaInsets.top > 0
    }

    public var notchSize: CGSize? {
        guard let leftWidth = auxiliaryTopLeftArea?.width,
              let rightWidth = auxiliaryTopRightArea?.width else { return nil }
        return CGSize(
            width: frame.width - leftWidth - rightWidth + 4,
            height: safeAreaInsets.top
        )
    }

    public var notchFrame: CGRect? {
        guard let size = notchSize else { return nil }
        return CGRect(
            x: frame.midX - size.width / 2,
            y: frame.maxY - size.height,
            width: size.width,
            height: size.height
        )
    }

    /// The built-in display with a hardware notch, if any is currently
    /// connected. This is the screen the real-notch panel must anchor to.
    ///
    /// Deliberately NOT `NSScreen.main`: `main` follows the keyboard-focus /
    /// key-window screen, so on a notched MacBook driving an external monitor
    /// it points at the external (notchless) display whenever a window there
    /// has focus. Selecting by `hasNotch` is focus-independent and always
    /// resolves to the built-in notch screen (issue #64 — external-display
    /// mis-anchoring).
    public static var withNotch: NSScreen? {
        screens.first { $0.hasNotch }
    }

    /// True when any connected display has a hardware notch. The correct
    /// question for the real-notch-vs-simulated decision: unlike
    /// `NSScreen.main?.hasNotch`, it does not flip to `false` merely because
    /// the focused window currently lives on an external monitor.
    public static var hasAnyNotch: Bool {
        screens.contains { $0.hasNotch }
    }
}
