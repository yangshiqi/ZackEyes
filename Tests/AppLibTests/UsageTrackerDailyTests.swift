import Testing
import Foundation
@testable import AppLib

@MainActor
struct UsageTrackerDailyTests {
    private static func tmpDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    // A Shanghai (UTC+8) calendar to prove buckets use the LOCAL day boundary.
    private static let shanghai: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return c
    }()
    private static func claudeLine(ts: String, model: String, input: Int, output: Int) -> String {
        """
        {"type":"assistant","timestamp":"\(ts)","message":{"model":"\(model)","usage":{"input_tokens":\(input),"output_tokens":\(output),"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}
        """
    }

    @Test func claudeMidnightSplitsByLocalDay() throws {
        // now = 2026-06-02 12:00 Shanghai. Two messages straddle local midnight:
        //  23:30 on 06-01 Shanghai (== 15:30Z) and 00:30 on 06-02 Shanghai (== 16:30Z 06-01).
        let now = Self.shanghai.date(from: DateComponents(timeZone: TimeZone(identifier: "Asia/Shanghai"),
            year: 2026, month: 6, day: 2, hour: 12))!
        let projects = try Self.tmpDir()
        let proj = projects.appendingPathComponent("p"); try FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)
        let text = [
            Self.claudeLine(ts: "2026-06-01T15:30:00.000Z", model: "claude-opus-4-8", input: 10, output: 1),  // 23:30 06-01 SH
            Self.claudeLine(ts: "2026-06-01T16:30:00.000Z", model: "claude-opus-4-8", input: 20, output: 2)   // 00:30 06-02 SH
        ].joined(separator: "\n")
        try text.write(to: proj.appendingPathComponent("s.jsonl"), atomically: true, encoding: .utf8)

        let res = UsageTracker.computeSnapshot(projectsDir: projects, calendar: Self.shanghai, now: now)
        let jun1 = Self.shanghai.startOfDay(for: Self.shanghai.date(from: DateComponents(timeZone: TimeZone(identifier: "Asia/Shanghai"), year: 2026, month: 6, day: 1, hour: 12))!)
        let jun2 = Self.shanghai.startOfDay(for: now)
        #expect(res.daily[jun1]?["claude-opus-4-8"]?.input == 10)   // first msg → 06-01 local
        #expect(res.daily[jun2]?["claude-opus-4-8"]?.input == 20)   // second msg → 06-02 local
    }
}
