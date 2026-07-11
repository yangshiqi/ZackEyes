# Unified Settings Window Implementation Plan

1. Add `SettingsViewModel`, `SettingsWindowController`, and a five-section SwiftUI settings surface.
2. Reuse existing hotkey recorder, hook health/repair, diagnostics, uninstall, and updater behavior through explicit dependencies.
3. Replace notch gear menus with direct settings-window callbacks and reduce the status-bar context menu.
4. Add focused tests for settings persistence and runtime notifications.
5. Update architecture documentation, build, test, assemble, and launch the app for visual review.

For local review, `.build/ZackEyes.app/Contents/MacOS/ZackEyes --settings` opens the shared window immediately. Normal launches remain unchanged.

Implementation must remain non-modal and must not change any NotchPanel focus or Bridge failure invariant.
