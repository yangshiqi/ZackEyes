import Foundation
import Shared

// MARK: - Collector I/O (#214)
//
// The filesystem half: walk both agents' transcript trees, parse each file
// once, and emit `SessionSlice`s for one local day. Directory roots are
// injected so tests drive this against fixtures in a temp dir.
//
// Tokens are folded out of the same read that extracts the text. The plan
// originally called for re-keying UsageTracker's per-file cache by project,
// but that cache aggregates by day × model (the project is already gone) and
// lives on @MainActor. This is a once-nightly batch job reading each file
// exactly once — a cache would add coupling to save work that isn't repeated.

extension JournalCollector {

    /// Parse result before config is applied — `rawProject` has not yet been
    /// through the alias/exclusion table.
    struct ParsedSlice {
        var agent: AgentKind
        var rawProject: String
        var startedAt: Date
        var endedAt: Date
        var turnCount: Int
        var toolCallCount: Int
        var tokens: SliceTokens
        var transcriptText: String
    }

    // MARK: Entry point

    public static func collect(
        day: Date,
        claudeProjectsDir: URL,
        codexSessionsDir: URL,
        config: Config = Config(),
        calendar: Calendar = .current
    ) -> [SessionSlice] {
        var slices: [SessionSlice] = []
        let dayStart = calendar.startOfDay(for: day)
        let fm = FileManager.default

        // Claude: ~/.claude/projects/<encoded-cwd>/<session>.jsonl
        //
        // One level deep on purpose: subagent transcripts live a level further
        // down (…/<encoded-cwd>/subagents/agent-*.jsonl) and are deliberately
        // not slices — their work already appears in the parent transcript as
        // Task tool calls and results, so promoting them would mint phantom
        // sessions the user never opened. Cost: their token spend is not in
        // the slice numbers (it is still in the app's DailyUsage, which scans
        // them since #116).
        if let projectDirs = try? fm.contentsOfDirectory(
            at: claudeProjectsDir, includingPropertiesForKeys: nil) {
            for projectDir in projectDirs {
                guard let files = try? fm.contentsOfDirectory(
                    at: projectDir,
                    includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
                ) else { continue }
                for file in files where file.pathExtension == "jsonl" {
                    guard let parsed = readEligible(file, newerThan: dayStart) else { continue }
                    if let slice = claudeSlice(fromText: parsed, day: day, calendar: calendar,
                                               config: config) {
                        slices.append(slice)
                    }
                }
            }
        }

        // Codex: ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl, UTC-partitioned.
        // Three directories per local day — see `utcDayDirectories`.
        for c in utcDayDirectories(forLocalDay: day, calendar: calendar) {
            guard let y = c.year, let m = c.month, let d = c.day else { continue }
            let dir = codexSessionsDir
                .appendingPathComponent(String(format: "%04d", y))
                .appendingPathComponent(String(format: "%02d", m))
                .appendingPathComponent(String(format: "%02d", d))
            guard let files = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
            ) else { continue }
            for file in files where file.pathExtension == "jsonl" {
                guard let parsed = readEligible(file, newerThan: dayStart) else { continue }
                if let slice = codexSlice(fromText: parsed, day: day, calendar: calendar,
                                          config: config) {
                    slices.append(slice)
                }
            }
        }

