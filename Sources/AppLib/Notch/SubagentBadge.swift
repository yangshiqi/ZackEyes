import SwiftUI

/// #40 — "this session has helpers running" badge.
///
/// Without it, a session that fans out to subagents looks identical to one
/// stuck on a single slow tool call: the card shows `Task` and then nothing
/// moves. This says how much is actually in flight.
struct SubagentBadge: View {
    let subagents: [ActiveSubagent]

    /// Longest description shown inline before eliding. The badge shares one
    /// crowded row with project name, port, agent, risk and elapsed time.
    static let maxDetailLength = 28

    /// Badge text, or nil when nothing is running.
    ///
    /// For a single subagent the description wins when we have one — "Fix
    /// dedup tests" is what the user wants to know, and "Explore" is only the
    /// fallback (#79). Past one, descriptions differ per agent and none of
    /// them fit, so the count carries the message and the detail moves to the
    /// tooltip.
    static func label(for subagents: [ActiveSubagent]) -> String? {
        guard !subagents.isEmpty else { return nil }
        if subagents.count == 1 {
            if let detail = subagents[0].detail, !detail.isEmpty {
                return truncate(detail)
            }
            if let type = subagents[0].type, !type.isEmpty { return type }
            return "1 agent"
        }
        return "\(subagents.count) agents"
    }

    private static func truncate(_ text: String) -> String {
        guard text.count > maxDetailLength else { return text }
        return text.prefix(maxDetailLength).trimmingCharacters(in: .whitespaces) + "…"
    }

    var body: some View {
        if let text = Self.label(for: subagents) {
            HStack(spacing: 3) {
                Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                    .font(.system(size: 7, weight: .bold))
                Text(text)
                    .font(.system(size: 8, weight: .bold))
                    .tracking(0.2)
                    .lineLimit(1)
            }
            .foregroundColor(AppColors.activity.color)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(AppColors.activity.color.opacity(0.15))
            .clipShape(Capsule())
            .help(tooltip)
        }
    }

    private var tooltip: String {
        // With descriptions available, list the actual work — that is the
        // whole point of #79, and the tooltip is where a fan-out's individual
        // tasks can be read without crowding the card.
        let described = subagents.compactMap { s -> String? in
            guard let detail = s.detail, !detail.isEmpty else { return nil }
            return s.type.map { "\($0): \(detail)" } ?? detail
        }
        if !described.isEmpty { return described.joined(separator: "\n") }

        let named = subagents.compactMap(\.type)
        guard !named.isEmpty else { return "\(subagents.count) subagents running" }
        // Collapse a fan-out of identical types into "3 × Explore".
        var counts: [String: Int] = [:]
        for type in named { counts[type, default: 0] += 1 }
        let parts = counts.sorted { $0.key < $1.key }.map { name, n in
            n > 1 ? "\(n) × \(name)" : name
        }
        return "Running: " + parts.joined(separator: ", ")
    }
}
