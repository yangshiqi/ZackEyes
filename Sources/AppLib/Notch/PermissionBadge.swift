import SwiftUI
import Shared

/// Small chip that surfaces a session's permission stance when it deviates
/// from the default "asks every time" mode. Hidden for the default state to
/// avoid cluttering Row 1 — the badge's value is *catching the eye* exactly
/// when the session is in a non-default mode.
///
/// Color encoding mirrors the [[user_role]] mental model of "is this thing
/// going to do something I don't expect":
///
/// - `.plan` → blue. Claude plan-mode; read-only, intentionally non-destructive.
/// - `.auto` → amber. Auto-approves within scope (claude `acceptEdits`,
///   codex `never` + `workspace-write`, codex `on-request` + `danger-full-access`).
/// - `.yolo` → red. Unconstrained (claude `bypassPermissions`, codex `never`
///   + `danger-full-access`).
struct PermissionBadge: View {
    let risk: PermissionRiskLevel

    var body: some View {
        Text(label)
            .font(.system(size: 8, weight: .bold))
            .tracking(0.3)
            .foregroundColor(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color.opacity(0.18))
            .clipShape(Capsule())
    }

    private var label: String {
        switch risk {
        case .plan: return "PLAN"
        case .auto: return "AUTO"
        case .yolo: return "YOLO"
        }
    }

    private var color: Color {
        switch risk {
        case .plan: return AppColors.information.color
        case .auto: return AppColors.attention.color
        case .yolo: return AppColors.critical.color
        }
    }
}
