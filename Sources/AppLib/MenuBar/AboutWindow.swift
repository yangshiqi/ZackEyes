import AppKit
import SwiftUI

/// Non-blocking About card. Replaces `NSAlert.runModal()` which would
/// block the main thread — starving the `@MainActor` socket handler and
/// delaying delivery of a concurrent permission request.
///
/// Same pattern as `HotkeyRecorderWindow`: borderless, nonactivating,
/// keyable panel hosting a SwiftUI card. `NSWindowDelegate` +
/// `windowWillClose` clears the reference so the next `show()` re-creates
/// the panel instead of early-returning against a hidden window.
@MainActor
final class AboutWindow: NSObject, NSWindowDelegate {
    private var panel: KeyablePanel?

    func show() {
        if let existing = panel {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let rootView = AboutCardView(onDismiss: { [weak self] in
            self?.dismiss()
        })

        let size = NSSize(width: 280, height: 256)
        let screenFrame = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? .zero
        let origin = NSPoint(
            x: screenFrame.midX - size.width / 2,
            y: screenFrame.midY - size.height / 2
        )
        let hosting = NSHostingView(rootView: rootView)
        hosting.frame = NSRect(origin: .zero, size: size)

        let p = KeyablePanel(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        p.contentView = hosting
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = .floating
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.delegate = self
        p.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        panel = p
    }

    private func dismiss() {
        // close() removes the window from NSApp.windows so ARC can reclaim it.
        // orderOut() alone would only hide — NSApp retains the window strongly,
        // leaking it every time the user opens/dismisses this panel.
        // isReleasedWhenClosed stays false (ARC-safe): ARC releases via our
        // `panel = nil`, not via NSWindow's own release path.
        panel?.close()
        panel = nil
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor [weak self] in
            self?.panel = nil
        }
    }
}

private struct AboutCardView: View {
    let onDismiss: () -> Void

    private static let websiteURL = URL(string: "https://zackeyes.vercel.app/")!

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.6)
                .contentShape(Rectangle())
                .onTapGesture { onDismiss() }

            VStack(spacing: 14) {
                icon
                    .frame(width: 64, height: 64)

                Text("ZackEyes")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white)

                Text("Version \(appVersion)")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.6))

                Button {
                    NSWorkspace.shared.open(Self.websiteURL)
                } label: {
                    Text("zackeyes.vercel.app")
                        .font(.system(size: 12))
                        .foregroundColor(AppColors.activity.color)
                }
                .buttonStyle(.plain)

                Button(action: onDismiss) {
                    Text("OK")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(AppColors.activity.color)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 6)
                        .background(AppColors.activity.color.opacity(0.15))
                        .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
            }
            .padding(20)
            .frame(width: 240, height: 236)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(white: 0.12))
            )
            .contentShape(Rectangle())
            .onTapGesture { /* swallow tap so backdrop doesn't dismiss */ }
        }
    }

    @ViewBuilder
    private var icon: some View {
        if let nsImage = NSImage(named: "AppIcon") {
            Image(nsImage: nsImage)
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 12))
        } else {
            Image(systemName: "sparkles")
                .font(.system(size: 36))
                .foregroundColor(.white.opacity(0.7))
        }
    }
}

// KeyablePanel is defined once in MenuBar/KeyablePanel.swift and shared
// with HotkeyRecorderWindow.
