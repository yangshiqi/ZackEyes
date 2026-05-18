import Foundation
import Shared

/// Scans the JSONL transcript trees produced by Claude Code and Codex CLI to
/// discover sessions that were already running when ZackEyes started. These
/// sessions are "detected" (read-only) because their hooks were loaded before
/// ZackEyes started — they won't send live events until the user opens a new
/// thread or restarts the agent.
public struct SessionScanner {

    public struct DetectedSession: Sendable {
        public let id: String
        public let agent: AgentKind
        public let cwd: String?
        public let lastModified: Date
        public let lastUserPrompt: String?
        public let messageCount: Int
        public let transcriptPath: String
    }

    private let projectsDir: URL
    private let codexSessionsDir: URL?

    public init(
        projectsDir: URL = URL(fileURLWithPath: NSHomeDirectory() + "/.claude/projects"),
        codexSessionsDir: URL? = URL(fileURLWithPath: NSHomeDirectory() + "/.codex/sessions")
    ) {
        self.projectsDir = projectsDir
        self.codexSessionsDir = codexSessionsDir
    }

    /// Scan all known transcript directories. Returns sessions whose jsonl
    /// files were modified within the recency window, with their `agent`
    /// stamped from the directory they were found in.
    ///
    /// Claude and Codex use **separate windows** because the two agents
    /// have different session lifecycles:
    ///
    /// - Claude often keeps a single session open for hours of intermittent
    ///   work, so a wide window (8h) is appropriate.
    /// - Codex creates a fresh rollout per `codex` invocation, and once
    ///   the user closes the TUI the rollout is dead. Importing every
    ///   rollout written in the last 8h would surface dozens of stale
    ///   "idle" cards for sessions that no longer exist. A tight window
    ///   (default 30 min) keeps the notch focused on currently-running
    ///   codex threads.
    public func scan(
        claudeRecencyMinutes: Int = 480,
        codexRecencyMinutes: Int = 30
    ) -> [DetectedSession] {
        let claudeCutoff = Date().addingTimeInterval(-Double(claudeRecencyMinutes * 60))
        let codexCutoff = Date().addingTimeInterval(-Double(codexRecencyMinutes * 60))
        var results: [DetectedSession] = []
        results.append(contentsOf: scanClaude(cutoff: claudeCutoff))
        if let codexDir = codexSessionsDir {
            results.append(contentsOf: scanCodex(rootDir: codexDir, cutoff: codexCutoff))
        }
        return results.sorted { $0.lastModified > $1.lastModified }
    }

    /// Convenience overload preserved for callers (and tests) that want a
    /// single window applied to both agents.
    public func scan(recencyMinutes: Int) -> [DetectedSession] {
        scan(claudeRecencyMinutes: recencyMinutes, codexRecencyMinutes: recencyMinutes)
    }

    // MARK: - Claude (~/.claude/projects/<encoded-cwd>/<sessionId>.jsonl)

    private func scanClaude(cutoff: Date) -> [DetectedSession] {
        let fm = FileManager.default
        guard let projectDirs = try? fm.contentsOfDirectory(at: projectsDir, includingPropertiesForKeys: nil) else {
            return []
        }

        var results: [DetectedSession] = []
        for projectDir in projectDirs {
            guard let files = try? fm.contentsOfDirectory(
                at: projectDir,
                includingPropertiesForKeys: [.contentModificationDateKey]
            ) else { continue }

            for file in files where file.pathExtension == "jsonl" {
                // Use the URL's pre-fetched resource values (we asked
                // contentsOfDirectory for .contentModificationDateKey) so
                // we don't pay a second stat() per file via attributesOfItem.
                guard let modDate = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                      modDate >= cutoff else { continue }

                let sessionId = file.deletingPathExtension().lastPathComponent
                if let session = parseClaudeSession(at: file, id: sessionId, lastModified: modDate) {
                    results.append(session)
                }
            }
        }
        return results
    }

    /// Parse the tail of a Claude jsonl file to extract session metadata.
    private func parseClaudeSession(at url: URL, id: String, lastModified: Date) -> DetectedSession? {
        guard let text = readTail(of: url, maxBytes: 65_536) else { return nil }

        var cwd: String? = nil
        var lastUserPrompt: String? = nil
        var messageCount = 0

        for line in text.split(separator: "\n") {
            guard let lineData = line.data(using: .utf8) else { continue }
            guard let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }

            if let cwdValue = obj["cwd"] as? String {
                cwd = cwdValue
            }

            if let type = obj["type"] as? String, type == "user" {
                messageCount += 1
                if let msg = obj["message"] as? [String: Any] {
                    let content = msg["content"]
                    if let text = content as? String, !text.isEmpty, !text.hasPrefix("<tool_use_error>") {
                        lastUserPrompt = text
                    } else if let arr = content as? [[String: Any]] {
                        let textParts = arr.compactMap { part -> String? in
                            guard part["type"] as? String == "text" else { return nil }
                            return part["text"] as? String
                        }
                        if !textParts.isEmpty {
                            lastUserPrompt = textParts.joined(separator: " ")
                        }
                    }
                }
            }
        }

