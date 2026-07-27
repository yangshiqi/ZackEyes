import Testing
import Foundation

/// CLAUDE.md invariant #2: the bridge never writes stdout/stderr and always
/// exits 0. Claude Code renders any non-zero hook exit — and anything on stderr —
/// as an error in the user's terminal.
///
/// These drive the real built binary because the failures that broke the
/// contract were not in our logic: `readDataToEndOfFile()` raised an ObjC
/// exception Swift cannot catch (exit 134 plus a stack trace on stderr), and an
/// unhandled SIGPIPE killed the process with 141 (#200 / #201).
struct BridgeExitContractTests {

    /// The `bridge` built alongside the running test bundle.
    ///
    /// Deliberately NOT a search of `.build`: after `make app` that tree also
    /// holds per-architecture release objects, and picking one of those on a
    /// machine of the other architecture fails with "Bad CPU type in
    /// executable" — which is what happened on master when two green branches
    /// merged. The products directory next to the .xctest bundle is the only
    /// one guaranteed to match this process.
    private static var bridgeURL: URL? {
        let products = Bundle.allBundles
            .map(\.bundleURL)
            .first { $0.pathExtension == "xctest" }?
            .deletingLastPathComponent()
        if let products {
            let candidate = products.appendingPathComponent("bridge")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        // swift-testing may run without an .xctest bundle; fall back to the
        // debug products directory for this machine's triple.
        var root = URL(fileURLWithPath: #filePath)
        while root.pathComponents.count > 1 {
            root = root.deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: root.appendingPathComponent("Package.swift").path) {
                break
            }
        }
        // Fail closed. Guessing an architecture here would re-create the exact
        // "Bad CPU type in executable" this fix is about — and `expectSilentSuccess`
        // records an issue on nil, so a genuinely unlocatable binary is loud
        // rather than a silent skip.
        guard let arch = ProcessInfo.processInfo.machineHardwareName else { return nil }
        let candidate = root
            .appendingPathComponent(".build/\(arch)-apple-macosx/debug/bridge")
        return FileManager.default.isExecutableFile(atPath: candidate.path) ? candidate : nil
    }

    private struct Run { let code: Int32; let out: Data; let err: Data }

    private func runBridge(stdin: Data?, closeStdin: Bool = false) throws -> Run? {
        guard let url = Self.bridgeURL else { return nil }
        let task = Process()
        task.executableURL = url
        task.arguments = ["--event", "SessionStart", "--agent", "claude"]
        let outPipe = Pipe(), errPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = errPipe
        if closeStdin {
            // `/dev/null` is a perfectly readable fd and does NOT reproduce this:
            // the failure needs descriptor 0 actually closed, which is what a
            // hook runner can hand us. Only the shell can arrange that, so spawn
            // through it. (Verified: with the legacy read API this run aborts
            // with 134; the earlier nullDevice version passed either way and was
            // therefore useless.)
            task.executableURL = URL(fileURLWithPath: "/bin/sh")
            task.arguments = ["-c", "exec '\(url.path)' --event SessionStart --agent claude 0<&-"]
        } else {
            let inPipe = Pipe()
            task.standardInput = inPipe
            try task.run()
            if let stdin { inPipe.fileHandleForWriting.write(stdin) }
            try? inPipe.fileHandleForWriting.close()
            let out = outPipe.fileHandleForReading.readDataToEndOfFile()
            let err = errPipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            return Run(code: task.terminationStatus, out: out, err: err)
        }
        try task.run()
        let out = outPipe.fileHandleForReading.readDataToEndOfFile()
        let err = errPipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return Run(code: task.terminationStatus, out: out, err: err)
    }

    private func expectSilentSuccess(_ run: Run?, _ label: String) {
        // Never skip silently: a test that quietly does nothing is the same
        // failure mode this file exists to prevent.
        guard let run else {
            Issue.record("\(label): could not locate the built `bridge` binary next to the test bundle")
            return
        }
        #expect(run.code == 0, "\(label): exited \(run.code), Claude Code shows that as a hook error")
        #expect(run.err.isEmpty,
                "\(label): wrote \(run.err.count) bytes to stderr — \(String(decoding: run.err.prefix(200), as: UTF8.self))")
        // Half the invariant: only a PermissionRequest may ever emit stdout, and
        // none of these cases is one. Captured-but-unasserted output would let a
        // chatty bridge sail through (caught in review).
        #expect(run.out.isEmpty,
                "\(label): wrote \(run.out.count) bytes to stdout — \(String(decoding: run.out.prefix(200), as: UTF8.self))")
    }

    @Test func emptyStdinExitsSilently() throws {
        expectSilentSuccess(try runBridge(stdin: Data()), "empty stdin")
    }

    @Test func malformedJsonExitsSilently() throws {
        expectSilentSuccess(try runBridge(stdin: Data("not json at all".utf8)), "malformed JSON")
    }

    /// The regression that produced exit 134 and an NSFileHandleOperationException
    /// stack trace on stderr.
    @Test func unreadableStdinExitsSilently() throws {
        expectSilentSuccess(try runBridge(stdin: nil, closeStdin: true), "closed stdin")
    }

    /// Large payloads are the case that used to be truncated at 4 KiB by
    /// `availableData`, and later killed the process with SIGPIPE once it was
    /// actually transmitted.
    @Test func oversizedPayloadExitsSilently() throws {
        let json = #"{"hook_event_name":"SessionStart","session_id":"contract","cwd":"/tmp","tool_response":"\#(String(repeating: "x", count: 300_000))"}"#
        expectSilentSuccess(try runBridge(stdin: Data(json.utf8)), "300 KB payload")
    }
}

private extension ProcessInfo {
    /// `uname -m` — the running process's architecture, so we pick the matching
    /// build products directory.
    var machineHardwareName: String? {
        var info = utsname()
        guard uname(&info) == 0 else { return nil }
        return withUnsafeBytes(of: &info.machine) { raw in
            raw.prefix(while: { $0 != 0 }).map { Character(UnicodeScalar($0)) }
        }.map(String.init).joined()
    }
}
