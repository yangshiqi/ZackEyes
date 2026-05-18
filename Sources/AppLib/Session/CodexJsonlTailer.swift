import Foundation
import Shared

/// Real-time fallback for codex sessions whose owning TUI process started
/// before `~/.codex/hooks.json` was installed (and therefore won't fire any
/// hooks for the rest of its lifetime). Codex writes turn lifecycle signals
/// into the per-session rollout JSONL as `event_msg.task_started` /
/// `event_msg.task_complete` — we tail the active rollouts, parse the tail
/// incrementally, mark the session working while a turn is active, and fire
/// a notification each time a `task_complete` lands.
///
/// Kqueue-backed (DispatchSource), so there's no polling cost while idle.
/// The tailer only attaches to rollouts modified within the last `recencyHours`
/// window, and re-scans on a coarse timer to pick up newly-created rollouts
/// from the same long-running codex.
public protocol CodexJsonlTailerDelegate: AnyObject {
    @MainActor
    func codexTailer(_ tailer: CodexJsonlTailer, didDetectTaskStarted event: CodexTaskStartedEvent)

    @MainActor
    func codexTailer(_ tailer: CodexJsonlTailer, didDetectTaskComplete event: CodexTaskCompleteEvent)

    @MainActor
    func codexTailer(_ tailer: CodexJsonlTailer, didDetectTokenCount event: CodexTokenCountEvent)

    @MainActor
    func codexTailer(_ tailer: CodexJsonlTailer, didDetectModelChanged event: CodexModelEvent)

    @MainActor
    func codexTailer(_ tailer: CodexJsonlTailer, didDetectSubagent event: CodexSubagentEvent)

    @MainActor
    func codexTailer(_ tailer: CodexJsonlTailer, didDetectPolicyChanged event: CodexPolicyEvent)
}

public struct CodexTaskStartedEvent: Sendable {
    public let sessionId: String
    public let cwd: String?
    public let startedAt: Date?
    public let transcriptPath: String
    public let turnId: String?
}

public struct CodexTaskCompleteEvent: Sendable {
    public let sessionId: String
    public let cwd: String?
    public let lastAgentMessage: String?
    public let completedAt: Date?
    public let durationMs: Int?
    public let transcriptPath: String
    public let turnId: String?
    public let shouldNotifyUser: Bool
}

public struct CodexTokenCountEvent: Sendable {
    public let sessionId: String
    public let cwd: String?
    public let contextUsedPct: Double
    public let contextWindowSize: Int?
    public let transcriptPath: String
}

/// Codex emits a top-level `turn_context` JSONL row per turn whose payload
/// carries `model` (the model id actually used for that turn — e.g.
/// `gpt-5.5`, `codex-auto-review`). Mirrors what Claude's StatusLine hook
/// provides via `model.display_name`.
public struct CodexModelEvent: Sendable {
    public let sessionId: String
    public let cwd: String?
    public let modelDisplayName: String
    public let transcriptPath: String
}

/// Codex `turn_context.approval_policy` + `sandbox_policy.type` snapshot
/// per turn. Raw strings (not pre-mapped to PermissionRiskLevel) so the parser
/// stays nonisolated/dependency-free; AppDelegate runs the mapper on MainActor.
public struct CodexPolicyEvent: Sendable {
    public let sessionId: String
    public let cwd: String?
    public let approvalPolicy: String?
    public let sandboxType: String?
    public let transcriptPath: String
}

/// Codex marks subagent-owned rollouts via `session_meta.source.subagent`
/// (set to a string like `"review"` or a dict `{"other":"guardian"}`). Main
/// user threads omit the field. We surface the name as a small badge so
/// guardian / auto-review sessions don't masquerade as the user's main turn.
public struct CodexSubagentEvent: Sendable {
    public let sessionId: String
    public let cwd: String?
    public let subagentLabel: String
    public let transcriptPath: String
}

public enum CodexTaskLifecycleEvent: Sendable {
    case started(CodexTaskStartedEvent)
    case complete(CodexTaskCompleteEvent)
    case tokenCount(CodexTokenCountEvent)
    case modelChanged(CodexModelEvent)
    case policyChanged(CodexPolicyEvent)
}

@MainActor
public final class CodexJsonlTailer {

    public weak var delegate: CodexJsonlTailerDelegate?

