import Foundation
import Shared

/// Drives one synthetic event through the real installation and reports where
/// it stopped.
///
/// `HookHealth.check()` reads files: does the launcher exist, is the socket node
/// a socket, do the settings name our command. Every one of those can be true
/// while the pipeline is dead — a socket left behind by a crash, an accept loop
/// that wedged, a launcher whose signature no longer validates, a quarantine
/// flag, a bundle that moved. The report says green and the user still gets no
/// notifications (#205).
///
/// So: run the deployed launcher exactly as Claude Code would, and see whether
/// the app receives what it sent.
public struct HookSelfTest: Sendable {

    public enum Step: String, Sendable, Equatable {
        /// The launcher ran and honoured the bridge contract (exit 0, silent).
        case launcher
        /// The event reached this app: socket, framing, decode and routing.
        case delivery
    }

    public struct Failure: Sendable, Equatable {
        public let step: Step
        /// Written for the user, not for a log: it appears in the Hook Status
        /// window verbatim.
        public let detail: String
    }

    public struct Result: Sendable, Equatable {
        public let failures: [Failure]
        public var passed: Bool { failures.isEmpty }
        public func failure(at step: Step) -> Failure? {
            failures.first { $0.step == step }
        }
    }

    /// Marks the probe so the app can absorb it instead of showing a session
    /// card for a run that is not real. Anything that reaches the event handler
    /// with this prefix is ours.
    public static let probeSessionPrefix = "zackeyes-selftest-"

    public static func isProbe(sessionId: String?) -> Bool {
        sessionId?.hasPrefix(probeSessionPrefix) ?? false
    }

    let launcherPath: String
    /// How long the launcher itself may take. It normally returns in
    /// milliseconds; this only exists so a wedged one is reported rather than
    /// left spinning behind a "Testing..." button.
    let executionTimeout: Duration
    /// How long to wait for the event to come back afterwards. Separate from the
    /// above on purpose — they answer different questions, and sharing one value
    /// meant a short delivery wait also killed a healthy launcher.
    let deliveryTimeout: Duration

    public init(
        launcherPath: String,
        executionTimeout: Duration = .seconds(10),
        deliveryTimeout: Duration = .seconds(5)
    ) {
        self.launcherPath = launcherPath
        self.executionTimeout = executionTimeout
        self.deliveryTimeout = deliveryTimeout
    }

    /// - Parameter watcher: armed BEFORE the launcher runs. The bridge delivers
    ///   the event and then exits, so anything that starts listening after the
    ///   spawn returns has already missed it — a healthy pipeline would be
    ///   reported as a delivery failure (found in review).
    public func run(watcher: some ProbeWatcher) async -> Result {
        let sessionId = Self.probeSessionPrefix + UUID().uuidString
        var failures: [Failure] = []

        await watcher.begin(sessionId: sessionId)

        switch await spawnLauncher(sessionId: sessionId) {
        case .failure(let detail):
            failures.append(Failure(step: .launcher, detail: detail))
            // No point waiting for something that was never sent.
            return Result(failures: failures)
        case .success:
            break
        }

        if await watcher.wait(timeout: deliveryTimeout) == false {
            failures.append(Failure(
                step: .delivery,
                detail: "The hook ran but ZackEyes never received the event. "
                      + "The socket may be stale — quitting and reopening ZackEyes usually clears it."))
        }
        return Result(failures: failures)
    }

    private enum SpawnOutcome { case success, failure(String) }

