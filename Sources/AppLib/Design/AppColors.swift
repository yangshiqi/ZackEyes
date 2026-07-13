import AppKit
import SwiftUI

struct AppColorToken: Sendable {
    let red: Double
    let green: Double
    let blue: Double

    var color: Color {
        Color(red: red, green: green, blue: blue)
    }

    var nsColor: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
    }
}

/// Functional colors shared across the app. Theme artwork and team colors stay
/// component-owned because they identify decoration rather than application state.
enum AppColors {
    static let activity = AppColorToken(red: 79.0 / 255, green: 203.0 / 255, blue: 195.0 / 255) // #4FCBC3
    static let information = AppColorToken(red: 120.0 / 255, green: 168.0 / 255, blue: 216.0 / 255) // #78A8D8
    static let timeOverlay = AppColorToken(red: 201.0 / 255, green: 205.0 / 255, blue: 211.0 / 255) // #C9CDD3
    static let attention = AppColorToken(red: 242.0 / 255, green: 181.0 / 255, blue: 68.0 / 255) // #F2B544
    static let critical = AppColorToken(red: 240.0 / 255, green: 90.0 / 255, blue: 90.0 / 255) // #F05A5A
    static let success = AppColorToken(red: 98.0 / 255, green: 196.0 / 255, blue: 122.0 / 255) // #62C47A
    static let idle = AppColorToken(red: 142.0 / 255, green: 142.0 / 255, blue: 147.0 / 255) // #8E8E93
    static let noData = AppColorToken(red: 1, green: 1, blue: 1)

    static let claudeIdentity = AppColorToken(red: 199.0 / 255, green: 140.0 / 255, blue: 242.0 / 255) // #C78CF2
    static let codexIdentity = AppColorToken(red: 26.0 / 255, green: 217.0 / 255, blue: 140.0 / 255) // #1AD98C

    /// Physical clock treatment retained from the original Icon design.
    static let timeMarker = AppColorToken(red: 161.0 / 255, green: 107.0 / 255, blue: 36.0 / 255) // #A16B24
}
