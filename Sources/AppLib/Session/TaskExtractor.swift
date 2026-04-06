import Foundation

/// Parses a Claude Code transcript JSONL file to reconstruct the current task list
/// by replaying all TaskCreate / TaskUpdate tool calls.
///
/// This is needed because TaskUpdate hooks don't carry the task's original subject —
/// only the initial TaskCreate does. If our bridge missed the TaskCreate (e.g., session
/// started before ZackEyes or hooks were loaded), we'd have no subject. The transcript
/// file records every tool call historically, so it's the source of truth.
public enum TaskExtractor {

    /// Extract the current task list from a transcript JSONL file.
    public static func extractTasks(fromTranscriptAt path: String) -> [TaskItem] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let text = String(data: data, encoding: .utf8) else {
            return []
        }

        // Preserve insertion order, keyed by task id
        var tasks: [String: TaskItem] = [:]
        var order: [String] = []

        for line in text.split(separator: "\n") {
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else { continue }

            // Only look at assistant messages with tool_use content
            guard let type = obj["type"] as? String, type == "assistant",
                  let msg = obj["message"] as? [String: Any],
                  let content = msg["content"] as? [[String: Any]]
            else { continue }

            for item in content where (item["type"] as? String) == "tool_use" {
                let name = item["name"] as? String ?? ""
                guard let input = item["input"] as? [String: Any] else { continue }

                switch name {
                case "TaskCreate":
                    guard let subject = input["subject"] as? String else { continue }
                    // TaskCreate doesn't return an id in the input — we'd need the tool_response
                    // for that. Since we can't reliably correlate create → id without the response,
                    // we use a synthetic id based on subject + order. Later TaskUpdate events
                    // will collide and overwrite; that's fine.
                    let id = "create-\(order.count)"
                    let task = TaskItem(id: id, subject: subject, status: "pending")
                    tasks[id] = task
                    order.append(id)

                case "TaskUpdate":
                    guard let taskId = input["taskId"] as? String else { continue }
                    let status = input["status"] as? String
                    let subject = input["subject"] as? String

                    if var existing = tasks[taskId] {
                        if let status = status { existing.status = status }
                        if let subject = subject { existing.subject = subject }
                        tasks[taskId] = existing
                    } else {
                        // Unknown task id — look back through tool_result entries in the
                        // transcript for TaskList output that mentions this id + subject.
                        // For simplicity, just stub it; a follow-up scan of tool_result
                        // entries will enrich it.
                        let stubSubject = subject ?? "Task \(taskId.prefix(6))"
                        let task = TaskItem(
                            id: taskId,
                            subject: stubSubject,
                            status: status ?? "pending"
                        )
                        tasks[taskId] = task
                        order.append(taskId)
                    }

                default:
                    break
                }
            }

            // Also look at tool_result entries — TaskList returns the full task list
            // as structured output. If we find one, prefer it as source of truth.
            if type == "user",
               let userMsg = obj["message"] as? [String: Any],
               let userContent = userMsg["content"] as? [[String: Any]] {
                for item in userContent where (item["type"] as? String) == "tool_result" {
                    enrichFromToolResult(item: item, tasks: &tasks, order: &order)
                }
            }
        }

        return order.compactMap { tasks[$0] }
    }

    /// TaskList / TaskGet / TaskCreate tool_result may contain the full task list
    /// with ids and subjects. Parse it to fill in missing subjects.
    private static func enrichFromToolResult(
        item: [String: Any],
        tasks: inout [String: TaskItem],
        order: inout [String]
    ) {
        // tool_result content can be a string (JSON text) or an array of blocks
        let contentBlocks: [[String: Any]]
        if let blocks = item["content"] as? [[String: Any]] {
            contentBlocks = blocks
        } else if let single = item["content"] as? String {
            contentBlocks = [["type": "text", "text": single]]
        } else {
            return
        }

        for block in contentBlocks {
            guard let text = block["text"] as? String else { continue }
            // Try to parse as JSON. TaskList returns something like:
            // { "tasks": [ { "id": "1", "subject": "...", "status": "..." }, ... ] }
            // or just an array.
            guard let data = text.data(using: .utf8) else { continue }
            guard let parsed = try? JSONSerialization.jsonObject(with: data) else { continue }

            var taskArray: [[String: Any]] = []
            if let arr = parsed as? [[String: Any]] {
                taskArray = arr
            } else if let dict = parsed as? [String: Any],
                      let arr = dict["tasks"] as? [[String: Any]] {
                taskArray = arr
            }

            for taskDict in taskArray {
                guard let id = taskDict["id"] as? String else { continue }
                let subject = taskDict["subject"] as? String
                let status = taskDict["status"] as? String

                if var existing = tasks[id] {
                    if let s = subject { existing.subject = s }
                    if let st = status { existing.status = st }
                    tasks[id] = existing
                } else if let subject = subject {
                    tasks[id] = TaskItem(id: id, subject: subject, status: status ?? "pending")
                    order.append(id)
                }
            }
        }
    }
}