    private func spawnLauncher(sessionId: String) async -> SpawnOutcome {
        guard FileManager.default.isExecutableFile(atPath: launcherPath) else {
            return .failure("The hook launcher is missing or not executable at \(launcherPath). Reinstall the hooks.")
        }

        let payload = """
        {"hook_event_name":"SessionStart","session_id":"\(sessionId)","cwd":"\(NSTemporaryDirectory())"}
        """
        // stdin comes from a file, not a pipe. A launcher that dies immediately
        // would break a pipe under us, and SIGPIPE in THIS process kills
        // ZackEyes — a self-test must not be able to take down the app it is
        // testing (found in review).
        let stdinPath = NSTemporaryDirectory() + "/zackeyes-selftest-\(UUID().uuidString).json"
        guard (try? Data(payload.utf8).write(to: URL(fileURLWithPath: stdinPath))) != nil,
              let stdin = FileHandle(forReadingAtPath: stdinPath) else {
            return .failure("Could not stage the test payload in the temporary directory.")
        }
        defer { try? FileManager.default.removeItem(atPath: stdinPath) }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: launcherPath)
        task.arguments = ["--event", "SessionStart", "--agent", "claude"]
        task.standardInput = stdin
        let output = Pipe(), errors = Pipe()
        task.standardOutput = output
        task.standardError = errors

        do {
            try task.run()
        } catch {
            return .failure("The hook launcher would not start: \(error.localizedDescription). "
                          + "It may be quarantined or its signature may be invalid — reinstall the hooks.")
        }

        // Drain both pipes at once — reading one to EOF first deadlocks if the
        // child fills the other — and keep only what the message can show. A
        // launcher stuck in `yes` would otherwise hand us hundreds of megabytes.
        // The deadline has to cover the DRAIN, not just the child's exit: a
        // launcher that backgrounds something and returns leaves the descendant
        // holding the write ends, so EOF never comes and the button would sit at
        // "Testing..." forever (found in review).
        let deadline = ContinuousClock.now + executionTimeout
        async let stdoutData = drain(output, until: deadline)
        async let stderrData = drain(errors, until: deadline)

        let finished = await waitForExit(task, within: executionTimeout)
        let (out, err) = await (stdoutData, stderrData)
        let drainedInTime = ContinuousClock.now < deadline

        guard finished, drainedInTime else {
            // A launcher that never returns is exactly one of the failures this
            // test exists to catch, so it must not hang the window instead.
            return .failure("The hook did not finish within \(executionTimeout). "
                          + "It may be stuck waiting on a socket that no longer has a listener.")
        }

        // The bridge contract (invariant #2): exit 0, and nothing on either
        // stream for a non-permission event. A violation is exactly what Claude
        // Code would show the user as a hook error.
        if task.terminationStatus != 0 {
            let noise = String(decoding: err.prefix(300), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure("The hook exited with code \(task.terminationStatus)"
                          + (noise.isEmpty ? "." : ": \(noise)"))
        }
        if !err.isEmpty || !out.isEmpty {
            let noise = String(decoding: (err + out).prefix(300), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure("The hook printed output, which Claude Code shows as an error: \(noise)")
        }
        return .success
    }

    /// Read until EOF or the deadline, retaining only the head.
    ///
    /// Raw poll/read rather than `FileHandle.readDataToEndOfFile`: that blocks
    /// with no way out, and EOF is not ours to wait for — an inherited write end
    /// in a descendant can hold it open long after the launcher itself is gone.
    /// The tail is still read and dropped so the writer never blocks on a full
    /// pipe, while our memory stays bounded.
    private func drain(
        _ pipe: Pipe, until deadline: ContinuousClock.Instant, keeping limit: Int = 1024
    ) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let fd = pipe.fileHandleForReading.fileDescriptor
                var kept = Data()
                var buffer = [UInt8](repeating: 0, count: 8192)
                while true {
                    let remaining = ContinuousClock.now.duration(to: deadline)
                    guard remaining > .zero else { break }
                    let ms = Int32(min(remaining.components.seconds * 1000 + 250, 5_000))
                    var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                    let ready = poll(&pfd, 1, max(ms, 50))
                    if ready < 0 { if errno == EINTR { continue }; break }
                    if ready == 0 { continue }          // nothing yet; deadline re-checked above
                    let n = read(fd, &buffer, buffer.count)
                    if n <= 0 { break }                 // EOF or error
                    if kept.count < limit {
                        kept.append(contentsOf: buffer[0..<min(n, limit - kept.count)])
                    }
                }
                continuation.resume(returning: kept)
            }
        }
    }

    /// Returns false if the deadline passed. The child is killed either way, so
    /// the drains above can reach EOF and this cannot hang the caller.
    private func waitForExit(_ task: Process, within timeout: Duration) async -> Bool {
        let done = ResumeOnce()
        // Killing the child cannot be told apart from a clean exit, so the
        // deadline is recorded separately — otherwise a hang gets reported as
        // "exited with code 15".
        let timedOut = Flag()

        // `waitUntilExit` on a background thread, NOT `terminationHandler`: the
        // handler is installed after `run()`, and a child that already exited by
        // then may never trigger it while `isRunning` has not caught up either.
        // Both paths miss and the wait burns the entire deadline — which is how
        // a trivial `exit 0` script took 10s and made the suite intermittently
        // red under parallel load.
        DispatchQueue.global(qos: .userInitiated).async {
            task.waitUntilExit()
            done.resume(!timedOut.isSet)
        }

        Task {
            try? await Task.sleep(for: timeout)
            guard task.isRunning else { return }   // the waiter above has it
            timedOut.set()
            // terminate() is only a request. A launcher that traps TERM — or a
            // descendant holding the pipes — would keep the drain alive and
            // leave the button at "Testing..." forever, which is precisely the
            // failure this test exists to report. Escalate, as TerminalLocator
            // already does for its subprocesses.
            task.terminate()
            try? await Task.sleep(for: .milliseconds(500))
            if task.isRunning { kill(task.processIdentifier, SIGKILL) }
            done.resume(false)
        }
        return await done.value()
    }
}

