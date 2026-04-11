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
                    Button("Cancel") { onCancel() }
                        .buttonStyle(.bordered)
                        .keyboardShortcut(.cancelAction)

                    Button("Save") { save() }
                        .buttonStyle(.borderedProminent)
                        .disabled(capturedKeyCode == nil)
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
        .onAppear { startMonitor() }
        .onDisappear { stopMonitor() }
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
