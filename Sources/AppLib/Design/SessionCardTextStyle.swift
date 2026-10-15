import SwiftUI

/// Shared typography for local and remote cards on the notch's dark surface.
enum SessionCardTextStyle {
    case title
    case context
    case metadata
    case timestamp
    case tool(isRunning: Bool)

    fileprivate var font: Font {
        switch self {
        case .title: .system(size: 13, weight: .semibold)
        case .context: .system(size: 11)
        case .metadata: .system(size: 9, weight: .medium)
        case .timestamp: .system(size: 9, weight: .medium, design: .monospaced)
        case .tool: .system(size: 11, weight: .semibold, design: .monospaced)
        }
    }

    fileprivate var color: Color {
        switch self {
        case .title: .white
        case .context: .white.opacity(0.6)
        case .metadata, .timestamp: .white.opacity(0.5)
        case .tool(let isRunning): isRunning ? AppColors.activity.color : .white.opacity(0.55)
        }
    }
}

extension View {
    func sessionCardTextStyle(_ style: SessionCardTextStyle) -> some View {
        font(style.font).foregroundColor(style.color)
    }
}
