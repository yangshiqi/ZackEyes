import SwiftUI

/// #77 — branch + uncommitted-work indicator on a session card.
///
/// Renders as `⑂ feat/x ●3`. Sits on the card's metadata row rather than the
/// title row: the title row already carries project name, port badge, agent,
/// risk and elapsed time, and branch names are long enough to push those off.
struct GitBadge: View {
    let snapshot: GitStatusReader.Snapshot

    /// Dirty marker, or nil for a clean tree.
    ///
    /// Capped because a repo mid-rebase can report hundreds of changes and the
    /// exact number stops carrying information well before that — "a lot" is
    /// the whole message at that point.
    static func dirtyLabel(for count: Int) -> String? {
        guard count > 0 else { return nil }
        return count > 99 ? "●99+" : "●\(count)"
    }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: snapshot.isDetached
                  ? "point.topleft.down.curvedto.point.bottomright.up"
                  : "arrow.triangle.branch")
                .font(.system(size: 7, weight: .semibold))
            Text(snapshot.branch)
                .lineLimit(1)
                .truncationMode(.middle)
            if let dirty = Self.dirtyLabel(for: snapshot.dirtyCount) {
                Text(dirty)
                    .foregroundColor(AppColors.attention.color.opacity(0.9))
            }
        }
        .font(.system(size: 9, weight: .medium))
        .foregroundColor(.white.opacity(0.45))
        .help(tooltip)
    }

    private var tooltip: String {
        var parts: [String] = [
            snapshot.isDetached ? "Detached at \(snapshot.branch)" : "On \(snapshot.branch)"
        ]
        if snapshot.dirtyCount > 0 {
            parts.append("\(snapshot.dirtyCount) uncommitted change\(snapshot.dirtyCount == 1 ? "" : "s")")
        }
        if snapshot.ahead > 0 { parts.append("\(snapshot.ahead) ahead") }
        if snapshot.behind > 0 { parts.append("\(snapshot.behind) behind") }
        return parts.joined(separator: " · ")
    }
}
