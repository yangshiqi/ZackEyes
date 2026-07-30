import Foundation
import Shared

// MARK: - Distiller (#214)
//
// The only component that ever spawns an agent CLI. Everything here except
// the runner is pure, and the runner is injected, so the orchestration —
// batching, vendor isolation, retry, strict parsing — is testable without
// spawning anything.

/// One (vendor × project) bucket. This is the unit of both map batching and
/// reduce, and it is what makes the two hard promises structural:
///
/// - **Never cross vendors** (plan Q0): the engine for a group *is* the
///   group's agent. There is no engine-selection code to get wrong.
/// - **No cross-project bleed** (plan Q1): a reduce call only ever sees one
///   project's notes, so a model cannot write project A's details into
///   project B — there is no B in its input.
public struct JournalGroupKey: Hashable, Sendable {
    public let agent: AgentKind
    public let project: String

    public init(agent: AgentKind, project: String) {
        self.agent = agent
        self.project = project
    }
}

/// Length tiers (spec §5.2). Tiers change length only, never granularity.
public enum JournalTier: String, Sendable {
    case concise, moderate, detailed

    var perItemScalars: Int {
        switch self {
        case .concise: 40
        case .moderate: 80
        case .detailed: 150
        }
    }

    var maxLessons: Int {
        switch self {
        case .concise: 3
        case .moderate: 5
        case .detailed: 8
        }
    }

    /// Whole-day narrative budget (spec §5.2). A hard cap: projects that
    /// exceed it are dropped whole and counted in the omission line.
    var totalScalars: Int {
        switch self {
        case .concise: 200
        case .moderate: 500
        case .detailed: 1200
        }
    }
}

/// Journal language (spec D11). Only scripts that are already inside the
/// sanitizer's whitelist and covered by a false-positive corpus may appear
/// here — adding a language is not adding a prompt string.
public enum JournalLanguage: String, Sendable {
    case chinese, english, japanese

    var instruction: String {
        switch self {
        case .chinese: "用中文"
        case .english: "Write in English"
        case .japanese: "日本語で書く"
        }
    }
}

/// Executes one agent CLI invocation. The real implementation spawns a
/// process; tests script this.
public protocol AgentRunner: Sendable {
    /// Returns the raw textual output (stdout for claude, the `-o` file for
    /// codex). Throws on timeout or nonzero exit.
    func run(agent: AgentKind, prompt: String, timeout: TimeInterval) throws -> String
}

public struct JournalDistiller {

    public struct Config: Sendable {
        public var tier: JournalTier
        public var language: JournalLanguage
        /// Spec §7 said 90s; a real distillation measured over two minutes,
        /// and this runs at 23:30 with nobody waiting. Generous is free.
        public var timeout: TimeInterval
        /// Transcript budget per map call. Batches never split a slice.
        public var batchScalars: Int

        public init(tier: JournalTier = .moderate,
                    language: JournalLanguage = .chinese,
                    timeout: TimeInterval = 300,
                    batchScalars: Int = 30_000) {
            self.tier = tier
            self.language = language
            self.timeout = timeout
            self.batchScalars = batchScalars
        }
    }

    public struct Failure: Sendable, Equatable {
        public enum Stage: String, Sendable { case map, reduce }
        public let group: JournalGroupKey
        public let stage: Stage
        public let reason: String
    }

    public struct DayResult: Sendable {
        /// One merged note per (vendor × project) that survived.
        public let notes: [JournalGroupKey: SliceNote]
        public let failures: [Failure]
    }

    let runner: AgentRunner
    let config: Config

    public init(runner: AgentRunner, config: Config = Config()) {
        self.runner = runner
        self.config = config
    }

    // MARK: Orchestration