    private let codexSessionsDir: URL
    private let recencyHours: Int
    /// Rescan interval for newly-created rollouts. Kqueue handles writes to
    /// existing files, but new files appearing under `<root>/YYYY/MM/DD/`
    /// need a coarse rediscovery sweep — UTC midnight rollover, fresh thread,
    /// etc. 30s keeps the rediscovery latency reasonable without spinning.
    private let rescanIntervalSeconds: Int

    private var watchers: [URL: Watcher] = [:]
    private var rescanTask: Task<Void, Never>?
    private var isRunning = false

    public init(
        codexSessionsDir: URL = URL(fileURLWithPath: NSHomeDirectory() + "/.codex/sessions"),
        recencyHours: Int = 24,
        rescanIntervalSeconds: Int = 30
    ) {
        self.codexSessionsDir = codexSessionsDir
        self.recencyHours = recencyHours
        self.rescanIntervalSeconds = rescanIntervalSeconds
    }

    public func start() {
        guard FileManager.default.fileExists(atPath: codexSessionsDir.path) else {
            // No codex install — silent no-op, mirror SessionScanner behavior.
            return
        }
        isRunning = true
        rediscover()
        rescanTask?.cancel()
        rescanTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(self?.rescanIntervalSeconds ?? 30))
                self?.rediscover()
            }
        }
    }

    public func stop() {
        isRunning = false
        rescanTask?.cancel()
        rescanTask = nil
        for (_, w) in watchers { w.cancel() }
        watchers.removeAll()
    }

    /// Walk the current date-window and attach a watcher to any rollout we
    /// don't already track. Watchers self-detach when the rollout's session
    /// closes (rename / unlink), so this only ever grows the active set.
    private func rediscover() {
        let cutoff = Date().addingTimeInterval(-Double(recencyHours * 3600))
        let rootDir = codexSessionsDir
        Task.detached(priority: .utility) { [weak self] in
            let files = Self.discoverRecentRollouts(rootDir: rootDir, cutoff: cutoff)
            await MainActor.run { [weak self] in
                guard let self, self.isRunning else { return }
                for file in files where self.watchers[file] == nil {
                    self.attachWatcher(at: file)
                }
            }
        }
    }

    nonisolated static func discoverRecentRollouts(rootDir: URL, cutoff: Date) -> [URL] {
        // Walk every YYYY/MM/DD dir, not just today/yesterday. `codex --resume`
        // keeps writing to the resumed session's original date dir, which can
        // be arbitrarily old. Filter by the file's own mtime — a stale-named
        // dir whose contents got freshly modified still belongs in the window.
        let fm = FileManager.default
        var result: [URL] = []
        for day in SessionScanner.allDateDirs(under: rootDir) {
            guard let files = try? fm.contentsOfDirectory(
                at: day,
                includingPropertiesForKeys: [.contentModificationDateKey]
            ) else { continue }
            for file in files where file.pathExtension == "jsonl" {
                guard let modDate = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                      modDate >= cutoff else { continue }
                result.append(file)
            }
        }
        return result
    }

    private func attachWatcher(at url: URL) {
        guard let watcher = Watcher(url: url, onTaskStarted: { [weak self] event in
            Task { @MainActor in
                guard let self = self else { return }
                self.delegate?.codexTailer(self, didDetectTaskStarted: event)
            }
        }, onTaskComplete: { [weak self] event in
            Task { @MainActor in
                guard let self = self else { return }
                self.delegate?.codexTailer(self, didDetectTaskComplete: event)
            }
        }, onTokenCount: { [weak self] event in
            Task { @MainActor in
                guard let self = self else { return }
                self.delegate?.codexTailer(self, didDetectTokenCount: event)
            }
        }, onModelChanged: { [weak self] event in
            Task { @MainActor in
                guard let self = self else { return }
                self.delegate?.codexTailer(self, didDetectModelChanged: event)
            }
        }, onSubagent: { [weak self] event in
            Task { @MainActor in
                guard let self = self else { return }
                self.delegate?.codexTailer(self, didDetectSubagent: event)
            }
        }, onPolicyChanged: { [weak self] event in
            Task { @MainActor in
                guard let self = self else { return }
                self.delegate?.codexTailer(self, didDetectPolicyChanged: event)
            }
        }, onClosed: { [weak self] closedURL in
            Task { @MainActor in
                self?.watchers.removeValue(forKey: closedURL)
            }
        }) else {
            return
        }
        watchers[url] = watcher
    }
}

