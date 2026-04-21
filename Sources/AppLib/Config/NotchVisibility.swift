import Foundation

/// Controls whether the Dynamic Island panel is persistently visible
/// (compact pill always on screen) or only appears on demand (hotkey,
/// menu-bar click, permission request, error).
///
/// `.hidden` does NOT suppress event-driven expansion (`forceUiExpand`)
/// — PermissionRequest and errors always show the panel to avoid leaving
/// the user locked out of their running Claude Code commands.
public enum NotchVisibility: String, Codable, Sendable {
    case always   // Default: compact pill always visible
    case hidden   // Panel off-screen unless recalled by hotkey / menu / event
}