    /// Map every group's slices to notes, reduce multi-batch groups, return
    /// one note per surviving group. A group that fails wholesale is reported
    /// and skipped; the rest of the day proceeds (spec §7).
    public func distill(_ slices: [SessionSlice]) -> DayResult {
        var notes: [JournalGroupKey: SliceNote] = [:]
        var failures: [Failure] = []

        for (group, groupSlices) in Self.grouped(slices) {
            let batches = Self.batch(groupSlices, budget: config.batchScalars)
            var batchNotes: [SliceNote] = []
            for batch in batches {
                let prompt = mapPrompt(for: batch)
                if let note = runWithRetry(agent: group.agent, prompt: prompt,
                                           group: group, stage: .map,
                                           failures: &failures) {
                    batchNotes.append(note)
                }
            }
            guard !batchNotes.isEmpty else { continue }

            if batchNotes.count == 1 {
                // One batch needs no synthesis; a spawn would only give the
                // model a second chance to drift.
                notes[group] = batchNotes[0]
            } else {
                let prompt = reducePrompt(for: batchNotes)
                if let merged = runWithRetry(agent: group.agent, prompt: prompt,
                                             group: group, stage: .reduce,
                                             failures: &failures) {
                    notes[group] = merged
                } else {
                    // Reduce failed twice: fall back to a Swift concatenation
                    // of every successful batch, not to the first batch alone.
                    // The first-batch version quietly discarded most of a busy
                    // day's map work — the exact silent data loss the failure
                    // record exists to prevent. Concatenation loses the LLM's
                    // dedup/synthesis, never its material; the assembler's
                    // sanitizer and budget still apply downstream.
                    notes[group] = Self.concatenate(batchNotes)
                }
            }
        }
        return DayResult(notes: notes, failures: failures)
    }

    /// One attempt, then one retry with a terser, stricter prompt (spec §7).
    /// A second failure records and returns nil — the same content re-asked a
    /// third time produces the same failure in different words.
    private func runWithRetry(
        agent: AgentKind, prompt: String, group: JournalGroupKey,
        stage: Failure.Stage, failures: inout [Failure]
    ) -> SliceNote? {
        for attempt in 0..<2 {
            let effective = attempt == 0 ? prompt : prompt + Self.strictSuffix
            do {
                let raw = try runner.run(agent: agent, prompt: effective,
                                         timeout: config.timeout)
                if let note = Self.parseSliceNote(raw) { return note }
                if attempt == 1 {
                    failures.append(Failure(group: group, stage: stage,
                                            reason: "unparseable output"))
                }
            } catch {
                if attempt == 1 {
                    failures.append(Failure(group: group, stage: stage,
                                            reason: String(describing: error)))
                }
            }
        }
        return nil
    }

    /// Mechanical merge of batch notes, used when the LLM reduce is
    /// unavailable. Exact-duplicate strings collapse; everything else is
    /// kept in batch order. Outcome: unanimous value, else `.partial` —
    /// a day whose batches disagree is by definition partially done.
    static func concatenate(_ batchNotes: [SliceNote]) -> SliceNote {
        var seenDid = Set<String>(), seenLessons = Set<String>()
        var did: [String] = [], lessons: [String] = []
        for note in batchNotes {
            for d in note.did where seenDid.insert(d).inserted { did.append(d) }
            for l in note.lessons where seenLessons.insert(l).inserted { lessons.append(l) }
        }
        let outcomes = Set(batchNotes.map(\.outcome))
        return SliceNote(did: did,
                         outcome: outcomes.count == 1 ? outcomes.first! : .partial,
                         lessons: lessons)
    }

    // MARK: Grouping and batching (pure)

    static func grouped(_ slices: [SessionSlice]) -> [(JournalGroupKey, [SessionSlice])] {
        var buckets: [JournalGroupKey: [SessionSlice]] = [:]
        for s in slices {
            buckets[JournalGroupKey(agent: s.agent, project: s.projectKey), default: []]
                .append(s)
        }
        // Deterministic order: heaviest group first, so if anything budgetary
        // ever truncates, it truncates the tail-end small stuff.
        return buckets.sorted {
            let l = $0.value.reduce(0) { $0 + $1.tokens.distinct }
            let r = $1.value.reduce(0) { $0 + $1.tokens.distinct }
            return l != r ? l > r : $0.key.project < $1.key.project
        }
    }

