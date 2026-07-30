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

    /// Distillation is a pure text transform — the model is handed transcript
    /// text and asked for JSON. It therefore gets **no tools at all**:
    /// `--disallowedTools "*"` overrides whatever unattended allowlist the
    /// user's own settings carry. Without it, a prompt-injected transcript
    /// ("run this command…") plus a user who pre-approved Bash would execute
    /// for real — the transcript is untrusted input (spec §6.1), and the env
    /// var bridge only silences *our* hooks, it restricts nothing.
    private func runClaude(prompt: String, timeout: TimeInterval) throws -> String {
        try spawn(
            arguments: ["claude", "-p", "--no-session-persistence",
                        "--disallowedTools", "*"],
            stdin: prompt,
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

        // `-` = read instructions from stdin (documented in `codex exec
        // --help`). The prompt embeds transcript text — untrusted input — and
        // the same help screen lists `--dangerously-bypass-approvals-and-
        // sandbox`, which is exactly what a smuggled argv element could name.
        // Keeping every untrusted byte out of argv closes the class.
        // `-C dir` points codex at the empty scratch directory, so "the
        // workspace" its tools see contains nothing. Known residual, recorded
        // rather than hidden: `-s read-only` blocks writes, not reads — codex
        // has no equivalent of claude's `--disallowedTools "*"`, so an
        // injected transcript can still steer it into reading user-readable
        // files and paraphrasing them into whitelist-shaped prose. The
        // sanitizer mitigates but is not a boundary against deliberate
        // encoding. Closing this needs a codex-side no-tools knob (tracked
        // for P2's opt-in copy); the minimal environment below at least
        // removes every secret that travels by env var.
        _ = try spawn(
            arguments: [
                "codex", "exec",
                "--ephemeral", "--disable", "hooks",
                "-s", "read-only", "--skip-git-repo-check",
                "-C", dir.path,
                "--output-schema", schemaURL.path,
                "-o", outURL.path,
                "-",
            ],
            stdin: prompt,
            timeout: timeout)

        // A SliceNote is a few hundred bytes; a megabyte of "note" is not a
        // note, and materializing an arbitrarily large file into a String is
        // how a hostile child turns disk into our memory.
        let attrs = try? FileManager.default.attributesOfItem(atPath: outURL.path)
        let size = attrs?[.size] as? Int ?? 0
        guard size <= Self.maxOutputBytes else {
            throw SpawnError(description: "codex output file exceeds cap (\(size) bytes)")
        }
        guard let out = try? String(contentsOf: outURL, encoding: .utf8) else {
            throw SpawnError(description: "codex produced no output file")
        }
        return out
    }

    /// Cap on anything a child hands back, stdout or file. Far above any real
    /// SliceNote, far below anything that could hurt the host app.
    static let maxOutputBytes = 2 * 1024 * 1024

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

    /// `stdin` carries the prompt for both agents. Argv holds only literals we
    /// wrote ourselves — no byte of transcript-derived content may appear
    /// there, because an element starting with `-` would parse as a flag.
    private func spawn(arguments: [String], stdin stdinText: String?,
                       timeout: TimeInterval) throws -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        task.arguments = arguments

        // Minimal environment, not an inherited one. The app's environment
        // can carry secrets (API keys, tokens exported in the user's shell),
        // and the child is fed hostile transcript text — inheriting
        // everything hands an injected model the contents of every env var.
        // The whitelist is what the CLIs demonstrably need: PATH to be found,
        // HOME for their auth stores, USER/LOGNAME because claude's OAuth
        // keychain lookup fails "Not logged in" without them (measured — the
        // smoke caught it in 3.7s; they are identity, not secrets), TMPDIR
        // for scratch, LANG for UTF-8, and ANTHROPIC_API_KEY passed through
        // because for some users it is the claude CLI's only auth.
        var env: [String: String] = ["ZACKEYES_JOURNAL": "1"]
        let inherited = ProcessInfo.processInfo.environment
        for key in ["PATH", "HOME", "USER", "LOGNAME", "TMPDIR", "LANG",
                    "ANTHROPIC_API_KEY"] {
            env[key] = inherited[key]
        }
        task.environment = env
        task.currentDirectoryURL = FileManager.default.temporaryDirectory

        let stdout = Pipe()
        task.standardOutput = stdout
        task.standardError = FileHandle.nullDevice

        let stdinPipe: Pipe?
        if stdinText != nil {
            let p = Pipe()
            task.standardInput = p
            stdinPipe = p
        } else {
            task.standardInput = FileHandle.nullDevice
            stdinPipe = nil
        }

        try task.run()

        if let stdinPipe, let stdinText {
            // Write off-thread: a prompt larger than the pipe buffer would
            // otherwise deadlock against a child that hasn't started reading.
            //
            // F_SETNOSIGPIPE first. If the child dies before consuming the
            // prompt, write(2) to the broken pipe raises SIGPIPE, whose
            // default action terminates the PROCESS — the whole app, not the
            // writer thread. With the flag, the write fails with EPIPE, which
            // `try?` swallows, which is the correct amount of caring about a
            // child that is already dead.
            let writeHandle = stdinPipe.fileHandleForWriting
            _ = fcntl(writeHandle.fileDescriptor, F_SETNOSIGPIPE, 1)
            DispatchQueue.global(qos: .utility).async {
                try? writeHandle.write(contentsOf: Data(stdinText.utf8))
                try? writeHandle.close()
            }
        }

        final class Flag: @unchecked Sendable {
            private let lock = NSLock()
            private var value = false
            func set() { lock.lock(); value = true; lock.unlock() }
            func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
        }
        let timedOut = Flag()
        let overCap = Flag()

        let drained = DispatchGroup()
        drained.enter()
        final class Holder: @unchecked Sendable {
            private let lock = NSLock()
            private var data = Data()
            func append(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }
            func count() -> Int { lock.lock(); defer { lock.unlock() }; return data.count }
            func get() -> Data { lock.lock(); defer { lock.unlock() }; return data }
        }
        let holder = Holder()
        let childPid = task.processIdentifier
        DispatchQueue.global(qos: .utility).async { [task] in
            // Chunked, capped drain. `readDataToEndOfFile` buffers without
            // limit, so a child spraying stdout turns its disk quota into our
            // memory; past the cap the child is killed and the run fails.
            let handle = stdout.fileHandleForReading
            while let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
                holder.append(chunk)
                if holder.count() > Self.maxOutputBytes {
                    overCap.set()
                    if task.isRunning { kill(childPid, SIGKILL) }
                    break
                }
            }
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
        // The pipe's write end closes when the child exits, so the drain
        // normally finishes instantly. If it doesn't — a grandchild inherited
        // stdout and is holding the pipe open — the honest answer is failure,
        // not whatever partial bytes happened to arrive: partial output would
        // surface downstream as "unparseable JSON", pointing at the model when
        // the fault is the read.
        if drained.wait(timeout: .now() + 5) == .timedOut {
            // A descendant inherited stdout and holds the pipe open. The
            // reader thread stays parked until that descendant exits — a
            // bounded leak (one thread + one fd per failed run), recorded
            // here as the failure it is. Containing descendants for real
            // needs a process group, which `Process` does not expose; the
            // CLIs themselves are trusted (our threat model distrusts the
            // *transcript*), so per-run process-group plumbing is not worth
            // its complexity yet.
            throw SpawnError(description: "stdout drain incomplete after exit")
        }

        if overCap.get() {
            throw SpawnError(description: "stdout exceeded \(Self.maxOutputBytes) bytes")
        }
        if timedOut.get() {
            throw SpawnError(description: "timed out after \(Int(timeout))s")
        }
        guard task.terminationStatus == 0 else {
            throw SpawnError(description: "exit \(task.terminationStatus)")
        }
        return String(data: holder.get(), encoding: .utf8) ?? ""
    }
}
