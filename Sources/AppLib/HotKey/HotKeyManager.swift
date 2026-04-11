import AppKit
import Carbon.HIToolbox

/// Registers a global hotkey via the Carbon Event Manager.
/// Default is Cmd+Shift+Z; can be customized via `register(keyCode:modifiers:onTrigger:)`.
@MainActor
public final class HotKeyManager {

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var onTrigger: (() -> Void)?
    private var currentKeyCode: UInt32 = 0
    private var currentModifiers: UInt32 = 0

    public init() {}

    /// Register a global hotkey and call `onTrigger` when pressed.
    /// - Parameters:
    ///   - keyCode: Carbon virtual key code (e.g. `UInt32(kVK_ANSI_Z)`)
    ///   - modifiers: Carbon modifier flags (e.g. `UInt32(cmdKey | shiftKey)`)
    ///   - onTrigger: Closure called when the hotkey is pressed
    public func register(
        keyCode: UInt32,
        modifiers: UInt32,
        onTrigger: @escaping () -> Void
    ) {
        self.onTrigger = onTrigger
        self.currentKeyCode = keyCode
        self.currentModifiers = modifiers

        // Install event handler (only once — it handles all hotkey IDs)
        if eventHandler == nil {
            var eventType = EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: OSType(kEventHotKeyPressed)
            )
            let selfPtr = Unmanaged.passUnretained(self).toOpaque()
            InstallEventHandler(
                GetApplicationEventTarget(),
                { _, event, userData in
                    guard let userData = userData, let event = event else { return noErr }
                    let manager = Unmanaged<HotKeyManager>.fromOpaque(userData)
                        .takeUnretainedValue()
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
        }

        registerHotKey(keyCode: keyCode, modifiers: modifiers)
    }

    /// Change the registered hotkey without changing the callback.
    /// Unregisters the old key and registers the new one.
    public func reregister(keyCode: UInt32, modifiers: UInt32) {
        unregisterHotKey()
        currentKeyCode = keyCode
        currentModifiers = modifiers
        registerHotKey(keyCode: keyCode, modifiers: modifiers)
    }

    public func unregister() {
        unregisterHotKey()
        if let eventHandler = eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
        onTrigger = nil
    }

    // MARK: - Private

    private func registerHotKey(keyCode: UInt32, modifiers: UInt32) {
        let hotKeyID = EventHotKeyID(signature: OSType(0x5A454B45) /* "ZEKE" */, id: 1)
        RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
    }

    private func unregisterHotKey() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
    }
}
