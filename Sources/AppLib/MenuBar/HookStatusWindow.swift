import AppKit
import SwiftUI

/// Standalone Hook Status card: six health rows + Repair/Close buttons.
/// Shared by the status-bar context menu and the simulated-notch gear menu.
/// Same non-blocking KeyablePanel pattern as `AboutWindow` — a modal alert
/// would block the main thread and delay delivery of a concurrent
/// permission request.
@MainActor
final class HookStatusWindow: NSObject, NSWindowDelegate {
    private var panel: KeyablePanel?

    func show() {
        if let existing = panel {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let rootView = HookStatusCardView(
            runCheck: { HookHealth().check() },
            runRepair: { HookRepair.run(appPath: Bundle.main.bundlePath) },
            onDismiss: { [weak self] in self?.dismiss() }
        )

        let size = NSSize(width: 360, height: 320)
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

private struct HookStatusCardView: View {
    let runCheck: () -> HookHealthReport
    let runRepair: () -> Void
    let onDismiss: () -> Void

    @State private var report: HookHealthReport?

    private static let accent = AppColors.activity.color

    var body: some View {
        ZStack {
            Color.black.opacity(0.6)
                .contentShape(Rectangle())
                .onTapGesture { onDismiss() }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Hook Status")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                    Spacer()
                    if let report {
                        Circle()
                            .fill(report.isHealthy
                                ? AppColors.success.color
                                : AppColors.attention.color)
                            .frame(width: 8, height: 8)
                    }
                }
                .padding(.bottom, 4)

                if let report {
                    row(agentRow(title: "Claude hooks", status: report.claudeHooks,
                                 agentName: "Claude Code"))
                    row(agentRow(title: "Codex hooks", status: report.codexHooks,
                                 agentName: "Codex"))
                    row((report.bridgeLauncher ? .ok : .bad,
                         "Bridge launcher",
                         report.bridgeLauncher ? "executable" : "missing"))
                    row((report.launcherResolvesApp ? .ok : .bad,
                         "Launcher target",
                         report.launcherResolvesApp ? "this app bundle" : "not this bundle"))
                    row((report.socketReachable ? .ok : .bad,
                         "Socket",
                         report.socketReachable ? "reachable" : "unreachable"))
                    row(statusLineRow(report.statusLine))
                }

                HStack(spacing: 10) {
                    Spacer()
                    Button {
                        runRepair()
                        report = runCheck()
                    } label: {
                        Text("Repair Hooks")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(Self.accent)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 6)
                            .background(Self.accent.opacity(0.15))
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)

                    Button(action: onDismiss) {
                        Text("Close")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white.opacity(0.7))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 6)
                            .background(Color.white.opacity(0.08))
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
                }
                .padding(.top, 8)
            }
            .padding(20)
            .frame(width: 330)
            .frame(minHeight: 240, alignment: .top)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(white: 0.12))
            )
            .contentShape(Rectangle())
            .onTapGesture { /* swallow tap so backdrop doesn't dismiss */ }
        }
        .onAppear { report = runCheck() }
    }

    // MARK: - Rows

    private enum RowState {
        case ok, bad, neutral
    }

    private func row(_ model: (RowState, String, String)) -> some View {
        HStack(spacing: 8) {
            switch model.0 {
            case .ok:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundColor(AppColors.success.color)
            case .bad:
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundColor(AppColors.attention.color)
            case .neutral:
                Image(systemName: "minus.circle")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.35))
            }
            Text(model.1)
                .font(.system(size: 12))
                .foregroundColor(.white)
            Spacer()
            Text(model.2)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.55))
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func agentRow(
        title: String,
        status: HookHealthReport.AgentHooksStatus,
        agentName: String
    ) -> (RowState, String, String) {
        switch status {
        case .installed:
            return (.ok, title, "installed")
        case .partial(let missing):
            return (.bad, title, "missing \(missing.count) event\(missing.count == 1 ? "" : "s")")
        case .missing:
            return (.bad, title, "not installed")
        case .notInstalled:
            return (.neutral, title, "\(agentName) not found")
        case .unreadable:
            return (.bad, title, "config unreadable")
        }
    }

    private func statusLineRow(
        _ mode: HookHealthReport.StatusLineMode
    ) -> (RowState, String, String) {
        switch mode {
        case .direct:
            return (.ok, "statusLine", "direct")
        case .mux:
            return (.ok, "statusLine", "mux (third-party preserved)")
        case .userRenderer:
            return (.ok, "statusLine", "user renderer")
        case .thirdParty(let command):
            return (.bad, "statusLine", "third-party: \(command)")
        case .absent:
            return (.neutral, "statusLine", "not installed")
        case .unreadable:
            return (.bad, "statusLine", "unreadable")
        }
    }
}
