import AppKit
import SwiftUI

/// Standalone Uninstall Integrations card: preview → confirm → done.
/// Same non-blocking KeyablePanel pattern as `HookStatusWindow` — a modal
/// alert would block the main thread and delay delivery of a concurrent
/// permission request.
@MainActor
final class UninstallWindow: NSObject, NSWindowDelegate {
    private var panel: KeyablePanel?

    func show() {
        if let existing = panel {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let rootView = UninstallCardView(
            runPreview: { IntegrationUninstaller().preview() },
            runExecute: { IntegrationUninstaller().execute() },
            onDismiss: { [weak self] in self?.dismiss() }
        )

        let size = NSSize(width: 360, height: 360)
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
        // close() (not orderOut()) so NSApp releases the window — see
        // AboutWindow.dismiss for the leak rationale.
        panel?.close()
        panel = nil
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor [weak self] in
            self?.panel = nil
        }
    }
}

private struct UninstallCardView: View {
    let runPreview: () -> IntegrationUninstaller.Plan
    let runExecute: () -> Bool
    let onDismiss: () -> Void

    @State private var plan: IntegrationUninstaller.Plan?
    @State private var cleanupComplete = true
    @State private var done = false

    private static let danger = Color(red: 0.95, green: 0.45, blue: 0.40)

    var body: some View {
        ZStack {
            Color.black.opacity(0.6)
                .contentShape(Rectangle())
                .onTapGesture { if !done { onDismiss() } }

            VStack(alignment: .leading, spacing: 8) {
                Text(done ? "Integrations Removed" : "Uninstall Integrations")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.bottom, 4)

                if done {
                    Text(cleanupComplete
                        ? "ZackEyes-owned hooks, statusLine entries and the launcher are gone. Third-party hooks and your own files were preserved.\n\nIntegrations stay removed while the app keeps running — but relaunching ZackEyes reinstalls them. To finish removal, quit now and drag ZackEyes.app to the Trash."
                        : "Some hook entries could not be removed (a config file may be unreadable or write-protected), so the launcher was kept to avoid hook errors in your terminal.\n\nCheck the config permissions and try again, or inspect Hook Status… for details.")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.8))
                        .fixedSize(horizontal: false, vertical: true)
                } else if let plan {
                    if plan.isEmpty {
                        Text("Nothing to remove — no ZackEyes integrations found on this machine.")
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.7))
                    } else {
                        Text("This will remove:")
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.7))
                        if plan.claudeHookEvents > 0 {
                            bullet("Claude hooks on \(plan.claudeHookEvents) event\(plan.claudeHookEvents == 1 ? "" : "s")")
                        }
                        if plan.claudeOwnsStatusLine {
                            bullet("Claude statusLine entry (a wrapped third-party original is restored)")
                        }
                        if plan.codexHookEvents > 0 {
                            bullet("Codex hooks on \(plan.codexHookEvents) event\(plan.codexHookEvents == 1 ? "" : "s")")
                        }
                        ForEach(plan.files, id: \.self) { path in
                            bullet((path as NSString).abbreviatingWithTildeInPath)
                        }
                        Text("Preserved: third-party hooks & statusLine, config.json, statusline-user. Configs are backed up before every write.")
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.5))
                            .padding(.top, 4)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                HStack(spacing: 10) {
                    Spacer()
                    if done {
                        Button(action: { NSApp.terminate(nil) }) {
                            buttonLabel("Quit ZackEyes", color: Self.danger)
                        }
                        .buttonStyle(.plain)
                        .keyboardShortcut(.defaultAction)
                        // Escape hatch: removal is a stable state while the
                        // app runs (auto-reinstall only happens at launch) —
                        // the user may legitimately keep ZackEyes alive.
                        Button(action: onDismiss) {
                            buttonLabel("Close", color: .white.opacity(0.7), dim: true)
                        }
                        .buttonStyle(.plain)
                        .keyboardShortcut(.cancelAction)
                    } else {
                        if let plan, !plan.isEmpty {
                            Button {
                                cleanupComplete = runExecute()
                                done = true
                            } label: { buttonLabel("Remove Integrations", color: Self.danger) }
                            .buttonStyle(.plain)
                        }
                        Button(action: onDismiss) {
                            buttonLabel("Cancel", color: .white.opacity(0.7), dim: true)
                        }
                        .buttonStyle(.plain)
                        .keyboardShortcut(.cancelAction)
                    }
                }
                .padding(.top, 8)
            }
            .padding(20)
            .frame(width: 330)
            .frame(minHeight: 240, alignment: .top)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(white: 0.12)))
            .contentShape(Rectangle())
            .onTapGesture { /* swallow tap so backdrop doesn't dismiss */ }
        }
        .onAppear { plan = runPreview() }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("•").foregroundColor(Self.danger)
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(.white)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func buttonLabel(_ title: String, color: Color, dim: Bool = false) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(color)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(dim ? Color.white.opacity(0.08) : color.opacity(0.15))
            .cornerRadius(6)
    }
}
