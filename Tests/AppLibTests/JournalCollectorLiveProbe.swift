import Testing
import Foundation
@testable import AppLib

/// TEMPORARY — run the real collector against this machine's live transcript
/// trees and dump a summary (#214). Fixtures prove the parser matches the
/// shapes *we wrote down*; this proves it matches the shapes the agents
/// actually emit today. Env-gated so normal runs never touch $HOME.
struct JournalCollectorLiveProbe {

    @Test("collect today's real slices")
    func collectToday() throws {
        guard ProcessInfo.processInfo.environment["JOURNAL_LIVE_PROBE"] == "1" else { return }
        let outPath = ProcessInfo.processInfo.environment["JOURNAL_PROBE_OUT"]
            ?? "/tmp/journal-live-probe.txt"

        let home = NSHomeDirectory()
        let slices = JournalCollector.collect(
            day: Date(),
            claudeProjectsDir: URL(fileURLWithPath: home + "/.claude/projects"),
            codexSessionsDir: URL(fileURLWithPath: home + "/.codex/sessions"))

        var lines: [String] = ["\(slices.count) slices"]
        for s in slices {
            let mins = Int(s.endedAt.timeIntervalSince(s.startedAt)) / 60
            lines.append(
                "[\(s.agent == .codex ? "codex " : "claude")] \(s.projectKey)"
                + " · \(s.turnCount) turns · \(s.toolCallCount) tools"
                + " · \(mins)min · \(s.tokens.distinct) tok"
                + " · text \(s.transcriptText.unicodeScalars.count)")
        }
        try lines.joined(separator: "\n")
            .write(toFile: outPath, atomically: true, encoding: .utf8)
    }
}
