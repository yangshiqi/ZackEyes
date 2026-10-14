import CoreFoundation
import Foundation
import Shared

/// Pure extraction of count observations. No text/argument content escapes this file.
enum UsageLedgerParser {
    static func parse(text: String, agent: AgentKind, sourceID: String, onIssue: (() -> Void)? = nil)
        -> [UsageLedgerRecord]
    {
        let objects = text.split(separator: "\n").compactMap { line -> [String: Any]? in
            guard line.utf8.count <= 1_048_576,
                let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
            else {
                onIssue?()
                return nil
            }
            return object
        }
        let meta = objects.first { $0["type"] as? String == "session_meta" }?["payload"] as? [String: Any]
        let rawSession =
            (meta?["id"] as? String) ?? objects.compactMap { ($0["sessionId"] ?? $0["session_id"]) as? String }.first
            ?? sourceID
        let subagent = objects.compactMap { $0["agentId"] as? String }.first ?? ""
        let session = UsageLedgerRecord.identity("\(agent.rawValue):\(rawSession):\(subagent)")
        let cwd = (meta?["cwd"] as? String) ?? objects.compactMap { $0["cwd"] as? String }.first
        let project = UsageLedgerRecord.label(cwd.flatMap { JournalCollector.projectName(fromCwd: $0) })
        var model = UsageLedgerRecord.label(meta?["model"] as? String)
        var out: [String: UsageLedgerRecord] = [:]
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plainISO = ISO8601DateFormatter()
        var pendingTools: [String: (Date, String)] = [:]
        var turnStart: Date?
        var previousActivity: Date?
        var previousTotals: [String: Int] = [:]

        func emit(
            _ kind: UsageLedgerRecord.Kind, key: String, at: Date, end: Date? = nil,
            input: Int = 0, output: Int = 0, read: Int = 0, write: Int = 0, tool: String? = nil
        ) {
            let id = UsageLedgerRecord.identity("\(agent.rawValue):\(key)")
            let record = UsageLedgerRecord(
                id: id, session: session, agent: agent, project: project, model: model,
                date: at, kind: kind, input: input, output: output, cacheRead: read,
                cacheWrite: write, tool: tool, end: end)
            if out[id].map({ record.supersedes($0) }) ?? true { out[id] = record }
        }
        func interval(_ start: Date, _ finish: Date, wait: Bool = false) {
            guard finish > start else { return }
            emit(
                wait ? .wait : .work, key: "\(session):\(wait ? "wait" : "work"):\(start.timeIntervalSince1970)",
                at: start, end: finish)
        }
        func activity(_ at: Date, startsTurn: Bool = false) {
            if startsTurn { previousActivity = nil }
            if let previous = previousActivity {
                let gap = at.timeIntervalSince(previous)
                // No evidence bridges a long idle gap; completed pairs below may.
                if gap > 0 && gap <= 1800 { interval(previous, min(at, previous.addingTimeInterval(300))) }
            }
            previousActivity = at
        }
        func toolStart(id: String, name: String, at: Date) {
            let name = UsageLedgerRecord.label(name)
            emit(.tool, key: "\(session):tool:\(id)", at: at, tool: name)
            pendingTools[id] = (at, name)
        }
        func toolEnd(id: String, at: Date) {
            guard let (start, name) = pendingTools.removeValue(forKey: id) else { return }
            interval(
                start, at,
                wait: ["AskUserQuestion", "request_user_input"].contains(name.components(separatedBy: ".").last ?? name)
            )
        }
        func isQuestion(_ name: String) -> Bool {
            ["AskUserQuestion", "request_user_input"].contains(name.components(separatedBy: ".").last ?? name)
        }
        func closeQuestions(at: Date) {
            let questions = pendingTools.filter { isQuestion($0.value.1) }
            for (id, value) in questions {
                interval(value.0, at, wait: true)
                pendingTools.removeValue(forKey: id)
            }
        }
        for (index, obj) in objects.enumerated() {
            if index.isMultiple(of: 256), Task.isCancelled { return [] }
            let type = obj["type"] as? String
            let payload = obj["payload"] as? [String: Any] ?? [:]
            if agent == .codex {
                if type == "turn_context", let value = payload["model"] as? String {
                    model = UsageLedgerRecord.label(value)
                }
                if type == "event_msg",
                    ["thread_settings_applied", "session_configured"].contains(payload["type"] as? String ?? "")
                {
                    let settings = payload["thread_settings"] as? [String: Any] ?? payload
                    if let value = settings["model"] as? String { model = UsageLedgerRecord.label(value) }
                }
            }
            guard let stamp = obj["timestamp"] as? String,
                let at = iso.date(from: stamp) ?? plainISO.date(from: stamp)
            else { continue }
            if agent == .claude {
                guard type == "user" || type == "assistant", let message = obj["message"] as? [String: Any],
                    obj["isApiErrorMessage"] as? Bool != true, message["model"] as? String != "<synthetic>"
                else { continue }
                if let value = message["model"] as? String { model = UsageLedgerRecord.label(value) }
                let blocks = message["content"] as? [[String: Any]] ?? []
                let isUserTurn = type == "user" && !blocks.contains { $0["type"] as? String == "tool_result" }
                if isUserTurn {
                    let content =
                        message["content"] as? String
                        ?? blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }
                        .joined()
                    let injectedTags = [
                        "<local-command-caveat>", "<local-command-stdout>", "<command-name>", "<command-message>",
                        "<system-reminder>", "<task-notification>", "<tool_use_error>",
                    ]
                    let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
                    if obj["isMeta"] as? Bool == true || obj["isCompactSummary"] as? Bool == true
                        || injectedTags.contains(where: trimmed.hasPrefix)
                    {
                        continue
                    }
                    closeQuestions(at: at)
                }
                activity(at, startsTurn: isUserTurn)
                if isUserTurn { turnStart = at }
                if let usage = message["usage"] as? [String: Any],
                    usage["input_tokens"] != nil, usage["output_tokens"] != nil
                {
                    if let input = count(usage["input_tokens"]), let output = count(usage["output_tokens"]),
                        let cached = count(usage["cache_read_input_tokens"]),
                        let writes = count(usage["cache_creation_input_tokens"])
                    {
                        let key =
                            (message["id"] as? String).flatMap { $0.isEmpty ? nil : $0 }.map { "message:\($0)" }
                            ?? "\(session):\(sourceID):message:\(index)"
                        emit(.tokens, key: key, at: at, input: input, output: output, read: cached, write: writes)
                    } else {
                        onIssue?()
                    }
                }
                for (blockIndex, block) in blocks.enumerated() {
                    if block["type"] as? String == "tool_use", let name = block["name"] as? String {
                        let id = block["id"] as? String ?? "\(sourceID):\(index):\(blockIndex)"
                        toolStart(id: id, name: name, at: at)
                    } else if block["type"] as? String == "tool_result", let id = block["tool_use_id"] as? String {
                        toolEnd(id: id, at: at)
                    }
                }
                if ["end_turn", "stop_sequence"].contains(message["stop_reason"] as? String ?? "") {
                    closeQuestions(at: at)
                    if let start = turnStart { interval(start, at) }
                    turnStart = nil
                    previousActivity = nil
                }
            } else if type == "event_msg" {
                let kind = payload["type"] as? String ?? ""
                if kind == "token_count" {
                    guard let info = payload["info"] as? [String: Any],
                        let totals = info["total_token_usage"] as? [String: Any]
                    else { continue }
                    let keys = ["input_tokens", "output_tokens", "cached_input_tokens", "cache_write_input_tokens"]
                    var current: [String: Int] = [:]
                    var valid = true
                    for key in keys {
                        if let raw = totals[key] {
                            if let value = count(raw) { current[key] = value } else { valid = false }
                        } else {
                            current[key] = previousTotals[key] ?? 0
                        }
                    }
                    guard valid else {
                        onIssue?()
                        continue
                    }
                    previousTotals = current
                    // Persist cumulative evidence, not predecessor-dependent deltas:
                    // partial/copy prefixes merge before the summary differences it.
                    let identity = keys.map { String(current[$0, default: 0]) }.joined(separator: ":")
                    emit(
                        .counter, key: "\(session):counter:\(at.timeIntervalSince1970):\(identity)", at: at,
                        input: current["input_tokens", default: 0], output: current["output_tokens", default: 0],
                        read: current["cached_input_tokens", default: 0],
                        write: current["cache_write_input_tokens", default: 0])
                } else if kind == "task_started" {
                    closeQuestions(at: at)
                    activity(at, startsTurn: true)
                    turnStart = at
                } else if ["task_complete", "task_aborted"].contains(kind) {
                    closeQuestions(at: at)
                    if let start = turnStart { interval(start, at) }
                    turnStart = nil
                    previousActivity = nil
                } else if ["user_message", "agent_message"].contains(kind) {
                    if kind == "user_message" { closeQuestions(at: at) }
                    activity(at, startsTurn: kind == "user_message")
                }
            } else if type == "response_item" {
                let kind = payload["type"] as? String ?? ""
                if ["function_call", "custom_tool_call", "local_shell_call", "web_search_call"].contains(kind) {
                    let name = payload["name"] as? String ?? (kind == "local_shell_call" ? "shell" : kind)
                    activity(at)
                    toolStart(
                        id: payload["call_id"] as? String ?? payload["id"] as? String ?? "\(sourceID):\(index)",
                        name: name, at: at)
                } else if ["function_call_output", "custom_tool_call_output"].contains(kind),
                    let id = payload["call_id"] as? String
                {
                    activity(at)
                    toolEnd(id: id, at: at)
                }
            }
        }
        return out.values.filter(\.isValid).sorted { $0.date == $1.date ? $0.id < $1.id : $0.date < $1.date }
    }

    private static func count(_ raw: Any?) -> Int? {
        guard let raw else { return 0 }
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let value = number.doubleValue
        guard value.isFinite, value >= 0, value <= 1_000_000_000, value.rounded(.towardZero) == value else {
            return nil
        }
        return Int(value)
    }
}
