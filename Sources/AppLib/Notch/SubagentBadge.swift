import SwiftUI

/// #40 — "this session has helpers running" badge.
///
/// Without it, a session that fans out to subagents looks identical to one
/// stuck on a single slow tool call: the card shows `Task` and then nothing
/// moves. This says how much is actually in flight.
struct SubagentBadge: View {
    let subagents: [ActiveSubagent]

    /// Badge text, or nil when nothing is running.
    ///
    /// A single subagent shows its type, because "Explore" says more than
    /// "1 agent" in the same width. Past one, the types are usually the same
    /// (a fan-out of identical reviewers) and would not fit anyway, so the
    /// count carries the message.
    static func label(for subagents: [ActiveSubagent]) -> String? {
        guard !subagents.isEmpty else { return nil }
        if subagents.count == 1, let type = subagents[0].type, !type.isEmpty {
            return type
        }
        return subagents.count == 1 ? "1 agent" : "\(subagents.count) agents"
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