// MARK: - Pure parser (testable, nonisolated)

extension CodexJsonlTailer {
    public nonisolated static func parseTaskLifecycleEvents(
        chunk: String,
        pending: inout String,
        sessionId: String,
        cwd: String?,
        transcriptPath: String
    ) -> [CodexTaskLifecycleEvent] {
        let combined = pending + chunk
        let parts = combined.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let last = parts.last else {
            pending = combined
            return []
        }
        pending = last
        let completeLines = parts.dropLast()

        var events: [CodexTaskLifecycleEvent] = []
        for line in completeLines {
            if line.isEmpty { continue }
            guard let lineData = line.data(using: .utf8) else { continue }
            guard let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }
            let topType = obj["type"] as? String
            guard let payload = obj["payload"] as? [String: Any] else { continue }

            // `turn_context` is a top-level row (not nested under event_msg).
            // It carries the model id + approval/sandbox policy for the
            // upcoming turn. Emit a model event AND a policy event when the
            // respective fields are populated — they're independent surfaces.
            if topType == "turn_context" {
                if let model = payload["model"] as? String, !model.isEmpty {
                    events.append(.modelChanged(CodexModelEvent(
                        sessionId: sessionId,
                        cwd: cwd,
                        modelDisplayName: model,
                        transcriptPath: transcriptPath
                    )))
                }
                let approval = payload["approval_policy"] as? String
                let sandboxType = (payload["sandbox_policy"] as? [String: Any])?["type"] as? String
                if approval != nil || sandboxType != nil {
                    events.append(.policyChanged(CodexPolicyEvent(
                        sessionId: sessionId,
                        cwd: cwd,
                        approvalPolicy: approval,
                        sandboxType: sandboxType,
                        transcriptPath: transcriptPath
                    )))
                }
                continue
            }

            guard topType == "event_msg" else { continue }

            switch payload["type"] as? String {
            case "task_started":
                let turnId = payload["turn_id"] as? String
                let startedAt = parseCodexDate(payload["started_at"])
                events.append(.started(CodexTaskStartedEvent(
                    sessionId: sessionId,
                    cwd: cwd,
                    startedAt: startedAt,
                    transcriptPath: transcriptPath,
                    turnId: turnId
                )))

            case "task_complete":
                let lastMsg = payload["last_agent_message"] as? String
                let turnId = payload["turn_id"] as? String
                let completedAt = parseCodexDate(payload["completed_at"])
                let durationMs = payload["duration_ms"] as? Int

                events.append(.complete(CodexTaskCompleteEvent(
                    sessionId: sessionId,
                    cwd: cwd,
                    lastAgentMessage: lastMsg,
                    completedAt: completedAt,
                    durationMs: durationMs,
                    transcriptPath: transcriptPath,
                    turnId: turnId,
                    shouldNotifyUser: shouldNotifyUser(forTaskCompleteMessage: lastMsg)
                )))

            case "token_count":
                if let event = parseTokenCountEvent(
                    payload: payload,
                    sessionId: sessionId,
                    cwd: cwd,
                    transcriptPath: transcriptPath
                ) {
                    events.append(.tokenCount(event))
                }

            default:
                continue
            }
        }
        return events
    }

    /// Append `chunk` to `pending` and consume any complete lines, returning
    /// every `event_msg.task_complete` payload found. Trailing partial line
    /// stays in `pending` for the next call.
    public nonisolated static func parseTaskCompleteEvents(
        chunk: String,
        pending: inout String,
        sessionId: String,
        cwd: String?,
        transcriptPath: String
    ) -> [CodexTaskCompleteEvent] {
        parseTaskLifecycleEvents(
            chunk: chunk,
            pending: &pending,
            sessionId: sessionId,
            cwd: cwd,
            transcriptPath: transcriptPath
        ).compactMap { event in
            if case let .complete(complete) = event { return complete }
            return nil
        }
    }

    private nonisolated static func parseCodexDate(_ raw: Any?) -> Date? {
        if let raw = raw as? Double {
            return Date(timeIntervalSince1970: raw > 1e12 ? raw / 1000 : raw)
        }
        if let raw = raw as? Int {
            let secs = raw > 1_000_000_000_000 ? Double(raw) / 1000 : Double(raw)
            return Date(timeIntervalSince1970: secs)
        }
        if let raw = raw as? String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: raw) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: raw)
        }
        return nil
    }

    private nonisolated static func shouldNotifyUser(forTaskCompleteMessage rawMessage: String?) -> Bool {
        guard let message = rawMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
              !message.isEmpty else {
            return false
        }
        return !isInternalDecisionMessage(message)
    }

    private nonisolated static func isInternalDecisionMessage(_ message: String) -> Bool {
        guard let data = message.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let outcome = dict["outcome"] as? String,
              outcome == "allow" || outcome == "deny" else {
            return false
        }
        if dict.count == 1 { return true }
        return dict["risk_level"] != nil
            || dict["user_authorization"] != nil
            || dict["rationale"] != nil
    }

    private nonisolated static func parseTokenCountEvent(
        payload: [String: Any],
        sessionId: String,
        cwd: String?,
        transcriptPath: String
    ) -> CodexTokenCountEvent? {
        guard let info = payload["info"] as? [String: Any],
              let lastUsage = info["last_token_usage"] as? [String: Any],
              let contextTokens = number(lastUsage["total_tokens"]),
              let window = number(info["model_context_window"]),
              window > 0 else {
            return nil
        }

        let windowSize = Int(window.rounded())
        return CodexTokenCountEvent(
            sessionId: sessionId,
            cwd: cwd,
            contextUsedPct: (contextTokens / window) * 100,
            contextWindowSize: windowSize,
            transcriptPath: transcriptPath
        )
    }

    private nonisolated static func number(_ raw: Any?) -> Double? {
        switch raw {
        case let value as Double:
            return value
        case let value as Int:
            return Double(value)
        case let value as NSNumber:
            return value.doubleValue
        default:
            return nil
        }
    }
}

