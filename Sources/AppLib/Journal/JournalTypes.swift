import Foundation
import Shared

/// Shapes for the daily work journal (#214).
///
/// ## The one rule that shapes every type here
///
/// **The LLM produces narrative, never facts.** Anything we already know
/// precisely — project name, duration, tokens, cost, tool-call count, which
/// agent produced the work — is filled in by Swift and never appears in a
/// schema the model is asked to complete.
///
/// Two payoffs: the numbers cannot hallucinate, and the safety boundary
/// shrinks to exactly the fields the model does write, which are the only
/// ones `JournalSanitizer` has to police.

// MARK: - Collector output (our facts; the LLM only reads these)

/// One agent session's worth of a single day's work in a single project.
///
/// A slice belongs to exactly one project. That is load-bearing, not
/// incidental: it is what makes cross-project bleed structurally impossible
/// during reduce (plan Q1) — a per-project reduce simply never sees another
/// project's text.
public struct SessionSlice: Sendable, Equatable {
    public let agent: AgentKind
    /// Already passed through the alias table; excluded projects never get here.
    public let projectKey: String
    public let startedAt: Date
    public let endedAt: Date
    public let turnCount: Int
    public let toolCallCount: Int
    public let tokens: SliceTokens
    /// The raw text fed to the LLM. Never appears in any output.
    public let transcriptText: String

    public init(
        agent: AgentKind, projectKey: String, startedAt: Date, endedAt: Date,
        turnCount: Int, toolCallCount: Int, tokens: SliceTokens, transcriptText: String
    ) {
        self.agent = agent
        self.projectKey = projectKey
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.turnCount = turnCount
        self.toolCallCount = toolCallCount
        self.tokens = tokens
        self.transcriptText = transcriptText
    }
}

/// Per-slice token facts.
///
/// Deliberately NOT reused from `DayUsage`: that type folds by day × agent ×
/// model and has already collapsed the project dimension this journal is
/// organised around. The per-file tally cache from #116 is re-keyed by project
/// instead, which costs no extra parsing.
public struct SliceTokens: Sendable, Equatable {
    public let input: Int
    public let output: Int
    public let cacheRead: Int
    public let cacheCreate: Int
    public let costUSD: Double?

    public init(input: Int = 0, output: Int = 0, cacheRead: Int = 0,
                cacheCreate: Int = 0, costUSD: Double? = nil) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheCreate = cacheCreate
        self.costUSD = costUSD
    }

    /// Distinct tokens processed — cache reads excluded so re-reading the same
    /// context every turn doesn't inflate the count. Mirrors `DayUsage`.
    public var distinct: Int { input + output + cacheCreate }
}

// MARK: - LLM output (everything the model is allowed to write)

public enum Outcome: String, Codable, Sendable, CaseIterable {
    case shipped, partial, blocked, explored
}

/// The map stage's product for one slice. Every field here is model-written
/// and therefore every field here goes through `JournalSanitizer`.
public struct SliceNote: Codable, Sendable, Equatable {
    public let did: [String]
    public let outcome: Outcome
    public let lessons: [String]

    public init(did: [String], outcome: Outcome, lessons: [String]) {
        self.did = did
        self.outcome = outcome
        self.lessons = lessons
    }
}

// MARK: - Day product

/// One project's narrative from one vendor's engine.
///
/// `agent` is stamped by Swift when the two per-vendor partials are merged,
/// never by the model. It is what makes the "content is only ever sent back to
/// the vendor that wrote it" promise visible in the artifact itself: a reader
/// can verify provenance by looking at the journal rather than trusting our
/// copy. It is also why a missing CLI needs no apology line — if every section
/// is labelled `codex`, what is absent is self-evident.
public struct ProjectNarrative: Sendable, Equatable {
    public let agent: AgentKind
    public let text: String
    public let outcome: Outcome

    public init(agent: AgentKind, text: String, outcome: Outcome) {
        self.agent = agent
        self.text = text
        self.outcome = outcome
    }
}

public struct Lesson: Sendable, Equatable {
    public let agent: AgentKind
    public let projectKey: String
    public let text: String

    public init(agent: AgentKind, projectKey: String, text: String) {
        self.agent = agent
        self.projectKey = projectKey
        self.text = text
    }
}

/// A day, assembled.
///
/// There is deliberately **no model-written headline**. The design draft had
/// one; it was dropped once "never cross vendors" was settled, because a
/// day-spanning sentence is the one field that would necessarily have to be
/// written from both vendors' material. Composing it from facts instead also
/// removes the draft's "headline rejected → publish nothing today" failure
/// path: a string we assemble ourselves cannot be rejected by the sanitizer.
public struct DayNote: Sendable, Equatable {
    public let day: Date
    public let projects: [String: [ProjectNarrative]]
    public let lessons: [Lesson]

    public init(day: Date, projects: [String: [ProjectNarrative]], lessons: [Lesson]) {
        self.day = day
        self.projects = projects
        self.lessons = lessons
    }

    public var isEmpty: Bool { projects.isEmpty && lessons.isEmpty }
}
