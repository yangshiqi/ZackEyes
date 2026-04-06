import AppKit
import Carbon.HIToolbox

/// Registers a global hotkey via the Carbon Event Manager.
/// Use Cmd+Shift+Z by default to toggle the popover.
@MainActor
public final class HotKeyManager {

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var onTrigger: (() -> Void)?

    public init() {}

    /// Register Cmd+Shift+Z and call `onTrigger` when pressed.
    public func register(onTrigger: @escaping () -> Void) {
        self.onTrigger = onTrigger

        // Install event handler
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: OSType(kEventHotKeyPressed)
        )
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let userData = userData, let event = event else { return noErr }
                let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
                Task { @MainActor in
                    manager.onTrigger?()
                }
                _ = event
                return noErr
            },
            1,
            &eventType,
            selfPtr,
            &eventHandler
        )

        // Register Cmd+Shift+Z
        let hotKeyID = EventHotKeyID(signature: OSType(0x5A454B45) /* "ZEKE" */, id: 1)
        let keyCode = UInt32(kVK_ANSI_Z)
        let modifiers = UInt32(cmdKey | shiftKey)

        RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
    }

    public func unregister() {
        if let hotKeyRef = hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let eventHandler = eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
        onTrigger = nil
    }

    // Note: Carbon cleanup must be done via explicit `unregister()` call
    // from MainActor context (deinit cannot access non-Sendable Carbon types).
}
