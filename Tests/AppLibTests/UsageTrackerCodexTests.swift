import Testing
import Foundation
@testable import AppLib
import Shared

/// Coverage for the Codex rate_limits ingestion path. Codex doesn't fire
/// hooks, so the tracker reads its own rollout jsonl files. The fixture
/// shape matches a real codex-tui 0.128.0 rollout.
@MainActor
struct UsageTrackerCodexTests {

    private func makeTmpDir() throws -> URL {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        return tmpDir
    }

    private func currentCodexDayDir(under root: URL) -> URL {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let comps = calendar.dateComponents([.year, .month, .day], from: Date())
        return root
            .appendingPathComponent(String(format: "%04d", comps.year!))
            .appendingPathComponent(String(format: "%02d", comps.month!))
            .appendingPathComponent(String(format: "%02d", comps.day!))
    }

    private func currentCodexRolloutName(id: String, hour: Int = 0) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let comps = calendar.dateComponents([.year, .month, .day], from: Date())
        return String(format: "rollout-%04d-%02d-%02dT%02d-00-00-\(id).jsonl",
                      comps.year!, comps.month!, comps.day!, hour)
    }

    // MARK: - Decoder

    @Test func decodeCodexObservation_canonicalShape() {
        let rl: [String: Any] = [
            "primary": [
                "used_percent": 12.0,
                "window_minutes": 300,
                "resets_at": 1_777_726_371,
            ],
            "secondary": [
                "used_percent": 47,
                "window_minutes": 10080,
                "resets_at": 1_777_959_054,
            ],
        ]
        let obs = UsageTracker.decodeCodexObservation(from: rl)
        #expect(obs.fiveHourUsedPct == 12.0)
        #expect(obs.fiveHourResetsAt?.timeIntervalSince1970 == 1_777_726_371)
        #expect(obs.sevenDayUsedPct == 47.0)
        #expect(obs.sevenDayResetsAt?.timeIntervalSince1970 == 1_777_959_054)
    }

    @Test func decodeCodexObservation_intMillisFallback() {
        // Some codex builds may emit ms — the decoder should normalize.
        let rl: [String: Any] = [
            "primary": [
                "used_percent": 5,
                "resets_at": 1_777_726_371_000 as Int,
            ],
        ]
        let obs = UsageTracker.decodeCodexObservation(from: rl)
        #expect(obs.fiveHourUsedPct == 5.0)
        #expect(obs.fiveHourResetsAt?.timeIntervalSince1970 == 1_777_726_371)
    }

    @Test func decodeCodexObservation_emptyDictGivesEmptyObservation() {
        let obs = UsageTracker.decodeCodexObservation(from: [:])
        #expect(obs.fiveHourUsedPct == nil)
        #expect(obs.sevenDayUsedPct == nil)
    }

    // MARK: - updateFromCodexRateLimits writes to snapshot

    @Test func updateFromCodexRateLimits_populatesSnapshot() {
        let tracker = UsageTracker(
            projectsDir: URL(fileURLWithPath: "/tmp/nonexistent-claude"),
            codexSessionsDir: nil
        )
        let rl: [String: Any] = [
            "primary":   ["used_percent": 25.0, "resets_at": 1_777_700_000],
            "secondary": ["used_percent": 60.0, "resets_at": 1_777_800_000],
        ]
        tracker.updateFromCodexRateLimits(rl)

        let snap = tracker.snapshot
        #expect(snap.codexFiveHourUsedPct == 25.0)
        #expect(snap.codexSevenDayUsedPct == 60.0)
        #expect(snap.hasCodexData)
        // Claude side stays empty.
        #expect(snap.fiveHourUsedPct == nil)
        #expect(!snap.hasClaudeData)
        #expect(snap.hasRealData)
    }

    @Test func bothAgentsCanCoexistInSnapshot() {
        let tracker = UsageTracker(
            projectsDir: URL(fileURLWithPath: "/tmp/nonexistent-claude"),
            codexSessionsDir: nil
        )
        // Claude path
        let claudeRL: [String: AnyCodable] = [
            "five_hour": AnyCodable(["used_percentage": 33.0, "resets_at": 1_777_700_000]),
            "seven_day": AnyCodable(["used_percentage": 55.0, "resets_at": 1_777_800_000]),
        ]
        tracker.updateFromHook(rateLimits: claudeRL)
        // Codex path
        tracker.updateFromCodexRateLimits([
            "primary":   ["used_percent": 11.0, "resets_at": 1_777_701_000],
            "secondary": ["used_percent": 22.0, "resets_at": 1_777_801_000],
        ])
        let snap = tracker.snapshot
        #expect(snap.fiveHourUsedPct == 33.0)
        #expect(snap.sevenDayUsedPct == 55.0)
        #expect(snap.codexFiveHourUsedPct == 11.0)
        #expect(snap.codexSevenDayUsedPct == 22.0)
        #expect(snap.hasClaudeData && snap.hasCodexData)
    }

    // MARK: - scanLatestCodexRateLimits picks newest file's last token_count

    @Test func scanLatestCodexRateLimits_returnsMostRecentObservation() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let day = currentCodexDayDir(under: tmpDir)
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)

        let now = Date()

        // Older file with stale (low) numbers.
        let oldId = "019dec85-b760-71f2-bca7-b1c463f0d36e"
        let oldFile = day.appendingPathComponent(currentCodexRolloutName(id: oldId, hour: 10))
        try """
            {"type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":1.0,"resets_at":1000000000},"secondary":{"used_percent":1.0,"resets_at":2000000000}}}}
            """.write(to: oldFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-7200)],   // -2h
            ofItemAtPath: oldFile.path
        )

        // Newer file — its LAST token_count event is what we expect to win.
        let newId = "019dec85-1111-2222-3333-444455556666"
        let newFile = day.appendingPathComponent(currentCodexRolloutName(id: newId, hour: 14))
        try """
            {"type":"event_msg","payload":{"type":"task_started"}}
            {"type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":40.0,"resets_at":1777700000},"secondary":{"used_percent":50.0,"resets_at":1777800000}}}}
            {"type":"event_msg","payload":{"type":"agent_message"}}
            {"type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":42.5,"resets_at":1777700005},"secondary":{"used_percent":51.0,"resets_at":1777800005}}}}
            """.write(to: newFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: now],                             // explicit "now"
            ofItemAtPath: newFile.path
        )

        let obs = UsageTracker.scanLatestCodexRateLimits(rootDir: tmpDir)
        #expect(obs?.fiveHourUsedPct == 42.5)
        #expect(obs?.sevenDayUsedPct == 51.0)
    }

    @Test func scanLatestCodexRateLimits_returnsNilWhenNoTokenCount() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let day = currentCodexDayDir(under: tmpDir)
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let id = "019dec85-b760-71f2-bca7-b1c463f0d36e"
        let file = day.appendingPathComponent(currentCodexRolloutName(id: id, hour: 14))
        try """
            {"type":"session_meta","payload":{"id":"\(id)","cwd":"/proj"}}
            {"type":"event_msg","payload":{"type":"user_message","message":"hi"}}
            """.write(to: file, atomically: true, encoding: .utf8)
        let obs = UsageTracker.scanLatestCodexRateLimits(rootDir: tmpDir)
        #expect(obs == nil)
    }

    @Test func scanLatestCodexRateLimits_skipsRolloutsOlderThanActiveWindow() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let day = currentCodexDayDir(under: tmpDir)
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let id = "019dec85-b760-71f2-bca7-b1c463f0d36e"
        let file = day.appendingPathComponent(currentCodexRolloutName(id: id, hour: 14))
        try """
            {"type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":99.0,"resets_at":1}}}}
            """.write(to: file, atomically: true, encoding: .utf8)
        // 30 min old — outside the 15-min active window. Codex isn't running
        // right now, so we want the bar gone.
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-30 * 60)],
            ofItemAtPath: file.path
        )
        let obs = UsageTracker.scanLatestCodexRateLimits(rootDir: tmpDir)
        #expect(obs == nil)
    }

    @Test @MainActor func refresh_clearsCodexData_whenNoRecentRollout() async throws {
        // tmp codex dir has no recent rollout files.
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let tracker = UsageTracker(
            projectsDir: URL(fileURLWithPath: "/tmp/nonexistent-claude"),
            codexSessionsDir: tmpDir
        )
        // Seed codex fields as if a previous run captured them. After
        // refresh, since no rollout in tmpDir is within the active window,
        // they must be cleared so the bar disappears.
        tracker.updateFromCodexRateLimits([
            "primary":   ["used_percent": 25.0, "resets_at": 1_777_700_000],
            "secondary": ["used_percent": 42.0, "resets_at": 1_777_800_000],
        ])
        #expect(tracker.snapshot.hasCodexData)

        await tracker.refresh()

        #expect(tracker.snapshot.codexFiveHourUsedPct == nil)
        #expect(tracker.snapshot.codexSevenDayUsedPct == nil)
        #expect(!tracker.snapshot.hasCodexData)
    }

    @Test func scanLatestCodexRateLimits_includesFreshRollout() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let day = currentCodexDayDir(under: tmpDir)
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let id = "019dec85-aaaa-bbbb-cccc-ddddeeeeffff"
        let file = day.appendingPathComponent(currentCodexRolloutName(id: id, hour: 14))
        try """
            {"type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":12.5,"resets_at":1777700000},"secondary":{"used_percent":3.0,"resets_at":1777800000}}}}
            """.write(to: file, atomically: true, encoding: .utf8)
        // 5 min old — well inside the 15-min active window.
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-5 * 60)],
            ofItemAtPath: file.path
        )
        let obs = UsageTracker.scanLatestCodexRateLimits(rootDir: tmpDir)
        #expect(obs?.fiveHourUsedPct == 12.5)
        #expect(obs?.sevenDayUsedPct == 3.0)
    }
}
