import Testing
import Foundation
@testable import AppLib
import Shared

/// #214 — orchestration around the only component that spawns agents.
///
/// The runner is scripted, so what is under test is everything the spawn
/// wraps: vendor isolation, batching, the strict parser, retry semantics, and
/// the failure paths. Nothing here starts a process.
struct JournalDistillerTests {

    // MARK: - Scripted runner

    /// Replays a queue of responses and records every invocation.
    final class FakeRunner: AgentRunner, @unchecked Sendable {
        struct Call { let agent: AgentKind; let prompt: String }
        private let lock = NSLock()
        private var script: [Result<String, Error>]
        private(set) var calls: [Call] = []

        init(_ script: [Result<String, Error>]) { self.script = script }

        func run(agent: AgentKind, prompt: String, timeout: TimeInterval) throws -> String {
            lock.lock(); defer { lock.unlock() }
            calls.append(Call(agent: agent, prompt: prompt))
            guard !script.isEmpty else { return Self.valid }
            return try script.removeFirst().get()
        }

        static let valid = #"{"did":["修好了"],"outcome":"shipped","lessons":[]}"#
    }

    struct Boom: Error {}

    private func slice(_ agent: AgentKind, _ project: String,
                       text: String = "user: 干活", start: TimeInterval = 0) -> SessionSlice {
        SessionSlice(agent: agent, projectKey: project,
                     startedAt: Date(timeIntervalSince1970: start),
                     endedAt: Date(timeIntervalSince1970: start + 60),
                     turnCount: 1, toolCallCount: 0,
                     tokens: SliceTokens(input: 10, output: 5),
                     transcriptText: text)
    }

    // MARK: - Vendor isolation (Q0)

