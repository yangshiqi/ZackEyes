import AppKit
import SwiftUI

/// A hover-only reader. Native NSPopover can activate its application when
/// opened from a nonactivating panel, so the original post uses a child panel
/// that explicitly cannot take keyboard focus.
struct CodexResetOriginalTextPopover: NSViewRepresentable {
    let text: String
    let height: CGFloat
    let isPresented: Bool
    let onHover: (Bool) -> Void
    let onAnchorHover: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> AnchorView { AnchorView(frame: .zero) }

    func updateNSView(_ view: AnchorView, context: Context) {
        view.onHover = onAnchorHover
        if isPresented {
            context.coordinator.show(anchor: view, text: text, height: height, onHover: onHover)
        } else {
            context.coordinator.hide()
        }
    }

    static func dismantleNSView(_ view: AnchorView, coordinator: Coordinator) {
        coordinator.hide()
    }

    static func containsReader(at point: NSPoint, attachedTo parent: NSWindow?) -> Bool {
        parent?.childWindows?.contains {
            isReaderWindow($0, attachedTo: parent) && $0.frame.contains(point)
        } ?? false
    }

    static func isReaderWindow(_ window: NSWindow?, attachedTo parent: NSWindow?) -> Bool {
        guard let parent, let window = window as? HoverPanel else { return false }
        return window.parent === parent && window.isVisible
    }

    /// Each lazy text block is bounded without losing Unicode or original
    /// content. Only the visible blocks need to be laid out on hover.
    static func readerChunks(_ text: String) -> [String] {
        var contiguous = text
        return contiguous.withUTF8 { bytes in
            var chunks: [String] = []
            var start = 0
            while start < bytes.count {
                var end = min(start + 2048, bytes.count)
                while end < bytes.count, bytes[end] & 0xC0 == 0x80 { end += 1 }
                chunks.append(String(decoding: bytes[start..<end], as: UTF8.self))
                start = end
            }
            return chunks
        }
    }

    final class AnchorView: NSView {
        var onHover: ((Bool) -> Void)?
        private var area: NSTrackingArea?
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let area { removeTrackingArea(area) }
            let tracking = NSTrackingArea(rect: .zero,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
            addTrackingArea(tracking)
            area = tracking
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func mouseEntered(with event: NSEvent) { onHover?(true) }
        override func mouseExited(with event: NSEvent) { onHover?(false) }
    }

    private struct TrackingArea: NSViewRepresentable {
        let onHover: (Bool) -> Void
        func makeNSView(context: Context) -> AnchorView { AnchorView(frame: .zero) }
        func updateNSView(_ view: AnchorView, context: Context) { view.onHover = onHover }
    }

    final class HoverPanel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    @MainActor final class Coordinator {
        private let panel: HoverPanel = {
            let panel = HoverPanel(
                contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            panel.isMovable = false
            panel.hidesOnDeactivate = false
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
            return panel
        }()

        private var renderedText: String?
        private var renderedSize = NSSize.zero
        private var hoverChanged: ((Bool) -> Void)?

        func show(anchor: NSView, text: String, height: CGFloat, onHover: @escaping (Bool) -> Void) {
            guard let parent = anchor.window, parent.isVisible, let screen = parent.screen else { return }
            panel.level = parent.level
            let anchorFrame = parent.convertToScreen(anchor.convert(anchor.bounds, to: nil))
            let available = screen.visibleFrame.insetBy(dx: 8, dy: 8)
            let size = NSSize(width: min(360, available.width), height: min(height, available.height))
            let x = min(max(anchorFrame.minX, available.minX), available.maxX - size.width)
            let below = anchorFrame.minY - size.height - 6
            let y = below >= available.minY ? below
                : min(anchorFrame.maxY + 6, available.maxY - size.height)
            panel.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: size), display: false)
            hoverChanged = onHover
            if renderedText != text || renderedSize != size {
                renderedText = text
                renderedSize = size
                let chunks = CodexResetOriginalTextPopover.readerChunks(text)
                panel.contentView = NSHostingView(rootView:
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(chunks.indices, id: \.self) { index in
                                Text(verbatim: chunks[index])
                                    .font(.system(size: 12))
                                    .foregroundStyle(.white)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(12)
                    }
                    .frame(width: size.width, height: size.height)
                    .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    .environment(\.colorScheme, .dark)
                    .background(TrackingArea(onHover: { [weak self] hovering in
                        self?.hoverChanged?(hovering)
                    })))
            }
            if panel.parent !== parent {
                panel.parent?.removeChildWindow(panel)
                parent.addChildWindow(panel, ordered: .above)
            }
            panel.orderFrontRegardless()
        }

        func hide() {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
    }
}
