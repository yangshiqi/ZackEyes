import Foundation
import Shared

/// Real-time fallback for codex sessions whose owning TUI process started
/// before `~/.codex/hooks.json` was installed (and therefore won't fire any
/// hooks for the rest of its lifetime). Codex writes turn-completion
/// signals into the per-session rollout JSONL as
/// `{"type":"event_msg","payload":{"type":"task_complete",...}}` — we tail
/// the active rollouts, parse the tail incrementally, and fire a notification
/// each time a `task_complete` lands.
///
/// Kqueue-backed (DispatchSource), so there's no polling cost while idle.
/// The tailer only attaches to rollouts modified within the last `recencyHours`
/// window, and re-scans on a coarse timer to pick up newly-created rollouts
/// from the same long-running codex.
public protocol CodexJsonlTailerDelegate: AnyObject {
    @MainActor
    func codexTailer(_ tailer: CodexJsonlTailer, didDetectTaskComplete event: CodexTaskCompleteEvent)
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
        rediscover()
        rescanTask?.cancel()
        rescanTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(self?.rescanIntervalSeconds ?? 30))
                await self?.rediscover()
            }
        }
    }

    public func stop() {
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
        let candidateDays = SessionScanner.candidateDateDirs(rootDir: codexSessionsDir, cutoff: cutoff)
        let fm = FileManager.default
        for day in candidateDays {
            guard let files = try? fm.contentsOfDirectory(
                at: day,
                includingPropertiesForKeys: [.contentModificationDateKey]
            ) else { continue }
            for file in files where file.pathExtension == "jsonl" {
                guard watchers[file] == nil else { continue }
                guard let modDate = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                      modDate >= cutoff else { continue }
                attachWatcher(at: file)
            }
        }
    }

    private func attachWatcher(at url: URL) {
        guard let watcher = Watcher(url: url, onTaskComplete: { [weak self] event in
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
        let combined = pending + chunk
        let parts = combined.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        // Last element is the partial trailing line; everything before it is
        // a complete line. (split with omittingEmptySubsequences=false leaves
        // the trailing "" if the chunk ends in '\n', which becomes an empty
        // pending — also correct.)
        guard let last = parts.last else {
            pending = combined
            return []
        }
        pending = last
        let completeLines = parts.dropLast()

        var events: [CodexTaskCompleteEvent] = []
        for line in completeLines {
            if line.isEmpty { continue }
            guard let lineData = line.data(using: .utf8) else { continue }
            guard let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }
            guard obj["type"] as? String == "event_msg" else { continue }
            guard let payload = obj["payload"] as? [String: Any] else { continue }
            guard payload["type"] as? String == "task_complete" else { continue }

            let lastMsg = payload["last_agent_message"] as? String
            let turnId = payload["turn_id"] as? String
            var completedAt: Date? = nil
            if let raw = payload["completed_at"] as? Double {
                completedAt = Date(timeIntervalSince1970: raw > 1e12 ? raw / 1000 : raw)
            } else if let raw = payload["completed_at"] as? Int {
                let secs = raw > 1_000_000_000_000 ? Double(raw) / 1000 : Double(raw)
                completedAt = Date(timeIntervalSince1970: secs)
            }
            let durationMs = payload["duration_ms"] as? Int

            events.append(CodexTaskCompleteEvent(
                sessionId: sessionId,
                cwd: cwd,
                lastAgentMessage: lastMsg,
                completedAt: completedAt,
                durationMs: durationMs,
                transcriptPath: transcriptPath,
                turnId: turnId
            ))
        }
        return events
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
    private let onTaskComplete: (CodexTaskCompleteEvent) -> Void
    private let onClosed: (URL) -> Void
    private var isCancelled = false

    init?(
        url: URL,
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
        self.onTaskComplete = onTaskComplete
        self.onClosed = onClosed

        // Read session_meta from the head once for cwd. Best-effort — if
        // the file doesn't have one yet, cwd stays nil (notification falls
        // back to the session id prefix).
        self.cwd = Self.parseCwdFromHead(of: url)

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
        if !isCancelled {
            source.cancel()
        }
    }

    func cancel() {
        guard !isCancelled else { return }
        isCancelled = true
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
            let events = CodexJsonlTailer.parseTaskCompleteEvents(
                chunk: chunk,
                pending: &pendingBuffer,
                sessionId: sessionId,
                cwd: cwd,
                transcriptPath: url.path
            )
            for ev in events {
                onTaskComplete(ev)
            }
        } catch {
            // Read errors are fatal for this watcher — file may be gone.
            cancel()
        }
    }

    /// Read the head (~4KB) and parse the first `session_meta` line for cwd.
    private static func parseCwdFromHead(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4096),
              let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") {
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  obj["type"] as? String == "session_meta",
                  let payload = obj["payload"] as? [String: Any] else { continue }
            return payload["cwd"] as? String
        }
        return nil
    }
}
