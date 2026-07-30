import Foundation
import Shared

/// transcript → `[SessionSlice]` for one local day (#214).
///
/// Everything downstream treats a slice as a fact, so this layer decides what
/// "a day's work on a project" means. Three decisions carry the weight:
///
/// 1. **The project comes from `cwd` inside the transcript, never from the
///    directory name.** Claude encodes the path into a directory by replacing
///    separators with hyphens, which is lossy — `-Users-ysq-Work-lab-ZackEyes`
///    could be `lab/ZackEyes` or `lab-ZackEyes`, and guessing wrong renames a
///    project in the user's permanent record.
/// 2. **Days come from per-entry timestamps, not file modification times.** A
///    session left open across midnight has work on both days, and its mtime
///    claims all of it for the second one.
/// 3. **Codex directories are UTC; the journal is local.** One local day spans
///    two UTC directories anywhere east or west of Greenwich, so scanning only
///    `YYYY/MM/DD` silently loses part of every day.
public enum JournalCollector {

    public struct Config: Sendable {
        /// Raw project name → the name to use in the journal. The point is the
        /// case where the directory name *is* the client's name.
        public let aliases: [String: String]
        /// Raw project names that never leave the machine at all.
        public let excluded: Set<String>
        /// Budget for the text handed to the model, in unicode scalars.
        public let maxTranscriptScalars: Int

        public init(
            aliases: [String: String] = [:],
            excluded: Set<String> = [],
            maxTranscriptScalars: Int = 14_000
        ) {
            self.aliases = aliases
            self.excluded = excluded
            self.maxTranscriptScalars = maxTranscriptScalars
        }
    }

    // MARK: - Pure core

    /// Last path component of a working directory — except for agent
    /// worktrees, which collapse to the repository that owns them.
    ///
    /// Found by the first live-data probe, not by design: a real day came back
    /// as fifteen "projects" where most were `issue-1714`, `main-guard`,
    /// `port-github` — all `console-ui-new/.claude/worktrees/*` checkouts.
    /// Filing them separately shatters one repository's day into micro-projects
    /// and hides what the user actually worked on. The `/.claude/worktrees/`
    /// shape is unambiguous and the owning repo sits right before it.
    public static func projectName(fromCwd cwd: String) -> String? {
        let trimmed = cwd.hasSuffix("/") ? String(cwd.dropLast()) : cwd
        if let range = trimmed.range(of: "/.claude/worktrees/") {
            let owner = String(trimmed[..<range.lowerBound])
            let name = (owner as NSString).lastPathComponent
            if !name.isEmpty && name != "/" { return name }
        }
        let name = (trimmed as NSString).lastPathComponent
        return name.isEmpty || name == "/" ? nil : name
    }

    /// Apply the exclusion list, then the alias table. `nil` means the project
    /// is excluded and must not appear anywhere downstream — not even as a
    /// count, since "1 project withheld" still leaks that it exists.
    public static func resolve(projectName raw: String, config: Config) -> String? {
        guard !config.excluded.contains(raw) else { return nil }
        return config.aliases[raw] ?? raw
    }

    /// Keep the beginning and the end, drop the middle.
    ///
    /// A session opens with what the user wanted and closes with what actually
    /// happened; the middle is tool calls and dead ends. Truncating the tail —
    /// the obvious implementation — throws away the conclusions, which is the
    /// half a journal is made of.
    public static func truncateHeadTail(_ text: String, limit: Int) -> String {
        let scalars = text.unicodeScalars
        guard scalars.count > limit else { return text }
        let marker = "\n…\n"
        let budget = max(0, limit - marker.unicodeScalars.count)
        let half = budget / 2
        let head = String(String.UnicodeScalarView(scalars.prefix(half)))
        let tail = String(String.UnicodeScalarView(scalars.suffix(budget - half)))
        return head + marker + tail
    }

    /// The UTC-dated directories that can hold entries for one local day.
    ///
    /// Always three: a local day starts in the previous UTC day east of
    /// Greenwich and ends in the next one west of it, and returning a fixed
    /// window avoids encoding the sign of the current offset — which changes
    /// under DST and is exactly the kind of thing that would silently drop an
    /// hour of work twice a year.
    public static func utcDayDirectories(
        forLocalDay day: Date, calendar: Calendar
    ) -> [DateComponents] {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let start = calendar.startOfDay(for: day)
        return (-1...1).compactMap { offset in
            guard let d = calendar.date(byAdding: .day, value: offset, to: start)
            else { return nil }
            return utc.dateComponents([.year, .month, .day], from: d)
        }
    }

    /// Whether an instant falls inside the given local day.
    public static func isSameLocalDay(_ instant: Date, as day: Date, calendar: Calendar) -> Bool {
        calendar.isDate(instant, inSameDayAs: day)
    }
}