        return slices.sorted { $0.startedAt < $1.startedAt }
    }

    /// Read a transcript if it can possibly contain in-day entries.
    ///
    /// An entry can never be newer than its file, so `mtime < dayStart` proves
    /// the file is all yesterday-or-older and skips the read. The reverse is
    /// not true — a file touched today may still hold mostly old entries —
    /// which is why filtering by per-entry timestamp still happens later.
    private static func readEligible(_ file: URL, newerThan dayStart: Date) -> String? {
        guard let vals = try? file.resourceValues(
                forKeys: [.contentModificationDateKey, .fileSizeKey, .isSymbolicLinkKey]),
              let mtime = vals.contentModificationDate,
              mtime >= dayStart,
              let size = vals.fileSize,
              UsageTracker.shouldScanTranscript(
                  isSymbolicLink: vals.isSymbolicLink ?? false, fileSize: size)
        else { return nil }
        return try? String(contentsOf: file, encoding: .utf8)
    }

    // MARK: Claude

    static func claudeSlice(
        fromText text: String, day: Date, calendar: Calendar, config: Config
    ) -> SessionSlice? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoNoFrac = ISO8601DateFormatter()

        var cwd: String?
        var turns: [String] = []
        var userTurns = 0
        var toolCalls = 0
        var first: Date?, last: Date?
        // Usage keyed by message id, last occurrence wins: a re-emitted
        // assistant line carries the message's final totals.
        var usageById: [String: (input: Int, output: Int, cacheRead: Int, cacheCreate: Int)] = [:]

        for line in text.split(separator: "\n") {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8))
                    as? [String: Any] else { continue }
            if obj["isSidechain"] as? Bool == true { continue }
            if cwd == nil, let c = obj["cwd"] as? String { cwd = c }

            guard let tsString = obj["timestamp"] as? String,
                  let ts = iso.date(from: tsString) ?? isoNoFrac.date(from: tsString),
                  isSameLocalDay(ts, as: day, calendar: calendar)
            else { continue }

            guard let message = obj["message"] as? [String: Any],
                  let role = message["role"] as? String else { continue }

            first = first.map { min($0, ts) } ?? ts
            last = last.map { max($0, ts) } ?? ts

            var textParts: [String] = []
            if let s = message["content"] as? String {
                textParts.append(s)
            } else if let blocks = message["content"] as? [[String: Any]] {
                for block in blocks {
                    switch block["type"] as? String {
                    case "text": if let t = block["text"] as? String { textParts.append(t) }
                    case "tool_use": toolCalls += 1
                    default: break
                    }
                }
            }
            let joined = textParts.joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if role == "user" {
                // System-injected turns (command caveats, task notifications,
                // hook output) all open with a tag; a person's prompt doesn't.
                guard !joined.isEmpty, !joined.hasPrefix("<") else { continue }
                userTurns += 1
                turns.append("user: \(joined)")
            } else if role == "assistant" {
                if !joined.isEmpty { turns.append("assistant: \(joined)") }
                if let usage = message["usage"] as? [String: Any] {
                    let id = message["id"] as? String ?? UUID().uuidString
                    usageById[id] = (
                        usage["input_tokens"] as? Int ?? 0,
                        usage["output_tokens"] as? Int ?? 0,
                        usage["cache_read_input_tokens"] as? Int ?? 0,
                        usage["cache_creation_input_tokens"] as? Int ?? 0
                    )
                }
            }
        }

        guard userTurns > 0, let cwd, let first, let last,
              let raw = projectName(fromCwd: cwd),
              let project = resolve(projectName: raw, config: config)
        else { return nil }

        var input = 0, output = 0, cacheRead = 0, cacheCreate = 0
        for u in usageById.values {
            input += u.input; output += u.output
            cacheRead += u.cacheRead; cacheCreate += u.cacheCreate
        }

        return SessionSlice(
            agent: .claude, projectKey: project, startedAt: first, endedAt: last,
            turnCount: userTurns, toolCallCount: toolCalls,
            tokens: SliceTokens(input: input, output: output,
                                cacheRead: cacheRead, cacheCreate: cacheCreate),
            transcriptText: truncateHeadTail(
                turns.joined(separator: "\n"), limit: config.maxTranscriptScalars))
    }

    // MARK: Codex

    static func codexSlice(
        fromText text: String, day: Date, calendar: Calendar, config: Config
    ) -> SessionSlice? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoNoFrac = ISO8601DateFormatter()

        var cwd: String?
        var turns: [String] = []
        var userTurns = 0
        var toolCalls = 0
        var first: Date?, last: Date?

        for line in text.split(separator: "\n") {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8))
                    as? [String: Any] else { continue }
            let payload = obj["payload"] as? [String: Any]

            if obj["type"] as? String == "session_meta", cwd == nil {
                cwd = payload?["cwd"] as? String
                continue
            }
            if obj["type"] as? String == "response_item",
               payload?["type"] as? String == "function_call" {
                toolCalls += 1
                continue
            }
            guard obj["type"] as? String == "event_msg",
                  let kind = payload?["type"] as? String,
                  kind == "user_message" || kind == "agent_message",
                  let msg = (payload?["message"] as? String)?
                      .trimmingCharacters(in: .whitespacesAndNewlines),
                  !msg.isEmpty,
                  let tsString = obj["timestamp"] as? String,
                  let ts = iso.date(from: tsString) ?? isoNoFrac.date(from: tsString),
                  isSameLocalDay(ts, as: day, calendar: calendar)
            else { continue }

            first = first.map { min($0, ts) } ?? ts
            last = last.map { max($0, ts) } ?? ts
            if kind == "user_message" {
                userTurns += 1
                turns.append("user: \(msg)")
            } else {
                turns.append("assistant: \(msg)")
            }
        }

        guard userTurns > 0, let cwd, let first, let last,
              let raw = projectName(fromCwd: cwd),
              let project = resolve(projectName: raw, config: config)
        else { return nil }

        // Token deltas via the same cumulative-diff parser the Today row uses
        // (#116) — pure text-in, so reuse is free. Codex's input_tokens
        // INCLUDES cached input; store the uncached remainder in `input` so
        // `SliceTokens.distinct` means the same thing for both agents.
        let dayStart = calendar.startOfDay(for: day)
        let tallies = UsageTracker.parseCodexDailyTallies(
            text: text, calendar: calendar, cutoff: dayStart)
        var input = 0, output = 0, cacheRead = 0
        if let models = tallies[dayStart] {
            for t in models.values {
                input += max(0, t.input - t.cacheRead)
                output += t.output
                cacheRead += t.cacheRead
            }
        }

        return SessionSlice(
            agent: .codex, projectKey: project, startedAt: first, endedAt: last,
            turnCount: userTurns, toolCallCount: toolCalls,
            tokens: SliceTokens(input: input, output: output,
                                cacheRead: cacheRead, cacheCreate: 0),
            transcriptText: truncateHeadTail(
                turns.joined(separator: "\n"), limit: config.maxTranscriptScalars))
    }
}