    @Test("a group's engine is the group's agent — no crossing, ever")
    func vendorIsolationStructural() {
        let runner = FakeRunner([])
        let distiller = JournalDistiller(runner: runner)
        _ = distiller.distill([
            slice(.claude, "Zack", text: "user: claude 的活"),
            slice(.codex, "nova", text: "user: codex 的活"),
        ])

        // Every invocation carrying claude content ran on claude, and codex
        // content on codex. This is the whole of Q0 at the distiller level.
        for call in runner.calls {
            if call.prompt.contains("claude 的活") { #expect(call.agent == .claude) }
            if call.prompt.contains("codex 的活") { #expect(call.agent == .codex) }
        }
        #expect(runner.calls.count == 2)
    }

    @Test("a reduce call only ever sees its own project's notes")
    func reduceSeesOneProject() {
        // Two projects, each forced into two batches so both reduce.
        let big = String(repeating: "x", count: 90)
        let runner = FakeRunner([
            .success(#"{"did":["A1"],"outcome":"shipped","lessons":[]}"#),
            .success(#"{"did":["A2"],"outcome":"shipped","lessons":[]}"#),
            .success(#"{"did":["A 合并"],"outcome":"shipped","lessons":[]}"#),
            .success(#"{"did":["B1"],"outcome":"partial","lessons":[]}"#),
            .success(#"{"did":["B2"],"outcome":"partial","lessons":[]}"#),
            .success(#"{"did":["B 合并"],"outcome":"partial","lessons":[]}"#),
        ])
        let distiller = JournalDistiller(
            runner: runner, config: .init(batchScalars: 100))
        _ = distiller.distill([
            slice(.claude, "alpha", text: big, start: 0),
            slice(.claude, "alpha", text: big, start: 100),
            slice(.claude, "beta", text: big, start: 200),
            slice(.claude, "beta", text: big, start: 300),
        ])

        let reduces = runner.calls.filter { $0.prompt.contains("合并成一份") }
        #expect(reduces.count == 2)
        // Q1: no reduce prompt may mix the two projects' material.
        for r in reduces {
            let hasA = r.prompt.contains("A1")
            let hasB = r.prompt.contains("B1")
            #expect(hasA != hasB, "reduce prompt mixed projects")
        }
    }

    // MARK: - Batching

    @Test("batches respect the budget, keep time order, and never split a slice")
    func batchingRespectsBudget() {
        let s1 = slice(.claude, "p", text: String(repeating: "a", count: 50), start: 0)
        let s2 = slice(.claude, "p", text: String(repeating: "b", count: 50), start: 100)
        let s3 = slice(.claude, "p", text: String(repeating: "c", count: 50), start: 200)
        let batches = JournalDistiller.batch([s3, s1, s2], budget: 100)
        #expect(batches.map { $0.count } == [2, 1])
        #expect(batches[0][0].transcriptText.hasPrefix("a"))  // re-sorted by time
        #expect(batches[0][1].transcriptText.hasPrefix("b"))
    }

    @Test("a slice alone over budget still ships as its own batch")
    func oversizedSliceStillShips() {
        let s = slice(.claude, "p", text: String(repeating: "x", count: 500))
        let batches = JournalDistiller.batch([s], budget: 100)
        #expect(batches.count == 1)
        #expect(batches[0].count == 1)
    }

    @Test("one batch means no reduce call")
    func singleBatchSkipsReduce() {
        let runner = FakeRunner([.success(FakeRunner.valid)])
        let distiller = JournalDistiller(runner: runner)
        let result = distiller.distill([slice(.claude, "p")])
        #expect(runner.calls.count == 1)
        #expect(result.notes.count == 1)
    }

    // MARK: - Strict parsing

    @Test("only an exact JSON object with exactly the right keys parses")
    func strictParserRejectsDrift() {
        let good = #"{"did":["x"],"outcome":"shipped","lessons":["y"]}"#
        #expect(JournalDistiller.parseSliceNote(good) != nil)
        #expect(JournalDistiller.parseSliceNote("  \n" + good + "\n") != nil)

        let rejected = [
            "```json\n" + good + "\n```",                       // fenced
            "Here is the JSON:\n" + good,                        // leading prose
            good + "\nHope that helps!",                         // trailing prose
            #"{"did":["x"],"outcome":"shipped"}"#,               // missing key
            #"{"did":["x"],"outcome":"shipped","lessons":[],"extra":1}"#, // extra key
            #"{"did":"x","outcome":"shipped","lessons":[]}"#,    // wrong type
            #"{"did":["x"],"outcome":"done","lessons":[]}"#,     // unknown outcome
            #"[{"did":["x"],"outcome":"shipped","lessons":[]}]"#, // array wrapper
        ]
        for r in rejected {
            #expect(JournalDistiller.parseSliceNote(r) == nil, "should reject: \(r)")
        }
    }

    // MARK: - Retry and failure

    @Test("an unparseable first answer earns exactly one stricter retry")
    func retryOnceWithStricterPrompt() {
        let runner = FakeRunner([
            .success("here you go: {...}"),      // junk
            .success(FakeRunner.valid),          // retry succeeds
        ])
        let distiller = JournalDistiller(runner: runner)
        let result = distiller.distill([slice(.claude, "p")])

        #expect(runner.calls.count == 2)
        #expect(!runner.calls[0].prompt.contains("上一次输出无法解析"))
        #expect(runner.calls[1].prompt.contains("上一次输出无法解析"))
        #expect(result.notes.count == 1)
        #expect(result.failures.isEmpty)
    }

    @Test("two failures skip the group and record why; the rest of the day proceeds")
    func doubleFailureSkipsGroup() {
        let runner = FakeRunner([
            .failure(Boom()),                    // p1 attempt 1: spawn error
            .failure(Boom()),                    // p1 attempt 2
            .success(FakeRunner.valid),          // p2 fine
        ])
        let distiller = JournalDistiller(runner: runner)
        let result = distiller.distill([
            slice(.claude, "p1", text: String(repeating: "z", count: 40_000)),
            slice(.claude, "p2"),
        ])

        #expect(result.notes.count == 1)
        #expect(result.failures.count == 1)
        #expect(result.failures[0].stage == .map)
    }

    @Test("a failed reduce falls back to concatenating every successful batch")
    func reduceFailureFallsBack() {
        let big = String(repeating: "x", count: 90)
        let runner = FakeRunner([
            .success(#"{"did":["第一批","重复项"],"outcome":"shipped","lessons":["教训甲"]}"#),
            .success(#"{"did":["第二批","重复项"],"outcome":"blocked","lessons":["教训乙"]}"#),
            .failure(Boom()),                    // reduce attempt 1
            .failure(Boom()),                    // reduce attempt 2
        ])
        let distiller = JournalDistiller(
            runner: runner, config: .init(batchScalars: 100))
        let result = distiller.distill([
            slice(.claude, "p", text: big, start: 0),
            slice(.claude, "p", text: big, start: 100),
        ])

        // First-batch-only quietly discarded most of a busy day's map work.
        // The mechanical merge keeps everything, dedupes exact repeats, and
        // reports disagreeing outcomes as partial.
        let key = JournalGroupKey(agent: .claude, project: "p")
        #expect(result.notes[key]?.did == ["第一批", "重复项", "第二批"])
        #expect(result.notes[key]?.lessons == ["教训甲", "教训乙"])
        #expect(result.notes[key]?.outcome == .partial)
        #expect(result.failures.count == 1)
        #expect(result.failures[0].stage == .reduce)
    }

    // MARK: - Prompts

    @Test("the map prompt carries tier caps and language")
    func promptCarriesTierAndLanguage() {
        let d = JournalDistiller(
            runner: FakeRunner([]),
            config: .init(tier: .detailed, language: .english))
        let p = d.mapPrompt(for: [slice(.claude, "p")])
        #expect(p.contains("150"))
        #expect(p.contains("Write in English"))
    }
}