// MARK: - Per-file watcher (kqueue-backed)

private final class Watcher: @unchecked Sendable {
    let url: URL
    private let sessionId: String
    private let cwd: String?
    private let fd: Int32
    private let source: DispatchSourceFileSystemObject
    private let queue: DispatchQueue
    private var offset: UInt64
    private var pendingBuffer: String = ""
    private let onTaskStarted: (CodexTaskStartedEvent) -> Void
    private let onTaskComplete: (CodexTaskCompleteEvent) -> Void
    private let onTokenCount: (CodexTokenCountEvent) -> Void
    private let onModelChanged: (CodexModelEvent) -> Void
    private let onSubagent: (CodexSubagentEvent) -> Void
    private let onPolicyChanged: (CodexPolicyEvent) -> Void
    private let onClosed: (URL) -> Void
    /// Guards `isCancelled` so the MainActor `stop()` path and the
    /// DispatchSource event handler (private queue, fires on .delete /
    /// .rename) can't both flip-and-cancel concurrently.
    private let cancelLock = NSLock()
    private var isCancelled = false

    init?(
        url: URL,
        onTaskStarted: @escaping (CodexTaskStartedEvent) -> Void,
        onTaskComplete: @escaping (CodexTaskCompleteEvent) -> Void,
        onTokenCount: @escaping (CodexTokenCountEvent) -> Void,
        onModelChanged: @escaping (CodexModelEvent) -> Void,
        onSubagent: @escaping (CodexSubagentEvent) -> Void,
        onPolicyChanged: @escaping (CodexPolicyEvent) -> Void,
        onClosed: @escaping (URL) -> Void
    ) {
        // Codex session id is encoded in the rollout filename; bail if we
        // can't recover it (defensive — never happens against real codex
        // output, but cheap to gate).
        guard let id = SessionScanner.extractCodexSessionId(fromFilename: url.lastPathComponent) else {
            return nil
        }
        // O_EVTONLY = "I'm only interested in events on this fd, don't keep
        // the file from being unlinked / unmounted." Required for kqueue
        // file system source on macOS.
        let openFd = open(url.path, O_EVTONLY)
        guard openFd != -1 else { return nil }

        self.url = url
        self.sessionId = id
        self.fd = openFd
        self.queue = DispatchQueue(label: "ZackEyes.CodexJsonlTailer.\(id.prefix(8))")
        self.onTaskStarted = onTaskStarted
        self.onTaskComplete = onTaskComplete
        self.onTokenCount = onTokenCount
        self.onModelChanged = onModelChanged
        self.onSubagent = onSubagent
        self.onPolicyChanged = onPolicyChanged
        self.onClosed = onClosed

        // Read session_meta once for cwd. Best-effort — if the file doesn't
        // have one yet, cwd stays nil (notification falls back to the
        // session id prefix).
        self.cwd = CodexJsonlTailer.parseSessionMetaCwd(at: url)

        // Same first line carries `source.subagent` for subagent threads
        // (guardian / review / etc). Fire once at attach time — subagent
        // identity is session-level, never changes mid-rollout.
        if let subagentLabel = CodexJsonlTailer.parseSessionMetaSubagent(at: url) {
            onSubagent(CodexSubagentEvent(
                sessionId: id,
                cwd: cwd,
                subagentLabel: subagentLabel,
                transcriptPath: url.path
            ))
        }

        // Bootstrap: scan the existing rollout for the first turn_context so
        // resumed sessions show model + policy immediately instead of waiting
        // for the next turn. Best-effort — missing fields stay nil until the
        // next turn_context arrives via the stream.
        if let initial = CodexJsonlTailer.parseInitialTurnContext(at: url) {
            if let initialModel = initial.model {
                onModelChanged(CodexModelEvent(
                    sessionId: id,
                    cwd: cwd,
                    modelDisplayName: initialModel,
                    transcriptPath: url.path
                ))
            }
            if initial.approvalPolicy != nil || initial.sandboxType != nil {
                onPolicyChanged(CodexPolicyEvent(
                    sessionId: id,
                    cwd: cwd,
                    approvalPolicy: initial.approvalPolicy,
                    sandboxType: initial.sandboxType,
                    transcriptPath: url.path
                ))
            }
        }

        // Start tailing FROM CURRENT EOF. We don't want to fire
        // notifications for historical task_complete events that already
        // happened before the user launched ZackEyes.
        let startSize: UInt64
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? UInt64 {
            startSize = size
        } else {
            startSize = 0
        }
        self.offset = startSize

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: openFd,
            eventMask: [.write, .delete, .rename],
            queue: queue
        )
        self.source = source

