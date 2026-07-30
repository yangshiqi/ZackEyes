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
        // just spawned real agents, and not one new transcript may exist.
        let after = sessionInventory()
        let phantoms = after.subtracting(before)

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
