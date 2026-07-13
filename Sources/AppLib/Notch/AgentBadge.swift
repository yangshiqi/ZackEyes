import SwiftUI
import Shared

/// Small badge identifying which AI agent owns a session card. Shown in the
/// top-right of each session card so the user can tell Claude and Codex
/// sessions apart at a glance.
struct AgentBadge: View {
    let agent: AgentKind
    /// Optional subagent name (codex-only, e.g. "guardian", "review"). When
    /// present, appears as a separator-divided suffix on the badge:
    /// `[CODEX • guardian]`. Helps users tell a guardian/reviewer subagent
    /// thread apart from their main user thread.
    var subagentLabel: String? = nil

    /// Used to tint the PermissionRequest banner so the user knows whose
    /// approval they're acting on without having to scan the card.
    static func accentColor(for agent: AgentKind) -> Color {
        switch agent {
        case .claude:
            return AppColors.claudeIdentity.color
        case .codex:
            return AppColors.codexIdentity.color
        }
    }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: iconName)
                .font(.system(size: 7, weight: .bold))
            Text(label)
                .font(.system(size: 8, weight: .bold))
                .tracking(0.3)
            if let subagentLabel, !subagentLabel.isEmpty {
                Text("•")
                    .font(.system(size: 8, weight: .bold))
                    .opacity(0.6)
                Text(subagentLabel.uppercased())
                    .font(.system(size: 8, weight: .bold))
                    .tracking(0.3)
                    .lineLimit(1)
            }
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
