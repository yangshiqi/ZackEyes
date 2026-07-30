import Testing
import Foundation
@testable import AppLib
import Shared

/// #214 — where model material and Swift facts meet.
struct JournalAssemblerTests {

    private let day = Date(timeIntervalSince1970: 1_784_952_000)

    private func slice(_ agent: AgentKind, _ project: String, tokens: Int) -> SessionSlice {
        SessionSlice(agent: agent, projectKey: project,
                     startedAt: day, endedAt: day.addingTimeInterval(60),
                     turnCount: 1, toolCallCount: 0,
                     tokens: SliceTokens(input: tokens, output: 0),
                     transcriptText: "user: x")
    }

    private func note(did: [String], outcome: Outcome = .shipped,
                      lessons: [String] = []) -> SliceNote {
        SliceNote(did: did, outcome: outcome, lessons: lessons)
    }

    @Test("projects order by token spend and both vendors sit under one heading")
    func ordersByTokensAndMergesVendors() {
        let out = JournalAssembler.assemble(
            day: day,
            slices: [slice(.claude, "small", tokens: 10),
                     slice(.claude, "big", tokens: 1000),
                     slice(.codex, "big", tokens: 500)],
            notes: [
                JournalGroupKey(agent: .claude, project: "big"): note(did: ["甲做了改造"]),
                JournalGroupKey(agent: .codex, project: "big"): note(did: ["乙修了缺陷"]),
                JournalGroupKey(agent: .claude, project: "small"): note(did: ["丙补了文档"]),
            ],
            config: .init())

        #expect(out.facts.projectOrder == ["big", "small"])
        #expect(out.note.projects["big"]?.map(\.agent) == [.claude, .codex])
        #expect(out.dropped.isEmpty)
    }

    @Test("a rejected item cannot squeeze a legitimate project out of the budget")
    func rejectedItemsDontConsumeBudget() {
        // The hostile item is huge AND invalid. If budgeting ran before
        // sanitizing, it would spend the whole day's budget and push the
        // second project out — the rejected item must be weightless.
        let hostile = String(repeating: "x", count: 60) + ".swift 里改的"
        let out = JournalAssembler.assemble(
            day: day,
            slices: [slice(.claude, "first", tokens: 100),
                     slice(.claude, "second", tokens: 50)],
            notes: [
                JournalGroupKey(agent: .claude, project: "first"): note(did: [hostile, "改了正文"]),
                JournalGroupKey(agent: .claude, project: "second"): note(did: ["也改了正文"]),
            ],
            config: .init(tier: .concise))

        #expect(out.facts.projectOrder == ["first", "second"])
        #expect(out.dropped.count == 1)
        #expect(out.facts.omittedNote == nil)
    }

    @Test("over-budget projects drop whole, and the omission line speaks the journal's language")
    func squeezeOutDropsWholeProjects() {
        // Concise = 200 scalars total. Three projects at ~90 scalars each:
        // the third must vanish entirely and be counted, not truncated.
        let long = String(repeating: "改", count: 39)  // fits perItem 40
        var notes: [JournalGroupKey: SliceNote] = [:]
        var slices: [SessionSlice] = []
        for (i, p) in ["p1", "p2", "p3"].enumerated() {
            slices.append(slice(.claude, p, tokens: 1000 - i))
            notes[JournalGroupKey(agent: .claude, project: p)] =
                note(did: [long, long, long], lessons: ["\(p) 的教训"])
        }
        let out = JournalAssembler.assemble(
            day: day, slices: slices, notes: notes,
            config: .init(tier: .concise, language: .english))

        #expect(out.facts.projectOrder == ["p1"])
        #expect(out.note.projects["p3"] == nil)
        #expect(out.facts.omittedNote == "2 more projects with minor changes")
        // A squeezed project must vanish COMPLETELY: its lessons would
        // otherwise resurface by name under ## Lessons with no heading to
        // anchor them, after consuming cap slots kept projects deserved.
        // They land in `dropped` instead — a lesson lost silently is exactly
        // the failure mode this feature must not have.
        #expect(out.note.lessons.map(\.projectKey) == ["p1"])
        #expect(out.dropped.contains("[projectOmitted] p2 的教训"))
        #expect(out.dropped.contains("[projectOmitted] p3 的教训"))
    }

    @Test("lessons cap globally across projects")
    func lessonsCapGlobal() {
        var notes: [JournalGroupKey: SliceNote] = [:]
        var slices: [SessionSlice] = []
        for (i, p) in ["p1", "p2"].enumerated() {
            slices.append(slice(.claude, p, tokens: 100 - i))
            notes[JournalGroupKey(agent: .claude, project: p)] =
                note(did: ["做了事"], lessons: ["教训一", "教训二", "教训三"])
        }
        let out = JournalAssembler.assemble(
            day: day, slices: slices, notes: notes,
            config: .init(tier: .concise))  // maxLessons = 3

        #expect(out.note.lessons.count == 3)
        // Heaviest project's lessons win — same priority as everything else.
        #expect(out.note.lessons.allSatisfy { $0.projectKey == "p1" })
    }

    @Test("the project's own name survives the camel-case rule")
    func projectNamesAutoWhitelisted() {
        let out = JournalAssembler.assemble(
            day: day,
            slices: [slice(.claude, "ZackEyes", tokens: 10)],
            notes: [JournalGroupKey(agent: .claude, project: "ZackEyes"):
                        note(did: ["给 ZackEyes 加了推送"])],
            config: .init())
        #expect(out.note.projects["ZackEyes"]?.first?.text == "给 ZackEyes 加了推送")
        #expect(out.dropped.isEmpty)
    }

    @Test("renderer prints the omission line verbatim between projects and lessons")
    func rendererPlacesOmittedNote() {
        let facts = DayFacts(projectOrder: ["p"], sessionCount: 1,
                             distinctTokens: 10, omittedNote: "另有 2 个项目的零星改动")
        let note = DayNote(
            day: day,
            projects: ["p": [ProjectNarrative(agent: .claude, text: "x", outcome: .shipped)]],
            lessons: [Lesson(agent: .claude, projectKey: "p", text: "y")])
        let md = JournalRenderer.render(note, facts: facts)
        let omitted = md.range(of: "另有 2 个项目的零星改动")!.lowerBound
        #expect(md.range(of: "## p")!.lowerBound < omitted)
        #expect(omitted < md.range(of: "## Lessons")!.lowerBound)
    }
}
