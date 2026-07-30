import Foundation
import Shared

/// Distiller output → sanitized `DayNote` + `DayFacts` (#214). Pure.
///
/// This is where the model's material and Swift's facts meet, and the order
/// of operations is the point: every model-written item passes through
/// `JournalSanitizer` *before* it can influence anything — a narrative that
/// gets discarded also doesn't count toward the length budget, so a rejected
/// item can never squeeze a legitimate project out of the day.
public enum JournalAssembler {

    public struct Config: Sendable {
        public var tier: JournalTier
        public var language: JournalLanguage
        /// Extra proper nouns for the sanitizer — the user's project aliases
        /// plus the project keys themselves. "给 ZackEyes 加了推送" is exactly
        /// the sentence a journal exists for; the camel-case rule must not
        /// eat the repo's own name.
        public var properNouns: Set<String>
        public var forbiddenLiterals: [String]

        public init(tier: JournalTier = .moderate,
                    language: JournalLanguage = .chinese,
                    properNouns: Set<String> = [],
                    forbiddenLiterals: [String] = []) {
            self.tier = tier
            self.language = language
            self.properNouns = properNouns
            self.forbiddenLiterals = forbiddenLiterals
        }
    }

    public struct Output: Sendable {
        public let note: DayNote
        public let facts: DayFacts
        /// What the sanitizer ate, for the run record. The silent-thinning
        /// failure mode makes this as important as what was kept.
        public let dropped: [String]
    }

    public static func assemble(
        day: Date,
        slices: [SessionSlice],
        notes: [JournalGroupKey: SliceNote],
        config: Config
    ) -> Output {
        let policy = JournalSanitizer.Policy(
            maxScalars: config.tier.perItemScalars,
            properNouns: JournalSanitizer.defaultProperNouns
                .union(config.properNouns)
                .union(notes.keys.map(\.project)),
            forbiddenLiterals: config.forbiddenLiterals)

        // Project order = token spend, heaviest first. The same order decides
        // which projects survive the length budget, so the file and the
        // squeeze-out can never disagree (spec §5.2).
        var tokensByProject: [String: Int] = [:]
        for s in slices {
            tokensByProject[s.projectKey, default: 0] += s.tokens.distinct
        }
        let order = tokensByProject.sorted {
            $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key
        }.map(\.key)

        var dropped: [String] = []
        var projects: [String: [ProjectNarrative]] = [:]

        for project in order {
            // Claude first, then codex — stable, arbitrary, and visible.
            for agent in [AgentKind.claude, AgentKind.codex] {
                guard let note = notes[JournalGroupKey(agent: agent, project: project)]
                else { continue }
                for item in note.did {
                    switch JournalSanitizer.check(item, policy: policy) {
                    case .success(let clean):
                        projects[project, default: []].append(
                            ProjectNarrative(agent: agent, text: clean, outcome: note.outcome))
                    case .failure(let why):
                        dropped.append("[\(why.rawValue)] \(item)")
                    }
                }
            }
        }

        // Total-length budget (spec §5.2): walk projects in order, stop
        // admitting once the narrative budget is spent. Whole projects drop —
        // a truncated narrative reads like an accident, an omission line reads
        // like a decision.
        var kept: [String] = []
        var omitted = 0
        var used = 0
        for project in order {
            guard let narratives = projects[project], !narratives.isEmpty else { continue }
            let cost = narratives.reduce(0) { $0 + $1.text.unicodeScalars.count }
            if used + cost <= config.tier.totalScalars || kept.isEmpty {
                kept.append(project)
                used += cost
            } else {
                projects[project] = nil
                omitted += 1
            }
        }

        // Lessons are collected AFTER the squeeze, from kept projects only.
        // Collecting first had two defects the first review round caught: a
        // squeezed project's name reappeared under ## Lessons with no heading
        // to anchor it, and its lessons had already consumed global cap slots
        // that a kept project's lessons deserved. A squeezed project's lesson
        // lands in `dropped` so the run record shows it existed — lessons are
        // the highest-value content (D4), and losing one silently is exactly
        // the failure mode this feature must not have.
        var lessons: [Lesson] = []
        for project in kept {
            for agent in [AgentKind.claude, AgentKind.codex] {
                guard let note = notes[JournalGroupKey(agent: agent, project: project)]
                else { continue }
                for item in note.lessons {
                    guard lessons.count < config.tier.maxLessons else {
                        dropped.append("[lessonCap] \(item)")
                        continue
                    }
                    switch JournalSanitizer.check(item, policy: policy) {
                    case .success(let clean):
                        lessons.append(Lesson(agent: agent, projectKey: project, text: clean))
                    case .failure(let why):
                        dropped.append("[\(why.rawValue)] \(item)")
                    }
                }
            }
        }
        for project in order where !kept.contains(project) {
            for agent in [AgentKind.claude, AgentKind.codex] {
                guard let note = notes[JournalGroupKey(agent: agent, project: project)]
                else { continue }
                for item in note.lessons {
                    dropped.append("[projectOmitted] \(item)")
                }
            }
        }

        let costs = slices.compactMap(\.tokens.costUSD)
        let facts = DayFacts(
            projectOrder: kept,
            sessionCount: slices.count,
            distinctTokens: slices.reduce(0) { $0 + $1.tokens.distinct },
            costUSD: costs.isEmpty ? nil : costs.reduce(0, +),
            costIsFloor: false,
            omittedNote: omitted > 0 ? omittedLine(omitted, language: config.language) : nil)

        return Output(
            note: DayNote(day: day, projects: projects, lessons: lessons),
            facts: facts,
            dropped: dropped)
    }

    /// Composed by Swift in the journal's language — it is a fact, not
    /// narrative, so it neither passes the sanitizer nor needs to.
    static func omittedLine(_ count: Int, language: JournalLanguage) -> String {
        switch language {
        case .chinese: "另有 \(count) 个项目的零星改动"
        case .english: count == 1
            ? "1 more project with minor changes"
            : "\(count) more projects with minor changes"
        case .japanese: "ほか \(count) 件のプロジェクトに小さな変更"
        }
    }
}
