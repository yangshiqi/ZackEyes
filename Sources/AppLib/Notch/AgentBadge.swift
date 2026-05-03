import SwiftUI
import Shared

/// Small badge identifying which AI agent owns a session card. Shown in the
/// top-right of each session card so the user can tell Claude and Codex
/// sessions apart at a glance.
struct AgentBadge: View {
    let agent: AgentKind

    /// Used to tint the PermissionRequest banner so the user knows whose
    /// approval they're acting on without having to scan the card.
    static func accentColor(for agent: AgentKind) -> Color {
        switch agent {
        case .claude:
            return Color(red: 0.78, green: 0.55, blue: 0.95)  // Anthropic-ish purple
        case .codex:
            return Color(red: 0.10, green: 0.85, blue: 0.55)  // OpenAI-ish green
        }
    }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: iconName)
                .font(.system(size: 7, weight: .bold))
            Text(label)
                .font(.system(size: 8, weight: .bold))
                .tracking(0.3)
        }
        .foregroundColor(Self.accentColor(for: agent))
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(Self.accentColor(for: agent).opacity(0.15))
        .clipShape(Capsule())
    }

    private var iconName: String {
        switch agent {
        case .claude: return "sparkle"
        case .codex:  return "circle.hexagongrid.fill"
        }
    }

    private var label: String {
        switch agent {
        case .claude: return "CLAUDE"
        case .codex:  return "CODEX"
        }
    }
}
