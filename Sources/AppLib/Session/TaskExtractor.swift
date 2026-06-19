import Foundation

/// Parses a Claude Code transcript JSONL file to reconstruct the current task list
/// by replaying all TaskCreate / TaskUpdate tool calls and correlating their
/// tool_result entries (which contain the real task id).
///
/// Example transcript entries:
///
///   tool_use   → TaskCreate input={"subject":"Push cogni-wiki to GitHub"}
///                tool_use_id=toolu_01ABC...
///   tool_result → "Task #11 created successfully: Push cogni-wiki to GitHub"
///                 tool_use_id=toolu_01ABC...
///
/// TaskUpdate uses the real id directly: input={"taskId":"11","status":"in_progress"}
public enum TaskExtractor {

    public static func extractTasks(fromTranscriptAt path: String) -> [TaskItem] {
        // Bound this read like the transcript scan (T-2): skip symlinks and
        // files over the 256MB cap before slurping the whole file. PR #119's cap
        // covered UsageTracker but not this sibling whole-file reader.
        let url = URL(fileURLWithPath: path)
        guard let rv = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey]),
              let size = rv.fileSize,
              UsageTracker.shouldScanTranscript(
                isSymbolicLink: rv.isSymbolicLink ?? false, fileSize: size) else {
            return []
        }
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else {
            return []
        }

        var tasks: [String: TaskItem] = [:]   // keyed by real task id (current turn only)
        var order: [String] = []
        // Pending TaskCreate tool_use entries waiting for their tool_result
        // to reveal the real id. Keyed by tool_use_id.
        var pendingCreates: [String: String] = [:]  // tool_use_id → subject

        for line in text.split(separator: "\n") {
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else { continue }

            guard let type = obj["type"] as? String,
                  let msg = obj["message"] as? [String: Any],
                  let content = msg["content"] as? [[String: Any]]
            else { continue }

            // Turn boundary: a user message containing plain text (not a tool_result)
            // marks the start of a new turn. Reset task state to show only current turn's tasks.
            if type == "user" && isUserPromptMessage(content: content) {
                tasks.removeAll()
                order.removeAll()
                pendingCreates.removeAll()
            }

            if type == "assistant" {
                // tool_use entries from Claude
                for item in content where (item["type"] as? String) == "tool_use" {
                    let name = item["name"] as? String ?? ""
                    guard let input = item["input"] as? [String: Any] else { continue }
                    guard let toolUseId = item["id"] as? String else { continue }

                    switch name {
                    case "TaskCreate":
                        if let subject = input["subject"] as? String {
                            pendingCreates[toolUseId] = subject
                        }

                    case "TaskUpdate":
                        guard let taskId = input["taskId"] as? String else { continue }
                        if var existing = tasks[taskId] {
                            if let status = input["status"] as? String { existing.status = status }
                            if let subject = input["subject"] as? String { existing.subject = subject }
                            tasks[taskId] = existing
                        } else {
                            // Unknown task — stub with whatever we have
                            let stubSubject = (input["subject"] as? String) ?? "Task \(taskId)"
                            let status = (input["status"] as? String) ?? "pending"
                            tasks[taskId] = TaskItem(id: taskId, subject: stubSubject, status: status)
                            order.append(taskId)
                        }

                    default:
                        break
                    }
                }
            } else if type == "user" {
                // tool_result entries from Claude Code (these are user-role messages
                // because the tool result is sent back as user input)
                for item in content where (item["type"] as? String) == "tool_result" {
                    guard let toolUseId = item["tool_use_id"] as? String else { continue }

                    // If this result matches a pending TaskCreate, extract the real id
                    if let subject = pendingCreates[toolUseId] {
                        let resultText = toolResultString(item)
                        if let taskId = parseCreatedTaskId(resultText) {
                            let task = TaskItem(id: taskId, subject: subject, status: "pending")
                            tasks[taskId] = task
                            if !order.contains(taskId) { order.append(taskId) }
                        }
                        pendingCreates.removeValue(forKey: toolUseId)
                    }
                }
            }
        }

        return order.compactMap { tasks[$0] }
    }

    // MARK: - Helpers

    /// A user-role message is a real user prompt (not a tool_result) if it contains
    /// at least one `text` block (and no `tool_result` blocks).
    private static func isUserPromptMessage(content: [[String: Any]]) -> Bool {
        var hasText = false
        for item in content {
            let kind = item["type"] as? String
            if kind == "tool_result" { return false }
            if kind == "text" { hasText = true }
        }
        return hasText
    }

    /// Extract the text content from a tool_result block.
    /// The content can be a string, or an array of blocks with `text` fields.
    private static func toolResultString(_ item: [String: Any]) -> String {
        if let s = item["content"] as? String {
            return s
        }
        if let blocks = item["content"] as? [[String: Any]] {
            return blocks.compactMap { $0["text"] as? String }.joined(separator: " ")
        }
        return ""
    }

    /// Parse "Task #<id> created successfully: ..." to extract the id.
    /// Also handles minor variations like "Created task #<id>".
    private static func parseCreatedTaskId(_ text: String) -> String? {
        // Look for "#<digits>" pattern
        let pattern = #"#(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let idRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[idRange])
    }
}
