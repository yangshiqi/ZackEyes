import Foundation

/// Controls when the Dynamic Island panel is visible. Three states:
///
/// - `.always`     — Compact pill permanently on screen (default).
/// - `.whenActive` — Panel visible only while ≥1 session exists; auto-hides
///                   when the last session ends (#48). Still yields to
///                   `forceUiExpand`: PermissionRequest and errors always show
///                   the panel even when it would otherwise be auto-hidden.
/// - `.hidden`     — Panel off-screen unless recalled by hotkey / menu / event.
///
/// `.hidden` (and `.whenActive`) do NOT suppress event-driven expansion
/// (`forceUiExpand`) — PermissionRequest and errors always show the panel
/// to avoid leaving the user locked out of their running Claude Code commands.
public enum NotchVisibility: String, Codable, Sendable {
    case always      // Default: compact pill always visible
    case whenActive  // Visible only while ≥1 session exists; auto-hides when empty (#48)
    case hidden      // Panel off-screen unless recalled by hotkey / menu / event
}
