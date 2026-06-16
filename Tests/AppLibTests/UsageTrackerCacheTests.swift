import Testing
import Foundation
@testable import AppLib

/// #116 — recursing the whole projects tree multiplies the bytes the 30s scan
/// reads (subagent + workflow agent transcripts). A per-file parse cache keyed by
/// `(mtime, size)` keeps steady-state cost ≈ the actively-written file. These
/// tests pin the cache hit/miss behavior of `computeSnapshot`.
@MainActor
struct UsageTrackerCacheTests {
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

    /// Cache HIT: when the cached `(mtime, size)` matches the file on disk, the
    /// cached records are reused and the file is NOT re-parsed — proven by the
    /// cache holding a deliberately different token count than the file.
    @Test func reusesCachedRecordsWhenMtimeAndSizeMatch() throws {
        let now = Date(); let ts = Self.iso(now)
        let projects = try Self.tmpDir()
        let proj = projects.appendingPathComponent("p")
        try FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)
        let file = proj.appendingPathComponent("s.jsonl")
        try Self.line(ts: ts, id: "msg_real", input: 100).write(to: file, atomically: true, encoding: .utf8)

        let vals = try file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let key = file.resolvingSymlinksInPath().path
        let cached = UsageTracker.ClaudeFileCache(
            mtime: vals.contentModificationDate!,
            size: UInt64(vals.fileSize!),
            records: [UsageTracker.ClaudeMsgRecord(
                ts: now, id: "msg_cached", model: "claude-opus-4-8",
                input: 555, output: 0, cacheRead: 0, cacheCreate: 0)])

        let r = UsageTracker.computeSnapshot(
            projectsDir: projects, cache: [key: cached], calendar: .current, now: now)
        #expect(r.snapshot.tokens5h == 555)   // cache hit → file not re-parsed
    }

    /// Cache MISS on size mismatch: the file is re-parsed and the returned cache
    /// is refreshed to the real `(mtime, size)` + records.
    @Test func reparsesWhenCachedSizeDiffers() throws {
        let now = Date(); let ts = Self.iso(now)
        let projects = try Self.tmpDir()
        let proj = projects.appendingPathComponent("p")
        try FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)
        let file = proj.appendingPathComponent("s.jsonl")
        try Self.line(ts: ts, id: "msg_real", input: 100).write(to: file, atomically: true, encoding: .utf8)

        let vals = try file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let key = file.resolvingSymlinksInPath().path
        let stale = UsageTracker.ClaudeFileCache(
            mtime: vals.contentModificationDate!,
            size: 999_999,   // wrong size → miss
            records: [UsageTracker.ClaudeMsgRecord(
                ts: now, id: "msg_cached", model: "claude-opus-4-8",
                input: 555, output: 0, cacheRead: 0, cacheCreate: 0)])

        let r = UsageTracker.computeSnapshot(
            projectsDir: projects, cache: [key: stale], calendar: .current, now: now)
        #expect(r.snapshot.tokens5h == 100)                    // re-parsed real file
        #expect(r.cache[key]?.size == UInt64(vals.fileSize!))  // cache refreshed
    }
}
