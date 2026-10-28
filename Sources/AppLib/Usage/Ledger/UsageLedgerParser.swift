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
        var state = seed(objects: objects, agent: agent, sourceID: sourceID)
        return consume(objects: objects, state: &state, onIssue: onIssue)
    }

    struct State: Codable, Sendable {
        struct Pending: Codable, Sendable {
            var date: Date
            var name: String
        }
        var agent: AgentKind
        var sourceID: String
        var session: String
        var project: String
        var model: String
        var pending: [String: Pending] = [:]
        var turnStart: Date?
        var previousActivity: Date?
        var previousTotals: [String: Int] = [:]
        var rowIndex = 0
        var truncatedTools = false
        var inheritedBaseline: UsageLedgerRecord? = nil
        var needsInheritedBaseline: Bool? = nil
        struct PendingCounter: Codable, Sendable {
            var date: Date
            var values: [String: Int]
        }
        var pendingCounter: PendingCounter? = nil
    }

    static func seed(objects: [[String: Any]], agent: AgentKind, sourceID: String, inherited: CodexUsageHistory.Baseline? = nil) -> State {
        let meta = objects.first { $0["type"] as? String == "session_meta" }?["payload"] as? [String: Any]
        let rawSession =
            (meta?["id"] as? String) ?? objects.compactMap { ($0["sessionId"] ?? $0["session_id"]) as? String }.first
            ?? sourceID
        let subagent = objects.compactMap { $0["agentId"] as? String }.first ?? ""
        let session = UsageLedgerRecord.identity("\(agent.rawValue):\(rawSession):\(subagent)")
        let cwd = (meta?["cwd"] as? String) ?? objects.compactMap { $0["cwd"] as? String }.first
        let project = UsageLedgerRecord.label(cwd.flatMap { JournalCollector.projectName(fromCwd: $0) })
        let model = UsageLedgerRecord.label(meta?["model"] as? String)
        var state = State(agent: agent, sourceID: sourceID, session: session, project: project, model: model)
        if agent == .codex, CodexUsageHistory.hasInheritedHistory(meta) {
            state.needsInheritedBaseline = inherited == nil
            if let inherited {
                let u = inherited.usage
                state.previousTotals = ["input_tokens": u.input, "cached_input_tokens": u.cached,
                    "output_tokens": u.output, "cache_write_input_tokens": u.writes]
            }
            if let inherited, inherited.date != .distantPast {
                let u = inherited.usage
                var record = UsageLedgerRecord(id: UsageLedgerRecord.identity("\(session):baseline:\(inherited.date.timeIntervalSince1970):\(u.input):\(u.cached):\(u.output):\(u.writes)"),
                    session: session, agent: agent, project: project, model: model, date: inherited.date, kind: .counter,
                    input: u.input, output: u.output, cacheRead: u.cached, cacheWrite: u.writes)
                record.baseline = true
                state.inheritedBaseline = record
            }
        }
        return state
    }

    static func consume(objects: [[String: Any]], state: inout State, onIssue: (() -> Void)? = nil)
        -> [UsageLedgerRecord]
    {
        let agent = state.agent
        let sourceID = state.sourceID
        let session = state.session
        let project = state.project
        var model = state.model
        var out: [String: UsageLedgerRecord] = [:]
        if let inherited = state.inheritedBaseline {
            out[inherited.id] = inherited
            state.inheritedBaseline = nil
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plainISO = ISO8601DateFormatter()
        var pendingTools = state.pending.mapValues { ($0.date, $0.name) }
        var turnStart = state.turnStart
        var previousActivity = state.previousActivity
        var truncatedTools = state.truncatedTools
        var previousTotals = state.previousTotals
        defer {
            state.truncatedTools = truncatedTools
            state.model = model
            state.pending = pendingTools.mapValues { State.Pending(date: $0.0, name: $0.1) }
            state.turnStart = turnStart
            state.previousActivity = previousActivity
            state.previousTotals = previousTotals
        }

        func emit(
            _ kind: UsageLedgerRecord.Kind, key: String, at: Date, end: Date? = nil,
            input: Int = 0, output: Int = 0, read: Int = 0, write: Int = 0, tool: String? = nil
        ) {
            let id = UsageLedgerRecord.identity("\(agent.rawValue):\(key)")
            var record = UsageLedgerRecord(
                id: id, session: session, agent: agent, project: project, model: model,
                date: at, kind: kind, input: input, output: output, cacheRead: read,
                cacheWrite: write, tool: tool, end: end)
            if kind == .counter { record.baseline = false }
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
            let key = UsageLedgerRecord.identity(id)
            if pendingTools[key] == nil, pendingTools.count >= 256,
                let oldest = pendingTools.min(by: { $0.value.0 < $1.value.0 })?.key
            {
                pendingTools.removeValue(forKey: oldest)
                truncatedTools = true
                onIssue?()
            }
            pendingTools[key] = (at, name)
        }
        func toolEnd(id: String, at: Date) {
            guard let (start, name) = pendingTools.removeValue(forKey: UsageLedgerRecord.identity(id)) else { return }
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
        for obj in objects {
            let index = state.rowIndex
            state.rowIndex += 1
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
                            if let value = count(raw, maximum: CodexUsageTotals.maximumCumulativeTokens) { current[key] = value } else { valid = false }
                        } else {
                            current[key] = previousTotals[key] ?? 0
                        }
                    }
                    guard valid else {
                        onIssue?()
                        continue
                    }
                    var gap: State.PendingCounter?
                    if let pending = state.pendingCounter {
                        if keys.allSatisfy({ key in
                            let delta = current[key, default: 0] - pending.values[key, default: 0]
                            return (0...1_000_000_000).contains(delta)
                        }) {
                            previousTotals = pending.values
                            gap = pending
                        }
                        state.pendingCounter = nil
                    }
                    let firstCounter = previousTotals.isEmpty
                    if current["input_tokens", default: 0] < previousTotals["input_tokens", default: 0]
                        || current["output_tokens", default: 0] < previousTotals["output_tokens", default: 0] {
                        for key in keys where totals[key] == nil { current[key] = 0 }
                    }
                    let reset = current["input_tokens", default: 0] < previousTotals["input_tokens", default: 0]
                        || current["output_tokens", default: 0] < previousTotals["output_tokens", default: 0]
                    let oversized = keys.contains { key in
                        max(0, current[key, default: 0] - (reset ? 0 : previousTotals[key, default: 0])) > 1_000_000_000
                    }
                    let initialBaseline = state.needsInheritedBaseline == true || (firstCounter && oversized)
                    if oversized && !initialBaseline {
                        state.pendingCounter = .init(date: at, values: current)
                        onIssue?()
                        continue
                    }
                    if let gap {
                        let identity = keys.map { String(gap.values[$0, default: 0]) }.joined(separator: ":")
                        let key = "\(session):gap-baseline:\(gap.date.timeIntervalSince1970):\(identity)"
                        emit(.counter, key: key, at: gap.date,
                             input: gap.values["input_tokens", default: 0], output: gap.values["output_tokens", default: 0],
                             read: gap.values["cached_input_tokens", default: 0], write: gap.values["cache_write_input_tokens", default: 0])
                        out[UsageLedgerRecord.identity("\(agent.rawValue):\(key)")]?.baseline = true
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
                    if initialBaseline {
                        // Establish a non-billable baseline when ancestors are unavailable.
                        let key = UsageLedgerRecord.identity("\(agent.rawValue):\(session):counter:\(at.timeIntervalSince1970):\(identity)")
                        out[key]?.baseline = true
                        state.needsInheritedBaseline = false
                        onIssue?()
                    }
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

    private static func count(_ raw: Any?, maximum: Int = 1_000_000_000) -> Int? {
        guard let raw else { return 0 }
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let value = number.doubleValue
        guard value.isFinite, value >= 0, value <= Double(maximum), value.rounded(.towardZero) == value else {
            return nil
        }
        return Int(value)
    }
}
