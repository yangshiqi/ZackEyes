import Foundation

/// Scans ~/.claude/projects/ to discover existing Claude Code sessions.
/// These sessions are "detected" (read-only) because their hooks were loaded
/// before ZackEyes started — they won't send live events.
public struct SessionScanner {

    public struct DetectedSession: Sendable {
        public let id: String
        public let cwd: String?
        public let lastModified: Date
        public let lastUserPrompt: String?
        public let messageCount: Int
    }

    private let projectsDir: URL

    public init(projectsDir: URL = URL(fileURLWithPath: NSHomeDirectory() + "/.claude/projects")) {
        self.projectsDir = projectsDir
    }

    /// Scan all project directories, return sessions with jsonl files modified in the last N minutes.
    public func scan(recencyMinutes: Int = 60) -> [DetectedSession] {
        let fm = FileManager.default
        guard let projectDirs = try? fm.contentsOfDirectory(at: projectsDir, includingPropertiesForKeys: nil) else {
            return []
        }

        let cutoff = Date().addingTimeInterval(-Double(recencyMinutes * 60))
        var results: [DetectedSession] = []

        for projectDir in projectDirs {
            guard let files = try? fm.contentsOfDirectory(
                at: projectDir,
                includingPropertiesForKeys: [.contentModificationDateKey]
            ) else { continue }

            for file in files where file.pathExtension == "jsonl" {
                guard let attrs = try? fm.attributesOfItem(atPath: file.path),
                      let modDate = attrs[.modificationDate] as? Date,
                      modDate >= cutoff else { continue }

                let sessionId = file.deletingPathExtension().lastPathComponent
                if let session = parseSession(at: file, id: sessionId, lastModified: modDate) {
                    results.append(session)
                }
            }
        }

        return results.sorted { $0.lastModified > $1.lastModified }
    }

    /// Parse the tail of a jsonl file to extract session metadata.
    private func parseSession(at url: URL, id: String, lastModified: Date) -> DetectedSession? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        // Read the last ~64KB of the file (more than enough for recent messages)
        let fileSize: UInt64
        do {
            fileSize = try handle.seekToEnd()
        } catch {
            return nil
        }

        let readSize: UInt64 = 65536
        let offset = fileSize > readSize ? fileSize - readSize : 0
        try? handle.seek(toOffset: offset)

        guard let data = try? handle.readToEnd() else { return nil }
        guard let text = String(data: data, encoding: .utf8) else { return nil }

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
            cwd: cwd,
            lastModified: lastModified,
            lastUserPrompt: lastUserPrompt,
            messageCount: messageCount
        )
    }
}