        source.setEventHandler { [weak self] in
            guard let self = self else { return }
            let mask = source.data
            if mask.contains(.delete) || mask.contains(.rename) {
                self.cancel()
                return
            }
            if mask.contains(.write) {
                self.readNewBytes()
            }
        }
        source.setCancelHandler { [weak self] in
            guard let self = self else { return }
            close(self.fd)
            self.onClosed(self.url)
        }
        source.resume()
    }

    deinit {
        cancel()
    }

    func cancel() {
        cancelLock.lock()
        guard !isCancelled else {
            cancelLock.unlock()
            return
        }
        isCancelled = true
        cancelLock.unlock()
        // DispatchSource.cancel() is itself idempotent and thread-safe; we
        // call it OUTSIDE the lock so the cancel handler (which closes the
        // fd and reaches back through onClosed) can never try to re-enter
        // this watcher's lock.
        source.cancel()
    }

    /// Read everything written past our current offset, parse complete
    /// JSONL lines for `task_complete` events.
    private func readNewBytes() {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        do {
            let endSize = try handle.seekToEnd()
            guard endSize > offset else { return }
            try handle.seek(toOffset: offset)
            guard let data = try handle.readToEnd() else { return }
            offset = endSize
            guard let chunk = String(data: data, encoding: .utf8) else { return }
            let events = CodexJsonlTailer.parseTaskLifecycleEvents(
                chunk: chunk,
                pending: &pendingBuffer,
                sessionId: sessionId,
                cwd: cwd,
                transcriptPath: url.path
            )
            for ev in events {
                switch ev {
                case .started(let started):
                    onTaskStarted(started)
                case .complete(let complete):
                    onTaskComplete(complete)
                case .tokenCount(let tokenCount):
                    onTokenCount(tokenCount)
                case .modelChanged(let modelEvent):
                    onModelChanged(modelEvent)
                case .policyChanged(let policyEvent):
                    onPolicyChanged(policyEvent)
                }
            }
        } catch {
            // Read errors are fatal for this watcher — file may be gone.
            cancel()
        }
    }
}

