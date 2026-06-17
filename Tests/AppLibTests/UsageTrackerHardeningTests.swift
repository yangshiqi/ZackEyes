import Testing
import Foundation
@testable import AppLib

/// Security hardening for the #116 recursive transcript scan (scan findings
/// F-008 unbounded read, F-009 symlink-follow): the scan must not follow a
/// symlink out of the projects tree, and must skip oversized files.
@MainActor
struct UsageTrackerHardeningTests {
    private static func tmpDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private static func line(ts: String, id: String, input: Int) -> String {
        "{\"type\":\"assistant\",\"timestamp\":\"\(ts)\",\"message\":{\"id\":\"\(id)\",\"model\":\"claude-opus-4-8\",\"usage\":{\"input_tokens\":\(input),\"output_tokens\":0,\"cache_read_input_tokens\":0,\"cache_creation_input_tokens\":0}}}"
    }

    private static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: d)
    }

    /// F-009: a `*.jsonl` symlink inside the tree whose target is OUTSIDE the
    /// tree must NOT be read (no following symlinks out of projectsDir).
    @Test func symlinkedTranscriptIsNotFollowed() throws {
        let now = Date(); let ts = Self.iso(now)
        let projects = try Self.tmpDir()
        let proj = projects.appendingPathComponent("p")
        try FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)
        // Real target OUTSIDE the projects tree.
        let outside = try Self.tmpDir()
        let target = outside.appendingPathComponent("secret.jsonl")
        try Self.line(ts: ts, id: "msg_secret", input: 500).write(to: target, atomically: true, encoding: .utf8)
        // Symlink inside the tree pointing at it.
        let link = proj.appendingPathComponent("link.jsonl")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        // Control: a genuine regular file in the same dir MUST be counted, so a
        // total of exactly 100 proves the scan ran AND skipped only the symlink.
        try Self.line(ts: ts, id: "msg_real", input: 100).write(
            to: proj.appendingPathComponent("real.jsonl"), atomically: true, encoding: .utf8)

        let r = UsageTracker.computeSnapshot(projectsDir: projects, calendar: .current, now: now)
        #expect(r.snapshot.tokens5h == 100)   // real file counted; symlink target (500) NOT read
    }

    /// F-008/F-009: the scan gate skips symlinks and files over the size cap,
    /// and admits normal-sized regular files.
    @Test func shouldScanTranscriptGate() {
        #expect(UsageTracker.shouldScanTranscript(isSymbolicLink: false, fileSize: 1_000) == true)
        #expect(UsageTracker.shouldScanTranscript(isSymbolicLink: true, fileSize: 1_000) == false)
        #expect(UsageTracker.shouldScanTranscript(isSymbolicLink: false, fileSize: UsageTracker.maxTranscriptBytes) == true)
        #expect(UsageTracker.shouldScanTranscript(isSymbolicLink: false, fileSize: UsageTracker.maxTranscriptBytes + 1) == false)
    }
}
