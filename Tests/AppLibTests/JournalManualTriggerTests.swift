import Testing
import Foundation
@testable import AppLib

/// #214 P1 step 7 — the manual trigger's state machine, with the pipeline
/// faked so nothing spawns.
@MainActor
struct JournalManualTriggerTests {

    private func tempDir() -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("journal-trigger-\(UUID().uuidString)").path
        return dir
    }

    @Test("a successful run writes the journal and its sidecar, then reveals")
    func successWritesAndReveals() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        var revealed: URL?
        let trigger = JournalManualTrigger(
            journalDir: dir,
            pipeline: { _ in .init(markdown: "# day\n", report: "slices=0") },
            reveal: { revealed = $0 })

        trigger.generateToday()
        #expect(trigger.state == .running)

        // The detached task hops back to the main actor to finish.
        for _ in 0..<200 where trigger.state == .running {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(trigger.state == .idle)

        let name = JournalManualTrigger.fileName(for: Date())
        let written = try String(contentsOfFile: dir + "/" + name, encoding: .utf8)
        #expect(written == "# day\n")
        let sidecar = try String(contentsOfFile: dir + "/." + name + ".run.txt",
                                 encoding: .utf8)
        #expect(sidecar == "slices=0")
        #expect(revealed?.lastPathComponent == name)
    }

    @Test("a failing pipeline lands in .failed, persists the reason, reveals nothing")
    func failureRecorded() async throws {
        struct Boom: Error {}
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        var revealed: URL?
        let trigger = JournalManualTrigger(
            journalDir: dir,
            pipeline: { _ in throw Boom() },
            reveal: { revealed = $0 })

        trigger.generateToday()
        for _ in 0..<200 where trigger.state == .running {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard case .failed = trigger.state else {
            Issue.record("expected .failed, got \(trigger.state)")
            return
        }
        #expect(revealed == nil)
        // The reason must survive the app: `.failed` is memory, and "why is
        // there no journal today" has to be answerable tomorrow too.
        let name = JournalManualTrigger.fileName(for: Date())
        let sidecar = try String(contentsOfFile: dir + "/." + name + ".run.txt",
                                 encoding: .utf8)
        #expect(sidecar.hasPrefix("FAILED: "))
        #expect(sidecar.contains("Boom"))
        // Failed is retryable: the menu label says so and the guard lets a
        // new run start.
        #expect(JournalManualTrigger.menuLabel(for: trigger.state).enabled)
    }

    @Test("a second click while running is ignored")
    func reentrancyGuarded() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let counter = Counter()
        let trigger = JournalManualTrigger(
            journalDir: dir,
            pipeline: { _ in
                counter.increment()
                Thread.sleep(forTimeInterval: 0.15)
                return .init(markdown: "x", report: "")
            },
            reveal: { _ in })

        trigger.generateToday()
        trigger.generateToday()   // double-click
        trigger.generateToday()

        for _ in 0..<300 where trigger.state == .running {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(counter.value() == 1)
    }

    @Test("menu labels track state")
    func menuLabels() {
        #expect(JournalManualTrigger.menuLabel(for: .idle)
                == ("Generate Today's Journal", true))
        #expect(JournalManualTrigger.menuLabel(for: .running).enabled == false)
        #expect(JournalManualTrigger.menuLabel(for: .failed("x")).enabled)
    }

    @Test("file name is the local calendar day")
    func fileNameLocalDay() {
        var beijing = Calendar(identifier: .gregorian)
        beijing.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        // 2026-07-25 23:30 Beijing is still the 25th locally, already the
        // 26th nowhere that matters.
        let lateEvening = Date(timeIntervalSince1970: 1_784_993_400)
        #expect(JournalManualTrigger.fileName(for: lateEvening, calendar: beijing)
                == "2026-07-25.md")
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func increment() { lock.lock(); n += 1; lock.unlock() }
        func value() -> Int { lock.lock(); defer { lock.unlock() }; return n }
    }
}