extension CodexJsonlTailer {
    /// Parse the `cwd` from Codex's `session_meta` line. Real rollouts can
    /// put a large `base_instructions` object on that first JSONL line, so a
    /// fixed small head read can truncate the JSON before `JSONSerialization`
    /// sees a complete object.
    nonisolated static func parseSessionMetaCwd(at url: URL) -> String? {
        guard let payload = readSessionMetaPayload(at: url) else { return nil }
        return payload["cwd"] as? String
    }

    /// Extract the subagent label from `session_meta.source.subagent`. Codex
    /// emits two shapes in the wild — a bare string (e.g. `"review"`) or a
    /// dict with a single `other` key (`{"other":"guardian"}`) — so we handle
    /// both. Returns nil for main user threads (no `subagent` key).
    nonisolated static func parseSessionMetaSubagent(at url: URL) -> String? {
        guard let payload = readSessionMetaPayload(at: url),
              let source = payload["source"] as? [String: Any] else {
            return nil
        }
        let raw = source["subagent"]
        if let s = raw as? String, !s.isEmpty { return s }
        if let dict = raw as? [String: Any],
           let other = dict["other"] as? String,
           !other.isEmpty {
            return other
        }
        return nil
    }

    private nonisolated static func readSessionMetaPayload(at url: URL) -> [String: Any]? {
        guard let line = readFirstLine(of: url, maxBytes: 1_048_576),
              let lineData = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
              obj["type"] as? String == "session_meta",
              let payload = obj["payload"] as? [String: Any] else {
            return nil
        }
        return payload
    }

    /// Subset of the first `turn_context.payload` we care about at watcher
    /// attach time. Any field can be nil — the rollout may have been written
    /// without it, or our schema knowledge may have drifted.
    public struct InitialTurnContext: Sendable, Equatable {
        public let model: String?
        public let approvalPolicy: String?
        public let sandboxType: String?
    }

    /// Scan the rollout from the start for the first `turn_context` row and
    /// extract model + policy fields in one pass. Used at watcher-attach time
    /// so resumed sessions surface this state before the next turn fires.
    nonisolated static func parseInitialTurnContext(at url: URL) -> InitialTurnContext? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        // Slightly above the 1 MB session_meta cap so a turn_context line that
        // sits immediately after a maximally-sized session_meta still lands in
        // the read.
        let maxBytes = 1_100_000
        guard let data = try? handle.read(upToCount: maxBytes), !data.isEmpty else {
            return nil
        }
        // String(decoding:as:) replaces invalid UTF-8 sequences with U+FFFD
        // instead of failing — protects against the read truncating in the
        // middle of a multi-byte char at the buffer edge.
        let text = String(decoding: data, as: UTF8.self)

        // Process every non-empty segment. Partial lines (the trailing segment
        // when we hit the read cap mid-line, or anything we corrupted with the
        // replacement char) just fail JSON parse and get skipped silently.
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  obj["type"] as? String == "turn_context",
                  let payload = obj["payload"] as? [String: Any] else {
                continue
            }
            let model = (payload["model"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let approval = payload["approval_policy"] as? String
            let sandbox = (payload["sandbox_policy"] as? [String: Any])?["type"] as? String
            // Don't return an empty result — keep scanning until we hit a
            // turn_context that actually carries something useful.
            if model != nil || approval != nil || sandbox != nil {
                return InitialTurnContext(
                    model: model,
                    approvalPolicy: approval,
                    sandboxType: sandbox
                )
            }
        }
        return nil
    }

    /// Backward-compatible wrapper used by older callsites and tests.
    nonisolated static func parseInitialTurnContextModel(at url: URL) -> String? {
        parseInitialTurnContext(at: url)?.model
    }

    private nonisolated static func readFirstLine(of url: URL, maxBytes: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        var data = Data()
        while data.count < maxBytes {
            guard let chunk = try? handle.read(upToCount: min(8192, maxBytes - data.count)),
                  !chunk.isEmpty else {
                break
            }
            if let newline = chunk.firstIndex(of: 0x0A) {
                data.append(chunk[..<newline])
                break
            }
            data.append(chunk)
        }
        return String(data: data, encoding: .utf8)
    }
}