    /// Pack time-ordered slices into batches under the scalar budget without
    /// ever splitting a slice. A slice alone over budget still ships as its
    /// own batch — the collector already capped slice text, so this only
    /// happens if someone raises that cap past this one.
    static func batch(_ slices: [SessionSlice], budget: Int) -> [[SessionSlice]] {
        var batches: [[SessionSlice]] = []
        var current: [SessionSlice] = []
        var used = 0
        for s in slices.sorted(by: { $0.startedAt < $1.startedAt }) {
            let cost = s.transcriptText.unicodeScalars.count
            if !current.isEmpty && used + cost > budget {
                batches.append(current)
                current = []
                used = 0
            }
            current.append(s)
            used += cost
        }
        if !current.isEmpty { batches.append(current) }
        return batches
    }

    // MARK: Prompts (pure)

    func mapPrompt(for batch: [SessionSlice]) -> String {
        let sessions = batch.enumerated().map { i, s in
            "=== 会话 \(i + 1)（\(s.turnCount) 轮）===\n\(s.transcriptText)"
        }.joined(separator: "\n\n")

        return """
        把下面同一项目的 \(batch.count) 个开发会话提炼成工作日志条目。硬性要求：
        - 只写项目/任务层面做了什么，绝不出现代码、文件名、路径、URL、命令行、函数名、类名
        - did 最多 3 条，每条不超过 \(config.tier.perItemScalars) 个字
        - lessons 只写因为踩坑而学到的东西，最多 \(config.tier.maxLessons) 条、每条不超过 \(config.tier.perItemScalars) 个字，没有就留空数组
        - \(config.language.instruction)
        - 只输出一个 JSON 对象：{"did":["…"],"outcome":"shipped|partial|blocked|explored","lessons":["…"]}，不要任何其它文字或代码块标记

        \(sessions)
        """
    }

    func reducePrompt(for notes: [SliceNote]) -> String {
        let payload = notes.map { note in
            "did: \(note.did.joined(separator: " / "))"
            + " | outcome: \(note.outcome.rawValue)"
            + " | lessons: \(note.lessons.joined(separator: " / "))"
        }.joined(separator: "\n")

        return """
        下面是同一项目同一天多段工作的摘要，合并成一份。硬性要求：
        - 合并重复项，保留信息量最大的表述
        - did 最多 3 条，每条不超过 \(config.tier.perItemScalars) 个字
        - lessons 去重后最多 \(config.tier.maxLessons) 条、每条不超过 \(config.tier.perItemScalars) 个字
        - \(config.language.instruction)
        - 只输出一个 JSON 对象：{"did":["…"],"outcome":"shipped|partial|blocked|explored","lessons":["…"]}，不要任何其它文字或代码块标记

        \(payload)
        """
    }

    static let strictSuffix = "\n\n上一次输出无法解析。只输出 JSON 对象本身，第一个字符必须是 {，最后一个字符必须是 }。"

    // MARK: Strict parsing (pure)

    /// The whole trimmed output must be exactly one JSON object with exactly
    /// the keys `did`, `outcome`, `lessons` and the right types. Anything else
    /// — fences, prose, extra keys, wrong types — is rejected, never repaired.
    ///
    /// Strictness is load-bearing on the Claude path: codex has
    /// `--output-schema` enforced by the provider, claude has only this
    /// parser. Salvaging "almost JSON" would silently accept exactly the
    /// drifted output the retry-with-stricter-prompt exists to correct.
    static func parseSliceNote(_ raw: String) -> SliceNote? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("{"), text.hasSuffix("}"),
              let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8))
                  as? [String: Any],
              Set(obj.keys) == ["did", "outcome", "lessons"],
              let did = obj["did"] as? [String],
              let outcomeRaw = obj["outcome"] as? String,
              let outcome = Outcome(rawValue: outcomeRaw),
              let lessons = obj["lessons"] as? [String]
        else { return nil }
        return SliceNote(did: did, outcome: outcome, lessons: lessons)
    }
}
