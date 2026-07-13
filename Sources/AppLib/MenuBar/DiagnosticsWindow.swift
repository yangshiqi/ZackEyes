import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Standalone Diagnostics card: shows the redacted plain-text report with
/// Copy / Save… / Close actions. Shared by the status-bar context menu and
/// the simulated-notch gear menu.
/// Same non-blocking KeyablePanel pattern as `HookStatusWindow`.
@MainActor
final class DiagnosticsWindow: NSObject, NSWindowDelegate {
    private var panel: KeyablePanel?
    private let makeReport: () -> String

    init(makeReport: @escaping () -> String) {
        self.makeReport = makeReport
        super.init()
    }

    func show() {
        if let existing = panel {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let rootView = DiagnosticsCardView(
            makeReport: makeReport,
            onDismiss: { [weak self] in self?.dismiss() }
        )

        let size = NSSize(width: 520, height: 460)
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
        panel?.close()
        panel = nil
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor [weak self] in
            self?.panel = nil
        }
    }
}

private struct DiagnosticsCardView: View {
    let makeReport: () -> String
    let onDismiss: () -> Void

    @State private var report: String = ""
    @State private var copied: Bool = false

    private static let accent = AppColors.activity.color

    var body: some View {
        ZStack {
            Color.black.opacity(0.6)
                .contentShape(Rectangle())
                .onTapGesture { onDismiss() }

            VStack(alignment: .leading, spacing: 12) {
                Text("Diagnostics — safe to attach to a GitHub issue")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.bottom, 2)

                ScrollView {
                    Text(report)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.white.opacity(0.85))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: .infinity)

                HStack(spacing: 10) {
                    Spacer()

                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(report, forType: .string)
                        copied = true
                    } label: {
                        buttonLabel(copied ? "Copied ✓" : "Copy", color: Self.accent)
                    }
                    .buttonStyle(.plain)

                    Button {
                        saveReport()
                    } label: {
                        buttonLabel("Save…", color: .white.opacity(0.7))
                    }
                    .buttonStyle(.plain)

                    Button(action: onDismiss) {
                        buttonLabel("Close", color: .white.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
                }
                .padding(.top, 4)
            }
            .padding(20)
            .frame(width: 480)
            .frame(minHeight: 380, alignment: .top)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(white: 0.12))
            )
            .contentShape(Rectangle())
            .onTapGesture { /* swallow tap so backdrop doesn't dismiss */ }
        }
        .onAppear { report = makeReport() }
    }

    private func saveReport() {
        let sp = NSSavePanel()
        sp.nameFieldStringValue = "zackeyes-diagnostics.txt"
        sp.allowedContentTypes = [.plainText]
        sp.begin { resp in
            if resp == .OK, let url = sp.url {
                do {
                    try report.write(to: url, atomically: true, encoding: .utf8)
                } catch {
                    NSLog("ZackEyes: failed to save diagnostics report: \(error)")
                }
            }
        }
    }

    @ViewBuilder
    private func buttonLabel(_ title: String, color: Color) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(color)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(color.opacity(0.15))
            .cornerRadius(6)
    }
}
