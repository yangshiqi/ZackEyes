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

    /// Total entries retained.
    ///
    /// Sizing this was measured, not guessed. cc-island keeps 20; 30 looked
    /// generous next to it until a live export showed two concurrent sessions
    /// filling all 30 slots in about 50 seconds — every tool call is two
    /// events (Pre + PostToolUse) plus StatusLine, times however many sessions
    /// are open. Raising it to 150 bought five minutes, and that export showed
    /// the real problem: 149 of the 150 lines were routine `.applied`, and
    /// exactly one carried a decision. Simply growing the buffer would need
    /// ~900 entries to hold half an hour and would produce a report nobody
    /// reads.
    public static let capacity = 150

    /// Of that total, the most routine `.applied` entries kept.
    ///
    /// `.applied` means "state moved, nothing user-visible" — worth a little
    /// context, worthless in bulk. Capping it separately is what lets the
    /// decision-bearing entries (prompted / dropped / suppressed / notified),
    /// which arrive orders of magnitude more rarely, survive long enough to
    /// still be there when the user exports the report *after* noticing that
    /// a notification never came.
    public static let routineCapacity = 30

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
        // Prune here rather than on arrival: routine-ness is only known once
        // the verdict is in, so trimming after classification keeps the bound
        // exact instead of overshooting by the entry currently being routed.
        while entries.lazy.filter({ $0.disposition == .applied }).count > Self.routineCapacity,
              let oldestRoutine = entries.firstIndex(where: { $0.disposition == .applied }) {
            entries.remove(at: oldestRoutine)
        }
    }
}
