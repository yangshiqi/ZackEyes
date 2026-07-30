import Foundation
import Shared

/// Facts about a day that Swift knows precisely. None of these are ever asked
/// of the model (`JournalTypes` explains why), and none of them pass through
/// `JournalSanitizer` — there is nothing to sanitize in a count.
///
/// `projectOrder` is supplied rather than derived so ordering stays a caller
/// decision: the assembler already sorts projects by token spend to decide
/// which ones get squeezed out of the length budget, and the rendered file
/// should agree with that order rather than invent a second one.
public struct DayFacts: Sendable, Equatable {
    public let projectOrder: [String]
    public let sessionCount: Int
    public let distinctTokens: Int
    public let costUSD: Double?
    /// Some models had no price entry, so `costUSD` is a floor, not a total.
    public let costIsFloor: Bool

    public init(
        projectOrder: [String], sessionCount: Int, distinctTokens: Int,
        costUSD: Double? = nil, costIsFloor: Bool = false
    ) {
        self.projectOrder = projectOrder
        self.sessionCount = sessionCount
        self.distinctTokens = distinctTokens
        self.costUSD = costUSD
        self.costIsFloor = costIsFloor
    }
}

/// `DayNote` → Markdown. Pure.
///
/// ## Why escaping lives here and not in the sanitizer
///
/// They answer different questions. The sanitizer asks *may this content
/// appear at all*; the renderer asks *how does it go into Markdown safely*.
/// The same character splits the two: `-` is an ordinary hyphen in a sentence
/// and a list marker at the start of a line. Deciding both in one layer either
/// kills normal prose or misses the injection.
///
/// ## Why escape what the sanitizer already blocks
///
/// Today the sanitizer rejects newlines, `*`, `>` and every `#` that is not an
/// issue reference, so most of what is escaped below cannot currently reach
/// here. The escaping stays anyway: the two layers must not depend on each
/// other's present settings. Loosening one character in the sanitizer later
/// must not silently turn into a structural injection, and escaping is
/// complete by construction where a blocklist is always one format behind.
public enum JournalRenderer {

    public static func render(
        _ note: DayNote,
        facts: DayFacts,
        calendar: Calendar = .current
    ) -> String {
        var out: [String] = []
        out.append("# \(dayStamp(note.day, calendar: calendar))")
        out.append("")
        out.append(factsLine(facts))

        for key in facts.projectOrder {
            guard let narratives = note.projects[key], !narratives.isEmpty else { continue }
            out.append("")
            out.append("## \(escape(key))")
            out.append("")
            for n in narratives {
                out.append("- **\(label(n.agent))** · \(n.outcome.rawValue) — \(escape(n.text))")
            }
        }

        if !note.lessons.isEmpty {
            out.append("")
            out.append("## Lessons")
            out.append("")
            for lesson in note.lessons {
                out.append("- **\(label(lesson.agent))** · \(escape(lesson.projectKey)) — \(escape(lesson.text))")
            }
        }

        out.append("")
        return out.joined(separator: "\n")
    }

    // MARK: - Facts

    static func factsLine(_ facts: DayFacts) -> String {
        var parts: [String] = []
        let projects = facts.projectOrder.count
        parts.append("\(projects) project\(projects == 1 ? "" : "s")")
        parts.append("\(facts.sessionCount) session\(facts.sessionCount == 1 ? "" : "s")")
        parts.append("\(TodayConsumptionRow.humanizeTokens(facts.distinctTokens)) tokens")
        if let cost = facts.costUSD {
            // `≥` mirrors the Today row: when a model had no price entry the
            // sum is a floor and saying "$12.34" flat would be a lie.
            parts.append(String(format: "%@$%.2f", facts.costIsFloor ? "≥" : "", cost))
        }
        return parts.joined(separator: " · ")
    }

    static func label(_ agent: AgentKind) -> String {
        agent == .codex ? "codex" : "claude"
    }

    static func dayStamp(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    // MARK: - Q3: structural escaping

    /// Neutralise every Markdown construct that could change the document's
    /// shape rather than its words.
    static func escape(_ raw: String) -> String {
        // Any line break would put the remainder at the start of a line, where
        // a plain `-` becomes a list item. Collapse first so the leading-marker
        // rule below only has one line to reason about.
        var text = raw
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")

        // Backslash first, or the escapes added below would be re-escaped.
        text = text.replacingOccurrences(of: "\\", with: "\\\\")

        for ch in ["[", "]", "(", ")", "`", "*", "_", "|", "<", ">", "~"] {
            text = text.replacingOccurrences(of: ch, with: "\\" + ch)
        }

        return escapeLeadingMarker(text)
    }

    /// `# `, `- `, `1. ` and friends only mean anything at the start of a line.
    /// Escaped rather than stripped: the character is part of what the model
    /// wrote, and Markdown renders `\-` as a plain `-`, so nothing is lost.
    static func escapeLeadingMarker(_ text: String) -> String {
        let trimmed = text.drop { $0 == " " }
        guard let first = trimmed.first else { return text }
        let leadingSpaces = String(text.prefix(text.count - trimmed.count))

        if "#-+>=".contains(first) {
            return leadingSpaces + "\\" + trimmed
        }
        // Ordered-list markers: `1.` or `1)` at the start.
        if first.isNumber {
            let digits = trimmed.prefix { $0.isNumber }
            let rest = trimmed.dropFirst(digits.count)
            if let marker = rest.first, marker == "." || marker == ")" {
                return leadingSpaces + digits + "\\" + rest
            }
        }
        return text
    }
}
