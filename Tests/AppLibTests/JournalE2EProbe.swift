import Testing
import Foundation
@testable import AppLib
import Shared

/// TEMPORARY — the full pipeline against this machine's real day (#214,
/// spec §8's "end-to-end must really run"). Synthetic replay proves we handle
/// what we receive; only this proves the isolation flags and the pipeline
/// work against the CLIs actually installed today.
///
/// Bounded on purpose: the heaviest claude group and the heaviest codex group
/// only, so wall clock stays in minutes. Env-gated; never runs in CI.
struct JournalE2EProbe {

    @Test("hardened runner smoke: both invocation shapes actually work")
    func runnerSmoke() throws {
        guard ProcessInfo.processInfo.environment["JOURNAL_RUNNER_SMOKE"] == "1" else { return }
        // The hardening changed both invocations — claude gained
        // --disallowedTools "*", codex switched to `-` stdin mode — and a flag
        // the CLI rejects would fail every nightly run, silently. Prove each
        // shape end to end with a trivial prompt before trusting it.
        let runner = ProcessAgentRunner()
        let prompt = """
        只输出一个 JSON 对象：{"did":["测试"],"outcome":"shipped","lessons":[]}
        不要任何其它文字。
        """
        for agent in [AgentKind.claude, AgentKind.codex] {
            let raw = try runner.run(agent: agent, prompt: prompt, timeout: 240)
            #expect(JournalDistiller.parseSliceNote(raw) != nil,
                    "\(agent) returned unparseable: \(raw.prefix(200))")
        }
    }

    @Test("collect → distill → assemble → render, for real")
    func fullPipeline() throws {
        guard ProcessInfo.processInfo.environment["JOURNAL_E2E"] == "1" else { return }
        let outDir = ProcessInfo.processInfo.environment["JOURNAL_E2E_OUT"] ?? "/tmp"
        let home = NSHomeDirectory()
        let claudeDir = URL(fileURLWithPath: home + "/.claude/projects")
        let codexDir = URL(fileURLWithPath: home + "/.codex/sessions")

        func sessionInventory() -> Set<String> {
            var out: Set<String> = []
            for root in [claudeDir, codexDir] {
                if let e = FileManager.default.enumerator(
                    at: root, includingPropertiesForKeys: nil) {
                    for case let url as URL in e where url.pathExtension == "jsonl" {
                        out.insert(url.path)
                    }
                }
            }
            return out
        }

        let before = sessionInventory()
        let started = Date()

        // Collect, then keep one group per vendor — the heaviest.
        let slices = JournalCollector.collect(
            day: Date(), claudeProjectsDir: claudeDir, codexSessionsDir: codexDir)
        func heaviest(_ agent: AgentKind) -> String? {
            var t: [String: Int] = [:]
            for s in slices where s.agent == agent {
                t[s.projectKey, default: 0] += s.tokens.distinct
            }
            return t.max { $0.value < $1.value }?.key
        }
        let keep = [heaviest(.claude).map { JournalGroupKey(agent: .claude, project: $0) },
                    heaviest(.codex).map { JournalGroupKey(agent: .codex, project: $0) }]
            .compactMap { $0 }
        let kept = slices.filter { s in
            keep.contains(JournalGroupKey(agent: s.agent, project: s.projectKey))
        }

        let distiller = JournalDistiller(runner: ProcessAgentRunner())
        let result = distiller.distill(kept)

        let assembled = JournalAssembler.assemble(
            day: Date(), slices: kept, notes: result.notes,
            config: .init(forbiddenLiterals: [home, NSUserName(),
                                             ProcessInfo.processInfo.hostName]))
        let markdown = JournalRenderer.render(assembled.note, facts: assembled.facts)

        // The self-pollution check is the E2E's real payload: the pipeline
        // just spawned real agents, and none of them may have left a
        // transcript. "New file" alone is not the test — the first run of
        // this probe flagged a session that turned out to be a background
        // security review the push itself had triggered, reading our source
        // (which is why even grepping for the prompt text inside it matched).
        // A phantom is a new transcript whose first user message IS our
        // distillation prompt; anything else is unrelated concurrent work on
        // a live machine.
        let after = sessionInventory()
        let phantoms = after.subtracting(before).filter { path in
            guard let fh = FileHandle(forReadingAtPath: path),
                  let head = try? fh.read(upToCount: 64 * 1024),
                  let text = String(data: head, encoding: .utf8)
            else { return false }
            return text.contains("把下面同一项目的") || text.contains("合并成一份。硬性要求")
        }

        var report: [String] = []
        report.append("slices total=\(slices.count) kept=\(kept.count) groups=\(keep.count)")
        report.append("notes=\(result.notes.count) failures=\(result.failures.count)")
        for f in result.failures {
            report.append("FAIL \(f.group.project) \(f.stage.rawValue): \(f.reason)")
        }
        report.append("dropped=\(assembled.dropped.count)")
        report.append(contentsOf: assembled.dropped.map { "DROP \($0)" })
        report.append("phantom transcripts=\(phantoms.count)")
        report.append(contentsOf: phantoms.map { "PHANTOM \($0)" })
        report.append("elapsed=\(Int(Date().timeIntervalSince(started)))s")

        try markdown.write(toFile: outDir + "/E2E.md", atomically: true, encoding: .utf8)
        try report.joined(separator: "\n")
            .write(toFile: outDir + "/E2E-report.txt", atomically: true, encoding: .utf8)

        #expect(phantoms.isEmpty, "spawned agents left transcripts behind")
        #expect(!result.notes.isEmpty, "no group produced a note")
    }
}
