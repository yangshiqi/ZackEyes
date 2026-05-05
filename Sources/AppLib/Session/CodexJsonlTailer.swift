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
}

public enum CodexTaskLifecycleEvent: Sendable {
    case started(CodexTaskStartedEvent)
    case complete(CodexTaskCompleteEvent)
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
        let candidateDays = SessionScanner.candidateDateDirs(rootDir: rootDir, cutoff: cutoff)
        let fm = FileManager.default
        var result: [URL] = []
        for day in candidateDays {
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
            guard obj["type"] as? String == "event_msg" else { continue }
            guard let payload = obj["payload"] as? [String: Any] else { continue }

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
                    turnId: turnId
                )))

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
        self.onClosed = onClosed

        // Read session_meta once for cwd. Best-effort — if the file doesn't
        // have one yet, cwd stays nil (notification falls back to the
        // session id prefix).
        self.cwd = CodexJsonlTailer.parseSessionMetaCwd(at: url)

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
        guard let line = readFirstLine(of: url, maxBytes: 1_048_576),
              let lineData = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
              obj["type"] as? String == "session_meta",
              let payload = obj["payload"] as? [String: Any] else {
            return nil
        }
        return payload["cwd"] as? String
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
