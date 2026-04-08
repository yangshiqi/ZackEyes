import SwiftUI
import AppKit

/// Holds a weak reference to an NSView so SwiftUI @State can carry the
/// pointer without retaining it. Used by `HostViewProbe` to expose the
/// gear button's backing view to the menu-anchoring code.
final class HostViewBox {
    weak var view: NSView?
}

/// Drop this as a `.background(HostViewProbe(box: ...))` on any SwiftUI
/// view to capture the underlying NSView. The NSView's `superview` is
/// the SwiftUI hosting view containing the target — close enough for
/// menu anchoring purposes (its `bounds` matches the SwiftUI frame).
struct HostViewProbe: NSViewRepresentable {
    let box: HostViewBox

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        // Defer until after the view is added to its superview, so .superview
        // (the actual SwiftUI host containing our gear button) is available.
        DispatchQueue.main.async { [weak v] in
            self.box.view = v?.superview ?? v
        }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
