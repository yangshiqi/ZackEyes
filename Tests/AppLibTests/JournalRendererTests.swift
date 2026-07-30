import Testing
import Foundation
@testable import AppLib
import Shared

/// #214 — `DayNote` → Markdown, and the Q3 boundary.
///
/// The adversarial half matters most. With no human review gate, a model that
/// emits `# Deploy keys` produces a real heading in a file that gets pushed to
/// a repo. Filtering that would mean another blocklist to keep extending;
/// escaping is complete by construction, so these tests assert on the *shape*
/// of the output — no new heading, list item or link, whatever the input.
struct JournalRendererTests {

    private let day = Date(timeIntervalSince1970: 1_785_000_000)  // 2026-07-25 UTC
    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func note(
        projects: [String: [ProjectNarrative]] = [:],
        lessons: [Lesson] = []
    ) -> DayNote {
        DayNote(day: day, projects: projects, lessons: lessons)
    }

    private func facts(_ order: [String], sessions: Int = 2, tokens: Int = 1_400_000,
                       cost: Double? = 12.34, floor: Bool = false) -> DayFacts {
        DayFacts(projectOrder: order, sessionCount: sessions,
                 distinctTokens: tokens, costUSD: cost, costIsFloor: floor)
    }

    // MARK: - Q3 adversarial

    @Test("a model-written heading cannot become a heading")
    func headingIsNeutralised() {
        let out = JournalRenderer.render(
            note(projects: ["Proj": [.init(agent: .claude, text: "# Deploy keys rotated", outcome: .shipped)]]),
            facts: facts(["Proj"]), calendar: utc)
        // The only headings in the document are the ones the renderer wrote.
        let headings = out.split(separator: "\n").filter { $0.hasPrefix("#") }
        #expect(headings == ["# 2026-07-25", "## Proj"])
        #expect(out.contains("\\# Deploy keys rotated"))
    }

    @Test("a model-written list marker cannot start a new list item")
    func listMarkerIsNeutralised() {
        for hostile in ["- item one", "+ item two", "1. item three", "2) item four", "> quoted"] {
            let out = JournalRenderer.render(
                note(projects: ["P": [.init(agent: .codex, text: hostile, outcome: .partial)]]),
                facts: facts(["P"]), calendar: utc)
            let bullets = out.split(separator: "\n").filter { $0.hasPrefix("- ") }
            #expect(bullets.count == 1, "extra list item from: \(hostile)")
        }
    }

    @Test("link and image syntax cannot survive as a link")
    func linkSyntaxIsNeutralised() {
        let out = JournalRenderer.render(
            note(projects: ["P": [.init(agent: .claude,
                                        text: "see [docs](http:example) and ![img](x)",
                                        outcome: .explored)]]),
            facts: facts(["P"]), calendar: utc)
        #expect(!out.contains("](")) // no intact link construct anywhere
        #expect(out.contains("\\[docs\\]"))
    }

    @Test("newlines cannot smuggle content to the start of a line")
    func newlinesCollapse() {
        let out = JournalRenderer.render(
            note(projects: ["P": [.init(agent: .codex,
                                        text: "first line\n# Injected\n- and a bullet",
                                        outcome: .shipped)]]),
            facts: facts(["P"]), calendar: utc)
        let headings = out.split(separator: "\n").filter { $0.hasPrefix("#") }
        #expect(headings == ["# 2026-07-25", "## P"])
        #expect(out.split(separator: "\n").filter { $0.hasPrefix("- ") }.count == 1)
    }

    @Test("emphasis, code spans and tables cannot change the shape")
    func inlineConstructsNeutralised() {
        let out = JournalRenderer.render(
            note(projects: ["P": [.init(agent: .claude,
                                        text: "used `rm` and *bold* and a|table|row",
                                        outcome: .blocked)]]),
            facts: facts(["P"]), calendar: utc)
        #expect(out.contains("\\`rm\\`"))
        #expect(out.contains("\\*bold\\*"))
        #expect(out.contains("a\\|table\\|row"))
    }

    @Test("a backslash in the text does not escape our escapes")
    func backslashHandledFirst() {
        // If `\` were escaped after `[`, the input `\[` would render as an
        // escaped backslash followed by a live bracket.
        let out = JournalRenderer.render(
            note(projects: ["P": [.init(agent: .codex, text: "path \\[x]", outcome: .shipped)]]),
            facts: facts(["P"]), calendar: utc)
        #expect(out.contains("\\\\\\[x\\]"))
    }

