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
}