/// Arms before the probe is sent, then waits for it.
public protocol ProbeWatcher: Sendable {
    func begin(sessionId: String) async
    func wait(timeout: Duration) async -> Bool
}

public extension Notification.Name {
    /// Posted by the event handler when a self-test probe arrives.
    static let hookSelfTestProbeReceived = Notification.Name("hookSelfTestProbeReceived")
}

/// Watches for the probe on the real notification the app posts when one
/// arrives. Arming and waiting are separate so the observer is in place before
/// the launcher runs.
public final class NotificationCenterProbeWatcher: ProbeWatcher, @unchecked Sendable {
    private let lock = NSLock()
    private var token: NSObjectProtocol?
    private var seen = false
    private var pending: ResumeOnce?

    public init() {}
    deinit { removeObserver() }

    public func begin(sessionId: String) async {
        let observer = NotificationCenter.default.addObserver(
            forName: .hookSelfTestProbeReceived, object: nil, queue: nil
        ) { [weak self] note in
            guard (note.object as? String) == sessionId else { return }
            self?.markSeen()
        }
        lock.withLock { token = observer }
    }

    public func wait(timeout: Duration) async -> Bool {
        // It may already have landed between begin() and here.
        let box: ResumeOnce? = lock.withLock {
            if seen { return nil }
            let created = ResumeOnce()
            pending = created
            return created
        }
        guard let box else { removeObserver(); return true }

        Task {
            try? await Task.sleep(for: timeout)
            box.resume(false)
        }
        let result = await box.value()
        removeObserver()
        return result
    }

    private func markSeen() {
        let waiter = lock.withLock { () -> ResumeOnce? in
            seen = true
            return pending
        }
        waiter?.resume(true)
    }

    private func removeObserver() {
        let observer = lock.withLock { () -> NSObjectProtocol? in
            defer { token = nil }
            return token
        }
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }
}

/// A one-shot Bool: whoever gets there first decides, the rest are ignored.
/// Resuming a continuation twice traps.
final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    private var settled: Bool?

    func value() async -> Bool {
        await withCheckedContinuation { continuation in
            let alreadySettled: Bool? = lock.withLock {
                if let settled { return settled }
                self.continuation = continuation
                return nil
            }
            if let alreadySettled { continuation.resume(returning: alreadySettled) }
        }
    }

    func resume(_ value: Bool) {
        let waiter = lock.withLock { () -> CheckedContinuation<Bool, Never>? in
            guard settled == nil else { return nil }
            settled = value
            defer { continuation = nil }
            return continuation
        }
        waiter?.resume(returning: value)
    }
}

/// One-way boolean shared between the deadline task and the termination handler.
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}
