import Foundation
import Shared

/// The real `AgentRunner`: spawns the user's own agent CLI (#214).
///
/// Every invocation carries the full isolation kit measured in §3 of the spec
/// and re-verified live on 2026-07-30:
///
/// - codex: `--ephemeral` (no rollout on disk) + `--disable hooks` (no bridge
///   events) + `-s read-only` + `--output-schema` (provider-enforced shape)
/// - claude: `--no-session-persistence` (no transcript) + `ZACKEYES_JOURNAL=1`
///   in the environment, which the bridge reads before stdin and exits 0 —
///   claude has no hook kill-switch of its own.
///
/// The env var is set for both agents. Codex doesn't need it, but belt and
/// suspenders costs one dictionary entry, and a future codex that drops
/// `--disable` fails safe instead of minting phantom cards.
///
/// Drain/kill mechanics follow `TerminalLocator.runWithTimeout` (stdout must
/// be drained off-thread or a chatty child deadlocks the wait; the killer is
/// cancelled on clean exit). Not reused directly because that helper cannot
/// inject environment and widening a Terminal utility for Journal needs would
/// couple the two modules over four lines of pattern.
///
/// Binary discovery goes through `/usr/bin/env`, inheriting the caller's
/// PATH. That is correct for the manual trigger and the test probe; the P3
/// scheduler runs from the app context where PATH is minimal, and will need
/// explicit discovery — deliberately not solved here.
public struct ProcessAgentRunner: AgentRunner {

    public struct SpawnError: Error, CustomStringConvertible {
        public let description: String
    }

    public init() {}

    public func run(agent: AgentKind, prompt: String, timeout: TimeInterval) throws -> String {
        switch agent {
        case .codex: try runCodex(prompt: prompt, timeout: timeout)
        case .claude: try runClaude(prompt: prompt, timeout: timeout)
        }
    }

    // MARK: Claude

    private func runClaude(prompt: String, timeout: TimeInterval) throws -> String {
        try spawn(
            arguments: ["claude", "-p", "--no-session-persistence", prompt],
            timeout: timeout)
    }

    // MARK: Codex

    /// The provider-enforced half of the whitelist: codex is handed the
    /// `SliceNote` schema as a file and told to write its answer to another.
    private func runCodex(prompt: String, timeout: TimeInterval) throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("zackeyes-journal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let schemaURL = dir.appendingPathComponent("slicenote.schema.json")
        let outURL = dir.appendingPathComponent("note.json")
        try Self.sliceNoteSchema.write(to: schemaURL, atomically: true, encoding: .utf8)

        _ = try spawn(
            arguments: [
                "codex", "exec",
                "--ephemeral", "--disable", "hooks",
                "-s", "read-only", "--skip-git-repo-check",
                "--output-schema", schemaURL.path,
                "-o", outURL.path,
                prompt,
            ],
            timeout: timeout)

        guard let out = try? String(contentsOf: outURL, encoding: .utf8) else {
            throw SpawnError(description: "codex produced no output file")
        }
        return out
    }

    static let sliceNoteSchema = """
    {
      "type": "object",
      "additionalProperties": false,
      "required": ["did", "outcome", "lessons"],
      "properties": {
        "did":     { "type": "array", "items": { "type": "string" } },
        "outcome": { "type": "string", "enum": ["shipped", "partial", "blocked", "explored"] },
        "lessons": { "type": "array", "items": { "type": "string" } }
      }
    }
    """

    // MARK: Spawn

    private func spawn(arguments: [String], timeout: TimeInterval) throws -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        task.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        env["ZACKEYES_JOURNAL"] = "1"
        task.environment = env

        let stdout = Pipe()
        task.standardOutput = stdout
        task.standardError = FileHandle.nullDevice
        task.standardInput = FileHandle.nullDevice

        try task.run()

        final class Flag: @unchecked Sendable {
            private let lock = NSLock()
            private var value = false
            func set() { lock.lock(); value = true; lock.unlock() }
            func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
        }
        let timedOut = Flag()

        let drained = DispatchGroup()
        drained.enter()
        final class Holder: @unchecked Sendable {
            private let lock = NSLock()
            private var data = Data()
            func set(_ d: Data) { lock.lock(); data = d; lock.unlock() }
            func get() -> Data { lock.lock(); defer { lock.unlock() }; return data }
        }
        let holder = Holder()
        DispatchQueue.global(qos: .utility).async {
            holder.set(stdout.fileHandleForReading.readDataToEndOfFile())
            drained.leave()
        }

        let killer = DispatchWorkItem { [task] in
            guard task.isRunning else { return }
            timedOut.set()
            task.terminate()
            Thread.sleep(forTimeInterval: 2)
            if task.isRunning { kill(task.processIdentifier, SIGKILL) }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + timeout, execute: killer)

        task.waitUntilExit()
        killer.cancel()
        _ = drained.wait(timeout: .now() + 2)

        if timedOut.get() {
            throw SpawnError(description: "timed out after \(Int(timeout))s")
        }
        guard task.terminationStatus == 0 else {
            throw SpawnError(description: "exit \(task.terminationStatus)")
        }
        return String(data: holder.get(), encoding: .utf8) ?? ""
    }
}