        return DetectedSession(
            id: id,
            agent: .claude,
            cwd: cwd,
            lastModified: lastModified,
            lastUserPrompt: lastUserPrompt,
            messageCount: messageCount,
            transcriptPath: url.path
        )
    }

    // MARK: - Codex (~/.codex/sessions/YYYY/MM/DD/rollout-<ts>-<uuid>.jsonl)

    /// Walk every `YYYY/MM/DD` subdirectory and pick the rollouts whose
    /// **file mtime** is within the recency window. Codex partitions new
    /// sessions by UTC date, but `codex --resume <id>` keeps appending to
    /// the original session's date dir, which can be arbitrarily old. The
    /// previous date-window pruning silently dropped those resumed sessions
    /// even when their files were freshly modified — they'd be invisible to
    /// the notch until the user started a brand-new codex thread.
    private func scanCodex(rootDir: URL, cutoff: Date) -> [DetectedSession] {
        let fm = FileManager.default
        var results: [DetectedSession] = []
        for day in Self.allDateDirs(under: rootDir) {
            guard let files = try? fm.contentsOfDirectory(
                at: day,
                includingPropertiesForKeys: [.contentModificationDateKey]
            ) else { continue }
            for file in files where file.pathExtension == "jsonl" {
                guard let modDate = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                      modDate >= cutoff else { continue }
                if let session = parseCodexSession(at: file, lastModified: modDate) {
                    results.append(session)
                }
            }
        }
        return results
    }

    /// Enumerate every `<rootDir>/YYYY/MM/DD` directory that exists on disk.
    /// Used by both the initial scanner and the live tailer because codex's
    /// `--resume` flow can keep an arbitrarily old date dir active.
    ///
    /// Performance: a heavy user with one codex session per day for several
    /// years lands at <2000 day dirs; the per-dir cost paid by callers is
    /// one `contentsOfDirectory` + a file-mtime check, so the total walk is
    /// dominated by file I/O, not by the day-dir count. The non-prod option
    /// of `find -type d -maxdepth 3` would be slightly faster but adds a
    /// subprocess dependency we'd rather avoid.
    static func allDateDirs(under rootDir: URL) -> [URL] {
        let fm = FileManager.default
        var dirs: [URL] = []
        let years = (try? fm.contentsOfDirectory(
            at: rootDir, includingPropertiesForKeys: nil
        )) ?? []
        for year in years where isAllDigits(year.lastPathComponent, length: 4) {
            let months = (try? fm.contentsOfDirectory(
                at: year, includingPropertiesForKeys: nil
            )) ?? []
            for month in months where isAllDigits(month.lastPathComponent, length: 2) {
                let days = (try? fm.contentsOfDirectory(
                    at: month, includingPropertiesForKeys: nil
                )) ?? []
                for day in days where isAllDigits(day.lastPathComponent, length: 2) {
                    dirs.append(day)
                }
            }
        }
        return dirs
    }

    private static func isAllDigits(_ s: String, length: Int) -> Bool {
        s.count == length && s.allSatisfy { $0 >= "0" && $0 <= "9" }
    }

    /// Codex rollout file names embed the session UUID as the trailing
    /// segment after the ISO timestamp:
    ///   `rollout-2026-05-03T14-27-59-019dec85-b760-71f2-bca7-b1c463f0d36e.jsonl`
    /// The UUID is the canonical 5-group form (8-4-4-4-12 hex). We pick the
    /// last five `-`-joined groups whose total length is 36 to form the id —
    /// the timestamp's own dashes never look like a UUID.
    static func extractCodexSessionId(fromFilename name: String) -> String? {
        let stem = (name as NSString).deletingPathExtension
        let parts = stem.split(separator: "-").map(String.init)
        guard parts.count >= 5 else { return nil }
        let tail = parts.suffix(5).joined(separator: "-")
        // UUID canonical length is 36 chars (32 hex + 4 dashes).
        guard tail.count == 36 else { return nil }
        return tail
    }

    /// Codex session jsonl schema (verified against codex-tui 0.128.0):
    /// - line 0 is `{"type":"session_meta","payload":{"id","cwd","timestamp",...}}`
    /// - subsequent `event_msg` lines with `payload.type=user_message`
    ///   carry the user prompt text in `payload.message`.
    /// Read the head for cwd, the tail for the last user prompt — same tail
    /// budget as the Claude parser.
    private func parseCodexSession(at url: URL, lastModified: Date) -> DetectedSession? {
        guard let id = Self.extractCodexSessionId(fromFilename: url.lastPathComponent) else {
            return nil
        }

        let cwd = CodexJsonlTailer.parseSessionMetaCwd(at: url)

        // Tail: last 64KB for user_message events.
        var lastUserPrompt: String? = nil
        var messageCount = 0
        if let tail = readTail(of: url, maxBytes: 65_536) {
            for line in tail.split(separator: "\n") {
                guard let lineData = line.data(using: .utf8) else { continue }
                guard let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }
                guard obj["type"] as? String == "event_msg" else { continue }
                guard let payload = obj["payload"] as? [String: Any] else { continue }
                guard payload["type"] as? String == "user_message" else { continue }
                messageCount += 1
                if let msg = payload["message"] as? String, !msg.isEmpty {
                    lastUserPrompt = msg
                }
            }
        }

        return DetectedSession(
            id: id,
            agent: .codex,
            cwd: cwd,
            lastModified: lastModified,
            lastUserPrompt: lastUserPrompt,
            messageCount: messageCount,
            transcriptPath: url.path
        )
    }

    // MARK: - Shared file IO

    private func readTail(of url: URL, maxBytes: UInt64) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let fileSize: UInt64
        do {
            fileSize = try handle.seekToEnd()
        } catch {
            return nil
        }
        let offset = fileSize > maxBytes ? fileSize - maxBytes : 0
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd() else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
