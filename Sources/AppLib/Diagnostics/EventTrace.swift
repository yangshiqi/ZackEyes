import Foundation
import Shared

/// Bounded in-memory record of the last N bridge events and what ZackEyes did
/// with each (#205 item 3). It exists to answer the one support question we
/// previously could only guess at: "why didn't my notification pop?"
///
/// Deliberately NOT a general-purpose log:
/// - **Memory only.** Never written to disk on its own; it rides along in the
///   diagnostics report the user explicitly chooses to copy or save.
/// - **Fixed-shape fields only.** No prompt text, no assistant text, no tool
///   arguments, no cwd — the things that make a log unshareable. What is kept
///   is the routing metadata needed to explain a decision.
/// - **Redacted and capped at render time**, not at capture time, so the
///   in-memory copy stays cheap and the report stays the single sink.
public enum EventDisposition: Sendable, Equatable {
    /// Stamped on arrival. An entry that is still `.received` when the report
    /// renders means no branch claimed the event — an honest "we don't know
    /// what happened to this", which is the whole point. A missing entry
    /// would be a silent gap; this is a visible one.
    case received
    /// Hook self-test probe — proves the pipeline works, intentionally leaves
    /// no session behind.
    case probe
    /// State updated, nothing user-visible. The ordinary case.
    case applied
    /// A permission / question popup was raised.
    case prompted
    /// "Allow Always" had already approved this tool for the session.
    case autoAllowed
    /// A notification fired. Payload is the kind (waiting / error / finished
    /// / compact).
    case notified(String)
    /// A notification was withheld on purpose. Payload is why (setting off /
    /// cooldown).
    case suppressed(String)
    /// The event was discarded. Payload is why.
    case dropped(String)
}

public struct EventTraceEntry: Sendable, Equatable {
    public let at: Date
    public let agent: String
    public let event: String
    public let tool: String?
    /// First 8 chars of the session id — enough to group a turn, useless as an
    /// identifier off this machine.
    public let session: String?
    /// The second dimension, and the one cc-island has no equivalent for: a
    /// replayed event was spooled by the bridge while the app was closed.
    /// Those apply state silently and never notify, which is the single most
    /// common reason a user "got nothing".
    public let replayed: Bool
    public var disposition: EventDisposition
}

/// Declared outside the `@MainActor` class on purpose: the diagnostics report
/// renders them from a non-isolated pure function, and nesting them would drag
/// main-actor isolation into that call.
@MainActor
public final class EventTrace {

    /// The app-wide instance. Same `.shared` pattern as `NotificationManager`,
    /// for the same reason: the event path and the diagnostics path are far
    /// apart in the object graph and threading an instance between them would
    /// be more plumbing than the feature is worth.
    public static let shared = EventTrace()

    /// cc-island keeps 20. 30 covers a permission plus the whole turn around
    /// it without turning the report into something nobody reads.
    public static let capacity = 30

    public private(set) var entries: [EventTraceEntry] = []

    public init() {}

    /// Stamp an arriving event as `.received`. Call once, at the top of the
    /// routing switch, before any branch runs.
    public func record(
        agent: String,
        event: String,
        tool: String?,
        session: String?,
        replayed: Bool,
        at: Date = Date()
    ) {
        entries.append(
            EventTraceEntry(
                at: at, agent: agent, event: event, tool: tool,
                session: session, replayed: replayed, disposition: .received
            )
        )
        if entries.count > Self.capacity {
            entries.removeFirst(entries.count - Self.capacity)
        }
    }

    public func record(_ event: BridgeEvent, at: Date = Date()) {
        record(
            agent: event.agent.rawValue,
            event: event.bridgeEvent,
            tool: event.toolName,
            session: event.sessionId.map { String($0.prefix(8)) },
            replayed: event.isReplayed,
            at: at
        )
    }

    /// Classify the event currently being routed.
    ///
    /// Updates the most recent entry, which is sound only because routing is
    /// `@MainActor` **and synchronous**: nothing else can append between the
    /// `record` at the top of `handleEvent` and a `note` from one of its
    /// branches. Last write wins, so a branch may refine its own verdict
    /// (`applied` → `notified`) as it learns more.
    ///
    /// A no-op on an empty buffer rather than a precondition: a diagnostic
    /// aid must never be the thing that crashes the app.
    public func note(_ disposition: EventDisposition) {
        guard !entries.isEmpty else { return }
        entries[entries.count - 1].disposition = disposition
    }

    public func clear() {
        entries.removeAll()
    }
}
