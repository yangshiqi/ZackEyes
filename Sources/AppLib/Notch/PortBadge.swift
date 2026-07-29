import SwiftUI

/// #76 — "this session is holding a port open" badge.
///
/// The problem it solves: a dev server started inside an agent session keeps
/// running after the session goes quiet, and the next `npm run dev` fails with
/// `EADDRINUSE` with no clue which session is squatting on it. A card that
/// reads `:3000` answers that at a glance.
struct PortBadge: View {
    let ports: [Int]

    /// Badge text, or nil when there is nothing to show.
    ///
    /// Session cards are narrow and already carry project name, agent badge,
    /// risk badge and elapsed time on one row, so a session running vite + api
    /// + db summarises to `:3000 +2` rather than pushing the project name off
    /// the row. The lowest port leads because it is the recognisable one — the
    /// server the user started, not an ephemeral helper port the framework
    /// happened to open alongside it.
    static func label(for ports: [Int]) -> String? {
        guard let lowest = ports.min() else { return nil }
        let others = ports.count - 1
        return others > 0 ? ":\(lowest) +\(others)" : ":\(lowest)"
    }

    var body: some View {
        if let text = Self.label(for: ports) {
            Text(text)
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .tracking(0.2)
                .foregroundColor(AppColors.activity.color)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(AppColors.activity.color.opacity(0.15))
                .clipShape(Capsule())
                .help(ports.count > 1
                      ? "Listening on \(ports.map(String.init).joined(separator: ", "))"
                      : "Listening on port \(ports.first.map(String.init) ?? "")")
        }
    }
}