    @Test("a hostile project name is escaped too")
    func projectNameEscaped() {
        // Project keys come from directory names, which the user controls but
        // did not write with Markdown in mind.
        let out = JournalRenderer.render(
            note(projects: ["we[ird](x)": [.init(agent: .claude, text: "ok", outcome: .shipped)]]),
            facts: facts(["we[ird](x)"]), calendar: utc)
        #expect(out.contains("## we\\[ird\\]\\(x\\)"))
        #expect(!out.contains("]("))
    }

    // MARK: - Shape

    @Test("renders projects in the order the caller supplied")
    func respectsProjectOrder() {
        // Ordering is the assembler's decision (token spend), not the
        // renderer's — the file must not disagree with the squeeze-out order.
        let n = note(projects: [
            "Alpha": [.init(agent: .claude, text: "a", outcome: .shipped)],
            "Zulu": [.init(agent: .codex, text: "z", outcome: .shipped)],
        ])
        let out = JournalRenderer.render(n, facts: facts(["Zulu", "Alpha"]), calendar: utc)
        let zulu = out.range(of: "## Zulu")!.lowerBound
        let alpha = out.range(of: "## Alpha")!.lowerBound
        #expect(zulu < alpha)
    }

    @Test("a project in the order list but absent from the note is skipped")
    func missingProjectSkipped() {
        let out = JournalRenderer.render(
            note(projects: ["P": [.init(agent: .codex, text: "x", outcome: .shipped)]]),
            facts: facts(["P", "Ghost"]), calendar: utc)
        #expect(!out.contains("Ghost"))
    }

    @Test("both vendors' narratives appear under one project, each labelled")
    func provenanceLabelledPerNarrative() {
        // This is what makes "content only goes back to the vendor that wrote
        // it" checkable from the artifact rather than from our copy.
        let out = JournalRenderer.render(
            note(projects: ["P": [
                .init(agent: .claude, text: "claude side", outcome: .shipped),
                .init(agent: .codex, text: "codex side", outcome: .explored),
            ]]),
            facts: facts(["P"]), calendar: utc)
        #expect(out.contains("- **claude** · shipped — claude side"))
        #expect(out.contains("- **codex** · explored — codex side"))
    }

    @Test("lessons carry vendor and project")
    func lessonsCarryProvenance() {
        let out = JournalRenderer.render(
            note(lessons: [.init(agent: .codex, projectKey: "P", text: "measure first")]),
            facts: facts([]), calendar: utc)
        #expect(out.contains("## Lessons"))
        #expect(out.contains("- **codex** · P — measure first"))
    }

    @Test("no Lessons section when there are none")
    func lessonsSectionOmitted() {
        let out = JournalRenderer.render(
            note(projects: ["P": [.init(agent: .codex, text: "x", outcome: .shipped)]]),
            facts: facts(["P"]), calendar: utc)
        #expect(!out.contains("## Lessons"))
    }

    @Test("an empty day still renders a dated file with its facts")
    func emptyDayStillRenders() {
        // Degrading to a stub beats writing nothing: the user asked why there
        // was no work today, and an empty file answers that.
        let out = JournalRenderer.render(
            note(), facts: facts([], sessions: 0, tokens: 0, cost: nil), calendar: utc)
        #expect(out.hasPrefix("# 2026-07-25"))
        #expect(out.contains("0 projects · 0 sessions · 0 tokens"))
    }

    // MARK: - Facts line

    @Test("facts line pluralises and abbreviates")
    func factsLineFormatting() {
        #expect(JournalRenderer.factsLine(facts(["A"], sessions: 1, tokens: 1_400_000, cost: 12.34))
                == "1 project · 1 session · 1.4M tokens · $12.34")
        #expect(JournalRenderer.factsLine(facts(["A", "B"], sessions: 3, tokens: 340_000, cost: nil))
                == "2 projects · 3 sessions · 340K tokens")
    }

    @Test("an unpriced model makes the cost a floor, not a total")
    func floorCostMarked() {
        let line = JournalRenderer.factsLine(
            facts(["A"], sessions: 1, tokens: 1000, cost: 5.0, floor: true))
        #expect(line.contains("≥$5.00"))
    }
}
