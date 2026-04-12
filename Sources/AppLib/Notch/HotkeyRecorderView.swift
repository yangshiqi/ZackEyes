import SwiftUI
import AppKit
import Carbon.HIToolbox

/// Key recorder overlay. Captures a key combo via NSEvent local monitor,
/// validates it has at least one modifier, and calls onSave/onCancel.
struct HotkeyRecorderView: View {
    let currentConfig: HotKeyConfig
    let onSave: (HotKeyConfig) -> Void
    let onCancel: () -> Void

    @State private var capturedKeyCode: UInt32?
    @State private var capturedModifiers: HotKeyModifiers = []
    @State private var isRecording = true
    @State private var errorMessage: String?
    @State private var monitor: Any?

    var body: some View {
        ZStack {
            // Backdrop
            Color.black.opacity(0.6)
                .contentShape(Rectangle())
                .onTapGesture { onCancel() }

            // Card
            VStack(spacing: 16) {
                Text("Change Hotkey")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)

                // Current or captured shortcut display
                Text(displayText)
                    .font(.system(size: 28, weight: .medium, design: .rounded))
                    .foregroundColor(.white)
                    .frame(height: 40)

                Text(isRecording ? "Press new shortcut..." : "")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.5))
                    .frame(height: 16)

                if let error = errorMessage {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundColor(Color(red: 0.95, green: 0.30, blue: 0.30))
                        .frame(height: 14)
                } else {
                    Spacer().frame(height: 14)
                }

                HStack(spacing: 12) {
                    Button(action: { onCancel() }) {
                        Text("Cancel")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white.opacity(0.8))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 6)
                            .background(Color.white.opacity(0.08))
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)

                    Button(action: { save() }) {
                        Text("Save")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(Color(red: 0.31, green: 0.80, blue: 0.77))
                            .padding(.horizontal, 20)
                            .padding(.vertical, 6)
                            .background(Color(red: 0.31, green: 0.80, blue: 0.77).opacity(0.15))
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                    .disabled(capturedKeyCode == nil)
                    .opacity(capturedKeyCode == nil ? 0.4 : 1.0)
                }
            }
            .padding(24)
            .frame(width: 280, height: 220)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(white: 0.12))
            )
            .contentShape(Rectangle())
            .onTapGesture { /* prevent backdrop dismiss */ }
        }
        .onAppear { activatePanel(); startMonitor() }
        .onDisappear { stopMonitor(); deactivatePanel() }
    }

    private var displayText: String {
        if let keyCode = capturedKeyCode {
            let config = HotKeyConfig(keyCode: keyCode, modifiers: capturedModifiers)
            return config.displayString
        }
        return currentConfig.displayString
    }

    private func startMonitor() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let mods = HotKeyModifiers.fromNSEventFlags(event.modifierFlags)

            // Must have at least one modifier
            if mods.isEmpty {
                errorMessage = "Must include \u{2318}, \u{2325}, \u{2303}, or \u{21E7}"
                return nil // swallow the event
            }

            errorMessage = nil
            capturedKeyCode = UInt32(event.keyCode)
            capturedModifiers = mods
            isRecording = false
            return nil // swallow the event
        }
    }

    private func stopMonitor() {
        if let mon = monitor {
            NSEvent.removeMonitor(mon)
            monitor = nil
        }
    }

    /// Temporarily allow the SimulatedNotchPanel to become key window
    /// so it can receive keyboard events for the recorder.
    private func activatePanel() {
        guard let panel = NSApp.windows.first(where: { $0 is SimulatedNotchPanel }) as? SimulatedNotchPanel else { return }
        panel.allowsKeyStatus = true
        panel.makeKey()
    }

    /// Revert the panel to its normal non-activating state.
    private func deactivatePanel() {
        guard let panel = NSApp.windows.first(where: { $0 is SimulatedNotchPanel }) as? SimulatedNotchPanel else { return }
        panel.allowsKeyStatus = false
    }

    private func save() {
        guard let keyCode = capturedKeyCode else { return }
        let newConfig = HotKeyConfig(keyCode: keyCode, modifiers: capturedModifiers)
        if newConfig == currentConfig {
            onCancel() // no change
            return
        }
        onSave(newConfig)
    }
}
