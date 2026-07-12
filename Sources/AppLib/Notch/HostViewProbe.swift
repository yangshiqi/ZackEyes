import AppKit
import SwiftUI

/// Weakly exposes a SwiftUI control's backing view for native menu anchoring.
final class HostViewBox {
    weak var view: NSView?
}

struct HostViewProbe: NSViewRepresentable {
    let box: HostViewBox

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in
            self.box.view = view?.superview ?? view
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
