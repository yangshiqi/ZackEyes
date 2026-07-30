import Testing
import Foundation
@testable import AppLib
import Shared

/// TEMPORARY — drive `JournalManualTrigger.realPipeline` for the whole real
/// day, every group, writing to the same directory the menu item writes to
/// (#214, P1 completion criterion). This is the trigger's exact code path
/// minus the NSMenu click. Env-gated; spawns real agents for many minutes.
struct JournalFullDayProbe {

    @Test("the real pipeline generates today's journal in ~/.zackeyes/journal")
    func fullDay() throws {
        guard ProcessInfo.processInfo.environment["JOURNAL_FULL_DAY"] == "1" else { return }

        let day = Date()
        let out = try JournalManualTrigger.realPipeline(day)

        let dir = NSHomeDirectory() + "/.zackeyes/journal"
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        let name = JournalManualTrigger.fileName(for: day)
        _ = try AtomicFileWriter.write(Data(out.markdown.utf8), to: dir + "/" + name)
        _ = try? AtomicFileWriter.write(
            Data(out.report.utf8), to: dir + "/." + name + ".run.txt")

        #expect(!out.markdown.isEmpty)
    }
}
