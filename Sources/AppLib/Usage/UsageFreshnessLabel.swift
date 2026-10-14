import SwiftUI
import Shared

/// #45 (staleness slice) — pure age/stale logic for usage data freshness,
/// kept separate from the view so it's unit-testable with an injected `now`.
enum UsageFreshness {
    /// After this long with no fresh rate-limit reading, the displayed usage is
    /// flagged as possibly out of date. 15 min mirrors the codex active window
    /// (`UsageTracker.codexActiveWindowSeconds`): if nothing has reported in
    /// that long, the user is idle and the numbers may have drifted.
    static let staleAfter: TimeInterval = 15 * 60

    static func isStale(now: Date, lastUpdated: Date) -> Bool {
        now.timeIntervalSince(lastUpdated) >= staleAfter
    }

    /// Compact "how long ago": "just now", "3m ago", "2h ago", "1d ago".
    static func ageString(now: Date, lastUpdated: Date) -> String {
        let secs = max(0, now.timeIntervalSince(lastUpdated))
        if secs < 60 { return "just now" }
        let mins = Int(secs) / 60
        if mins < 60 { return "\(mins)m ago" }
        let hours = mins / 60
        if hours < 24 { return "\(hours)h ago" }
        return "\(hours / 24)d ago"
    }
}

/// #45 — usage freshness footnote shown under the expanded usage bars. Renders
/// nothing without a `lastUpdated` timestamp. Subtle gray when fresh; amber with
/// a warning glyph once the data is stale, so an idle session's pinned numbers
/// (and the #86 ETA derived from them) aren't mistaken for live values.
public struct UsageFreshnessLabel: View {
    let lastUpdated: Date

    public init(lastUpdated: Date) {
        self.lastUpdated = lastUpdated
    }

    public var body: some View {
        let now = Date()
        let stale = UsageFreshness.isStale(now: now, lastUpdated: lastUpdated)
        HStack(spacing: 3) {
            Image(systemName: stale ? "exclamationmark.triangle.fill" : "clock")
                .font(.system(size: 8))
            Text("updated \(UsageFreshness.ageString(now: now, lastUpdated: lastUpdated))")
                .font(.system(size: 9))
        }
        .foregroundColor(stale
            ? AppColors.attention.color
            : .white.opacity(0.35))
    }
}

/// A reading's age belongs to its source agent, independent of the selected
/// Used/Left presentation. Missing values are rendered by callers as before.
struct QuotaReadingPresentation {
    let text: String
    let help: String

    init(text: String, lastUpdated: Date?, now: Date) {
        let stale = lastUpdated.map { UsageFreshness.isStale(now: now, lastUpdated: $0) } ?? false
        self.text = (stale ? "~" : "") + text
        self.help = lastUpdated.map { "last updated " + UsageFreshness.ageString(now: now, lastUpdated: $0) }
            ?? "last update unavailable"
    }
}

extension UsageTracker.Snapshot {
    func quotaLastUpdated(for agent: AgentKind) -> Date? {
        agent == .codex ? codexLastUpdated : lastUpdated
    }
}

/// The clock keeps a pinned reading honest even without incoming agent events.
/// Typography and quota color are inherited from the surrounding surface.
struct QuotaReadingText: View {
    let text: String
    let lastUpdated: Date?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let reading = QuotaReadingPresentation(text: text, lastUpdated: lastUpdated, now: context.date)
            Text(reading.text)
                .help(reading.help)
                .accessibilityHint(reading.help)
        }
    }
}
