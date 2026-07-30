import AppKit
import Shared

/// Manual "generate today's journal" entry point (#214, P1 step 7).
///
/// P1's only trigger — the nightly scheduler is P3. Deliberately thin: state
/// machine on the main actor, pipeline injected as a closure so the state
/// transitions are testable without spawning agents, and the real pipeline is
/// just the four stages already tested on their own.
@MainActor
public final class JournalManualTrigger {

    public enum State: Equatable {
        case idle
        case running
        case failed(String)
    }

    public struct RunOutput: Sendable {
        public let markdown: String
        /// Failures + sanitizer drops, for the sidecar. "今天为什么没有/少了
        /// 内容" must be answerable (spec §7) even before P3's formal run
        /// record exists.
        public let report: String

        public init(markdown: String, report: String) {
            self.markdown = markdown
            self.report = report
        }
    }

    public typealias Pipeline = @Sendable (_ day: Date) throws -> RunOutput

    public private(set) var state: State = .idle
    private let pipeline: Pipeline
    private let journalDir: String
    /// Opens the finished file. Injected so tests don't launch editors.
    private let reveal: @MainActor (URL) -> Void

    public init(
        journalDir: String = NSHomeDirectory() + "/.zackeyes/journal",
        pipeline: @escaping Pipeline = JournalManualTrigger.realPipeline,
        reveal: @escaping @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) }
    ) {
        self.journalDir = journalDir
        self.pipeline = pipeline
        self.reveal = reveal
    }

    /// Kick off a run. A second click while running is ignored — the menu
    /// shows a disabled "Generating…" item, but the menu is rebuilt per open
    /// and a race would double-spawn the whole pipeline.
    public func generateToday() {
        guard state != .running else { return }
        state = .running

        let pipeline = self.pipeline
        let dir = self.journalDir
        let day = Date()
        Task.detached(priority: .utility) {
            let name = Self.fileName(for: day)
            let result: Result<URL, Error> = Result {
                let out = try pipeline(day)
                try FileManager.default.createDirectory(
                    atPath: dir, withIntermediateDirectories: true)
                _ = try AtomicFileWriter.write(
                    Data(out.markdown.utf8), to: dir + "/" + name)
                // Sidecar is best-effort: losing the report must not fail the
                // journal it reports on.
                _ = try? AtomicFileWriter.write(
                    Data(out.report.utf8), to: dir + "/." + name + ".run.txt")
                return URL(fileURLWithPath: dir + "/" + name)
            }
            if case .failure(let error) = result {
                // A failed run must leave a trace on disk too. `.failed` lives
                // in memory; if the app quits before anyone opens the menu,
                // "why is there no journal today" (spec §7) becomes
                // unanswerable. Best-effort, same as the success sidecar.
                try? FileManager.default.createDirectory(
                    atPath: dir, withIntermediateDirectories: true)
                _ = try? AtomicFileWriter.write(
                    Data("FAILED: \(String(describing: error))".utf8),
                    to: dir + "/." + name + ".run.txt")
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                switch result {
                case .success(let url):
                    self.state = .idle
                    self.reveal(url)
                case .failure(let error):
                    self.state = .failed(String(describing: error))
                }
            }
        }
    }

    /// `2026-07-30.md` — the local calendar day, matching the collector's
    /// definition of a day.
    nonisolated public static func fileName(for day: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: day)
        return String(format: "%04d-%02d-%02d.md", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    nonisolated public static func menuLabel(for state: State) -> (title: String, enabled: Bool) {
        switch state {
        case .idle: ("Generate Today's Journal", true)
        case .running: ("Generating Journal… (takes minutes)", false)
        case .failed: ("Journal Failed — Retry", true)
        }
    }

    // MARK: - The real pipeline

    /// The four stages, exactly as tested individually. Runs for minutes and
    /// spawns real agents — always called off the main actor (the closure is
    /// `@Sendable` and the class-level `@MainActor` must not capture it).
    nonisolated public static let realPipeline: Pipeline = { day in
        let home = NSHomeDirectory()
        let slices = JournalCollector.collect(
            day: day,
            claudeProjectsDir: URL(fileURLWithPath: home + "/.claude/projects"),
            codexSessionsDir: URL(fileURLWithPath: home + "/.codex/sessions"))

        let distiller = JournalDistiller(runner: ProcessAgentRunner())
        let distilled = distiller.distill(slices)

        let assembled = JournalAssembler.assemble(
            day: day, slices: slices, notes: distilled.notes,
            config: .init(forbiddenLiterals: [
                NSHomeDirectory(), NSUserName(), ProcessInfo.processInfo.hostName,
            ]))

        let markdown = JournalRenderer.render(assembled.note, facts: assembled.facts)

        var report: [String] = []
        report.append("slices=\(slices.count) groups=\(distilled.notes.count)")
        for f in distilled.failures {
            report.append("FAIL \(f.group.project) \(f.stage.rawValue): \(f.reason)")
        }
        report.append(contentsOf: assembled.dropped.map { "DROP \($0)" })
        return RunOutput(markdown: markdown, report: report.joined(separator: "\n"))
    }
}
