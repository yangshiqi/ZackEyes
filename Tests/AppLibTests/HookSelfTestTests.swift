import Testing
import Foundation
@testable import AppLib

/// Execution budget for the tests whose launcher is *expected* to finish
/// promptly — deliberately far above the product's 10s default (#216).
///
/// These tests spawn real processes and wait on real pipes, so their runtime
/// tracks machine load rather than the code under test. At load ~15 the 10s
/// product default failed about 1 run in 6; at load ~33, 2 in 3. A red test
/// gate that depends on how busy the laptop is costs more than it catches: it
/// blocked a release check and, worse, once sent me hunting a regression that
/// did not exist.
///
/// A healthy run never waits this long — `waitForExit` returns the moment the
/// process exits — so the only thing that pays 60s is a genuine hang, which is
/// exactly when patience is worth more than speed. Tests that assert the
/// timeout *fires* keep their own short values.
private let generousExecution: Duration = .seconds(60)

/// #205 — the self-test exists because file-existence checks report green on a
/// dead pipeline. These pin what it concludes from each way the launcher can
/// misbehave, using real spawned scripts rather than a mock: the whole point is
/// that it exercises exec.
struct HookSelfTestTests {

    private func makeLauncher(_ body: String, executable: Bool = true) throws -> String {
        let dir = NSTemporaryDirectory() + "/selftest-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = dir + "/bridge"
        try ("#!/bin/sh\n" + body).write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: path)
        return path
    }

    /// Records the order of operations so we can prove the watcher is armed
    /// before the launcher runs — registering afterwards means a healthy
    /// pipeline reports a delivery failure.
    private final class FakeWatcher: ProbeWatcher, @unchecked Sendable {
        let outcome: Bool
        private(set) var begunSessionId: String?
        private(set) var waitedAfterBegin = false
        init(arrives: Bool) { self.outcome = arrives }
        func begin(sessionId: String) async { begunSessionId = sessionId }
        func wait(timeout: Duration) async -> Bool {
            waitedAfterBegin = begunSessionId != nil
            return outcome
        }
    }

    @Test func passesWhenTheLauncherIsSilentAndTheEventArrives() async throws {
        let launcher = try makeLauncher("cat > /dev/null\nexit 0\n")
        let watcher = FakeWatcher(arrives: true)
        let result = await HookSelfTest(launcherPath: launcher, executionTimeout: generousExecution).run(watcher: watcher)

        #expect(result.passed, "unexpected failures: \(result.failures)")
        #expect(watcher.begunSessionId?.hasPrefix(HookSelfTest.probeSessionPrefix) == true)
        #expect(watcher.waitedAfterBegin, "waited for the probe before arming the watcher")
    }

    /// The bridge delivers and then exits, so a watcher armed after the spawn
    /// has already missed it.
    ///
    /// Checking `begunSessionId` after `run` returns would pass even if `begin`
    /// moved after the spawn, so the ordering is proven the only way that
    /// cannot: `begin` drops a marker file, and the launcher fails unless it is
    /// already there (found in review).
    @Test func armsTheWatcherBeforeRunningTheLauncher() async throws {
        let marker = NSTemporaryDirectory() + "/armed-\(UUID().uuidString).flag"
        let launcher = try makeLauncher("cat > /dev/null\n[ -f '\(marker)' ] || exit 9\nexit 0\n")

        final class MarkerWatcher: ProbeWatcher, @unchecked Sendable {
            let path: String
            init(path: String) { self.path = path }
            func begin(sessionId: String) async {
                FileManager.default.createFile(atPath: path, contents: Data())
            }
            func wait(timeout: Duration) async -> Bool { true }
        }
        defer { try? FileManager.default.removeItem(atPath: marker) }

        let result = await HookSelfTest(launcherPath: launcher, executionTimeout: generousExecution)
            .run(watcher: MarkerWatcher(path: marker))

        #expect(result.passed,
                "the launcher ran before the watcher was armed: \(result.failures)")
    }

    /// A launcher that ignores SIGTERM must still be stopped, or the drain never
    /// reaches EOF and the button stays at "Testing..." (found in review).
    @Test func killsALauncherThatIgnoresTermination() async throws {
        let launcher = try makeLauncher("trap '' TERM\ncat > /dev/null\nsleep 5\n")
        let clock = ContinuousClock()
        let started = clock.now

        let result = await HookSelfTest(launcherPath: launcher, executionTimeout: .milliseconds(300))
            .run(watcher: FakeWatcher(arrives: true))

        #expect(clock.now - started < .seconds(20), "a TERM-ignoring launcher hung the test")
        #expect(result.failure(at: .launcher)?.detail.contains("did not finish") == true,
                "got: \(result.failures)")
    }

    /// A launcher stuck on a dead socket is one of the failures this test is
    /// meant to diagnose — it must not hang the window instead.
    @Test func reportsLauncherWhenItNeverReturns() async throws {
        let launcher = try makeLauncher("cat > /dev/null\nsleep 5\n")
        let clock = ContinuousClock()
        let started = clock.now

        let result = await HookSelfTest(launcherPath: launcher, executionTimeout: .milliseconds(400))
            .run(watcher: FakeWatcher(arrives: true))

        #expect(clock.now - started < .seconds(10), "the hung launcher was not killed")
        #expect(result.failure(at: .launcher)?.detail.contains("did not finish") == true,
                "got: \(result.failures)")
    }

    /// A launcher that exits before reading stdin used to break the pipe under
    /// us and kill THIS process with SIGPIPE (found in review).
    @Test func survivesALauncherThatExitsWithoutReadingStdin() async throws {
        let launcher = try makeLauncher("exit 0\n")
        let result = await HookSelfTest(launcherPath: launcher, executionTimeout: generousExecution).run(watcher: FakeWatcher(arrives: true))
        #expect(result.passed, "unexpected failures: \(result.failures)")
    }

    /// A launcher that floods stdout must be REPORTED, not merely time out —
    /// asserting "some failure" would also pass on a deadlocked drain.
    @Test func survivesALauncherThatFloodsStdout() async throws {
        // POSIX loop rather than `seq`, which is not guaranteed to exist.
        let launcher = try makeLauncher(
            "cat > /dev/null\ni=0\nwhile [ $i -lt 4000 ]; do echo 'noise-line-padding'; i=$((i+1)); done\nexit 0\n")
        let clock = ContinuousClock()
        let started = clock.now

        let result = await HookSelfTest(launcherPath: launcher, executionTimeout: generousExecution)
            .run(watcher: FakeWatcher(arrives: true))

        // The first expectation is what discriminates: a deadlocked drain
        // would report "did not finish", not "printed output". The duration
        // bound is a second guard, kept well under the budget so it still
        // means "the timeout did not rescue us" without tracking load (#216).
        #expect(result.failure(at: .launcher)?.detail.contains("printed output") == true,
                "expected the chatter to be reported, got: \(result.failures)")
        #expect(clock.now - started < .seconds(50), "the drain deadlocked and only the timeout saved it")
    }

    /// A launcher that backgrounds something and returns: the process exits
    /// cleanly, but the descendant holds the pipe write ends, so EOF never
    /// arrives (found in review).
    @Test func doesNotHangWhenADescendantHoldsThePipesOpen() async throws {
        let launcher = try makeLauncher("cat > /dev/null\nsleep 5 &\nexit 0\n")
        let clock = ContinuousClock()
        let started = clock.now

        let result = await HookSelfTest(launcherPath: launcher, executionTimeout: .milliseconds(600))
            .run(watcher: FakeWatcher(arrives: true))

        #expect(clock.now - started < .seconds(20), "a background descendant hung the drain")
        #expect(result.failure(at: .launcher)?.detail.contains("did not finish") == true,
                "got: \(result.failures)")
    }

    /// The case file checks cannot see: everything installed, nothing arriving.
    @Test func reportsDeliveryWhenTheLauncherRunsButNothingArrives() async throws {
        let launcher = try makeLauncher("cat > /dev/null\nexit 0\n")
        let result = await HookSelfTest(launcherPath: launcher, executionTimeout: generousExecution,
                                     deliveryTimeout: .milliseconds(50))
            .run(watcher: FakeWatcher(arrives: false))

        #expect(result.failure(at: .delivery) != nil)
        #expect(result.failure(at: .launcher) == nil, "blamed the launcher for a delivery failure")
    }

    @Test func reportsLauncherWhenItExitsNonZero() async throws {
        let launcher = try makeLauncher("cat > /dev/null\nexit 3\n")
        let result = await HookSelfTest(launcherPath: launcher, executionTimeout: generousExecution).run(watcher: FakeWatcher(arrives: true))

        let failure = result.failure(at: .launcher)
        #expect(failure != nil)
        #expect(failure?.detail.contains("3") == true, "the exit code is the useful part: \(failure?.detail ?? "")")
    }

    /// Invariant #2: Claude Code renders anything on stderr as a hook error, so
    /// a launcher that "works" but chatters is still broken.
    @Test func reportsLauncherWhenItWritesToStderr() async throws {
        let launcher = try makeLauncher("cat > /dev/null\necho 'warning: something' >&2\nexit 0\n")
        let result = await HookSelfTest(launcherPath: launcher, executionTimeout: generousExecution).run(watcher: FakeWatcher(arrives: true))

        #expect(result.failure(at: .launcher)?.detail.contains("warning: something") == true)
    }

    @Test func reportsLauncherWhenItIsNotExecutable() async throws {
        let launcher = try makeLauncher("exit 0\n", executable: false)
        let result = await HookSelfTest(launcherPath: launcher, executionTimeout: generousExecution).run(watcher: FakeWatcher(arrives: true))

        #expect(result.failure(at: .launcher)?.detail.contains("not executable") == true)
    }

    @Test func reportsLauncherWhenItIsMissingEntirely() async throws {
        let result = await HookSelfTest(launcherPath: "/nope/bridge").run(watcher: FakeWatcher(arrives: true))
        #expect(result.failure(at: .launcher) != nil)
    }

    /// A launcher that never returns must not hang the Hook Status window.
    @Test func doesNotWaitForDeliveryAfterALauncherFailure() async throws {
        let launcher = try makeLauncher("cat > /dev/null\nexit 1\n")
        let clock = ContinuousClock()
        let started = clock.now

        let result = await HookSelfTest(
            launcherPath: launcher,
            executionTimeout: generousExecution,
            deliveryTimeout: .seconds(30)
        ).run(watcher: FakeWatcher(arrives: false))

        // Generous on purpose: these tests run in parallel with one that sleeps
        // and one that floods a pipe, so wall clock carries scheduling noise.
        // The bound only has to prove we did not sit through the 30s delivery
        // wait — a tighter one made this flaky (1 run in 3), and load spikes
        // then made it flaky again through the execution budget (#216).
        #expect(clock.now - started < .seconds(25), "waited on delivery despite the launcher failing")
        #expect(result.failure(at: .delivery) == nil)
    }

    // MARK: - Probe identification

    @Test func recognisesItsOwnProbe() {
        #expect(HookSelfTest.isProbe(sessionId: HookSelfTest.probeSessionPrefix + "abc"))
        #expect(HookSelfTest.isProbe(sessionId: "a-real-session-uuid") == false)
        #expect(HookSelfTest.isProbe(sessionId: nil) == false)
    }
}
