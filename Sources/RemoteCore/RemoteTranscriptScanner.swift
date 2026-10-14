import Foundation

#if os(Linux)
    import Glibc
#else
    import Darwin
#endif

/// Portable observer: metadata only, without hooks or a process/permission channel.
public struct RemoteTranscriptScanner: Sendable {
    private struct Cached: Sendable {
        var modified: Date
        var device: UInt64
        var inode: UInt64
        var size: Int
        var session: RemoteSessionSnapshot
    }
    private let claudeRoot: URL
    private let codexRoot: URL
    private var cache: [String: Cached] = [:]
    public init(
        claudeRoot: URL = URL(fileURLWithPath: NSHomeDirectory() + "/.claude/projects"),
        codexRoot: URL = URL(fileURLWithPath: NSHomeDirectory() + "/.codex/sessions")
    ) {
        self.claudeRoot = claudeRoot
        self.codexRoot = codexRoot
    }
    public mutating func snapshot(now: Date = Date()) throws -> RemoteSnapshot {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey,
        ]
        var next: [String: Cached] = [:]
        var sessions: [String: RemoteSessionSnapshot] = [:]
        for (root, agent) in [(claudeRoot, RemoteAgent.claude), (codexRoot, .codex)] {
            guard fm.fileExists(atPath: root.path) else { continue }
            guard (try root.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])).isSymbolicLink != true
            else { continue }
            let cutoff = now.addingTimeInterval(agent == .claude ? -8 * 3600 : -30 * 60)
            var walkFailed = false
            guard
                let walker = fm.enumerator(
                    at: root, includingPropertiesForKeys: Array(keys),
                    errorHandler: { _, _ in
                        walkFailed = true
                        return true
                    })
            else { throw CocoaError(.fileReadNoPermission) }
            for case let file as URL in walker where file.pathExtension == "jsonl" {
                guard let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true,
                    values.isSymbolicLink != true, let modified = values.contentModificationDate,
                    modified >= cutoff, modified <= now.addingTimeInterval(300), let size = values.fileSize,
                    size <= 256 * 1024 * 1024
                else { continue }
                var identity = stat()
                guard lstat(file.path, &identity) == 0, identity.st_mode & S_IFMT == S_IFREG else { continue }
                let key = file.path
                let entry: Cached
                if let hit = cache[key], hit.modified == modified, hit.size == size,
                    hit.device == UInt64(identity.st_dev), hit.inode == UInt64(identity.st_ino)
                {
                    entry = hit
                } else {
                    guard let text = try Self.readMetadata(file) else { continue }
                    let session = Self.parse(
                        regions: text, agent: agent, id: file.deletingPathExtension().lastPathComponent,
                        modified: modified, now: now)
                    entry = Cached(
                        modified: modified, device: UInt64(identity.st_dev), inode: UInt64(identity.st_ino), size: size,
                        session: session)
                }
                next[key] = entry
                guard entry.session.lastActivity >= cutoff else { continue }
                let id = "\(agent.rawValue):\(entry.session.id)"
                if sessions[id].map({ entry.session.lastActivity > $0.lastActivity }) ?? true {
                    sessions[id] = entry.session
                }
            }
            if walkFailed { throw CocoaError(.fileReadNoPermission) }
        }
        cache = next
        let ordered = sessions.values.sorted {
            $0.lastActivity == $1.lastActivity ? $0.id < $1.id : $0.lastActivity > $1.lastActivity
        }
        let snapshot = RemoteSnapshot(
            observedAt: now, sessions: Array(ordered.prefix(RemoteFrameCodec.maxSessions)),
            truncated: ordered.count > RemoteFrameCodec.maxSessions)
        try RemoteFrameCodec.validate(snapshot)
        return snapshot
    }
    private static func clean(_ value: String?, bytes: Int) -> String? {
        guard let value else { return nil }
        var result = String(
            String.UnicodeScalarView(value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
        ).prefix(bytes).description
        while result.utf8.count > bytes { result.removeLast() }
        return result.isEmpty ? nil : result
    }
    private static func parse(regions: [String], agent: RemoteAgent, id: String, modified: Date, now: Date)
        -> RemoteSessionSnapshot
    {
        var session = RemoteSessionSnapshot(
            id: clean(id, bytes: 128) ?? "unknown", agent: agent, state: .unknown, lastActivity: modified)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        var questions = Set<String>()
        var sawActivity = false
        for (index, text) in regions.enumerated() {
            if index > 0 {
                // The omitted middle may contain completion/cancellation. Keep
                // identity/model metadata, but never carry state across a gap.
                questions.removeAll()
                session.state = .unknown
                session.tool = nil
                session.lastActivity = modified
                sawActivity = false
            }
            for line in text.split(separator: "\n") {
                guard let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else {
                    continue
                }
                let type = obj["type"] as? String ?? ""
                let payload = obj["payload"] as? [String: Any] ?? [:]
                if let cwd = obj["cwd"] as? String { session.cwd = clean(cwd, bytes: 2048) }
                if agent == .codex {
                    if type == "session_meta" {
                        session.id = clean(payload["id"] as? String, bytes: 128) ?? session.id
                        session.cwd = clean(payload["cwd"] as? String, bytes: 2048) ?? session.cwd
                    }
                    if type == "turn_context" {
                        session.model = clean(payload["model"] as? String, bytes: 128) ?? session.model
                        session.cwd = clean(payload["cwd"] as? String, bytes: 2048) ?? session.cwd
                    }
                }
                guard let stamp = obj["timestamp"] as? String,
                    let at = iso.date(from: stamp) ?? plain.date(from: stamp),
                    at <= now.addingTimeInterval(300)
                else { continue }
                var activity = false
                if agent == .claude {
                    let message = obj["message"] as? [String: Any] ?? [:]
                    if obj["isApiErrorMessage"] as? Bool == true {
                        session.state = .error
                        activity = true
                    } else if message["model"] as? String == "<synthetic>" {
                        continue
                    } else if type == "user" {
                        guard obj["isMeta"] as? Bool != true, obj["isCompactSummary"] as? Bool != true else { continue }
                        let blocks = message["content"] as? [[String: Any]] ?? []
                        let text = message["content"] as? String ?? blocks.compactMap { $0["text"] as? String }.joined()
                        let injected = [
                            "<local-command-caveat>", "<local-command-stdout>", "<command-name>", "<command-message>",
                            "<task-notification>", "<system-reminder>",
                        ]
                        if injected.contains(where: text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix) {
                            continue
                        }
                        if !blocks.contains(where: { $0["type"] as? String == "tool_result" }) {
                            questions.removeAll()
                        }
                        for block in blocks where block["type"] as? String == "tool_result" {
                            if let id = block["tool_use_id"] as? String { questions.remove(id) }
                        }
                        session.state = questions.isEmpty ? .working : .waiting
                        activity = true
                    } else if type == "assistant" {
                        session.model = clean(message["model"] as? String, bytes: 128) ?? session.model
                        session.state = questions.isEmpty ? .working : .waiting
                        activity = true
                        for block in message["content"] as? [[String: Any]] ?? []
                        where block["type"] as? String == "tool_use" {
                            session.tool = clean(block["name"] as? String, bytes: 128)
                            if session.tool == "AskUserQuestion" {
                                questions.insert(block["id"] as? String ?? "question")
                                session.state = .waiting
                            }
                        }
                        if ["end_turn", "stop_sequence"].contains(message["stop_reason"] as? String ?? "") {
                            session.state = .idle
                            questions.removeAll()
                        }
                    } else if type == "system", obj["subtype"] as? String == "turn_duration" {
                        session.state = .idle
                        questions.removeAll()
                        activity = true
                    }
                } else if type == "event_msg" {
                    switch payload["type"] as? String ?? "" {
                    case "task_started", "user_message":
                        session.state = .working
                        questions.removeAll()
                        activity = true
                    case "task_complete", "task_aborted", "turn_aborted":
                        session.state = .idle
                        questions.removeAll()
                        activity = true
                    case "error", "task_failed":
                        session.state = .error
                        activity = true
                    default: break
                    }
                } else if type == "response_item" {
                    let kind = payload["type"] as? String ?? ""
                    if ["function_call", "custom_tool_call", "local_shell_call", "web_search_call"].contains(kind) {
                        session.tool = clean(payload["name"] as? String ?? kind, bytes: 128)
                        if session.tool?.components(separatedBy: ".").last == "request_user_input" {
                            questions.insert(payload["call_id"] as? String ?? "question")
                        }
                        session.state = questions.isEmpty ? .working : .waiting
                        activity = true
                    } else if ["function_call_output", "custom_tool_call_output"].contains(kind) {
                        if let id = payload["call_id"] as? String { questions.remove(id) }
                        session.state = questions.isEmpty ? .working : .waiting
                        activity = true
                    }
                }
                if activity {
                    session.lastActivity = sawActivity ? max(session.lastActivity, at) : at
                    sawActivity = true
                }
            }
        }
        return session
    }
    /// Read two bounded regions, without following a swapped link or FIFO.
    private static func readMetadata(_ url: URL) throws -> [String]? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else {
            if errno == ENOENT { return nil }
            throw CocoaError(.fileReadNoPermission)
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= 256 * 1024 * 1024 else {
            return nil
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let limit = 65_536
        if info.st_size <= 2 * limit {
            return [String(decoding: try handle.read(upToCount: 2 * limit) ?? Data(), as: UTF8.self)]
        }
        var head = try handle.read(upToCount: limit) ?? Data()
        if let newline = head.lastIndex(of: 10) { head = Data(head[...newline]) } else { head = Data() }
        try handle.seek(toOffset: UInt64(Int(info.st_size) - limit))
        var tail = try handle.read(upToCount: limit) ?? Data()
        if let newline = tail.firstIndex(of: 10) {
            tail = Data(tail.dropFirst(tail.distance(from: tail.startIndex, to: newline) + 1))
        } else {
            tail = Data()
        }
        return [String(decoding: head, as: UTF8.self), String(decoding: tail, as: UTF8.self)]
    }
}
