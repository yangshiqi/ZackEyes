import Testing
import Foundation
@testable import AppLib

/// #214 — what "a day's work on a project" means.
///
/// Everything downstream treats a slice as fact, so an error here is not a
/// wrong sentence in the journal, it is a wrong *record*: work filed under the
/// wrong day, or a project renamed in something the user keeps permanently.
struct JournalCollectorTests {

    private var beijing: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        return c
    }

    private var honolulu: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: -10 * 3600)!
        return c
    }

    // MARK: - Project identity

    @Test("project name comes from the working directory's last component")
    func projectNameFromCwd() {
        #expect(JournalCollector.projectName(fromCwd: "/Users/a/Work/ZackEyes") == "ZackEyes")
        #expect(JournalCollector.projectName(fromCwd: "/Users/a/Work/ZackEyes/") == "ZackEyes")
        #expect(JournalCollector.projectName(fromCwd: "/") == nil)
        #expect(JournalCollector.projectName(fromCwd: "") == nil)
    }

    @Test("a hyphenated directory name is not ambiguous when read from cwd")
    func hyphenatedNamesAreUnambiguous() {
        // Claude stores transcripts under a directory whose name replaces path
        // separators with hyphens, so `-Users-a-Work-lab-ZackEyes` could be
        // `lab/ZackEyes` or `lab-ZackEyes`. Reading cwd from inside the file
        // avoids the guess — and guessing wrong renames a project in a record
        // the user keeps.
        #expect(JournalCollector.projectName(fromCwd: "/Users/a/Work/lab/ZackEyes") == "ZackEyes")
        #expect(JournalCollector.projectName(fromCwd: "/Users/a/Work/lab-ZackEyes") == "lab-ZackEyes")
    }

    @Test("an agent worktree files under the repository that owns it")
    func worktreeCollapsesToOwner() {
        // From the first live probe: a real day came back as fifteen
        // "projects", most of them worktree checkouts of one repo. Filing by
        // the worktree name shatters a repository's day into micro-projects.
        #expect(JournalCollector.projectName(
            fromCwd: "/Users/a/Work/console-ui-new/.claude/worktrees/issue-1714")
            == "console-ui-new")
        #expect(JournalCollector.projectName(
            fromCwd: "/Users/a/Work/console-ui-new/.claude/worktrees/main-guard/sub")
            == "console-ui-new")
        // A directory merely *named* worktrees, without the .claude parent,
        // is not the pattern and keeps its own name.
        #expect(JournalCollector.projectName(
            fromCwd: "/Users/a/Work/worktrees/thing") == "thing")
    }

    // MARK: - Aliases and exclusions

    @Test("an excluded project resolves to nothing at all")
    func exclusionRemovesEntirely() {
        let config = JournalCollector.Config(excluded: ["AcmeBank"])
        #expect(JournalCollector.resolve(projectName: "AcmeBank", config: config) == nil)
        #expect(JournalCollector.resolve(projectName: "ZackEyes", config: config) == "ZackEyes")
    }

    @Test("an alias replaces the name, and exclusion wins over it")
    func aliasApplied() {
        let config = JournalCollector.Config(
            aliases: ["acme-portal": "Client A", "AcmeBank": "Client B"],
            excluded: ["AcmeBank"])
        #expect(JournalCollector.resolve(projectName: "acme-portal", config: config) == "Client A")
        // Excluding something that also has an alias must exclude it, not
        // publish the alias — the user asked for it to be absent.
        #expect(JournalCollector.resolve(projectName: "AcmeBank", config: config) == nil)
    }

    // MARK: - Truncation

    @Test("truncation keeps the beginning and the end")
    func truncationKeepsBothEnds() {
        // The intent is at the start and the conclusion is at the end; a plain
        // prefix cut throws away the half a journal is made of.
        let text = "START" + String(repeating: "x", count: 500) + "END"
        let out = JournalCollector.truncateHeadTail(text, limit: 100)
        #expect(out.hasPrefix("START"))
        #expect(out.hasSuffix("END"))
        #expect(out.unicodeScalars.count <= 100)
    }

    @Test("text within budget is returned untouched")
    func shortTextUntouched() {
        #expect(JournalCollector.truncateHeadTail("短的", limit: 100) == "短的")
    }

    @Test("truncation counts scalars so CJK is not over-trimmed")
    func truncationCountsScalars() {
        let text = String(repeating: "工", count: 300)
        let out = JournalCollector.truncateHeadTail(text, limit: 50)
        #expect(out.unicodeScalars.count <= 50)
        #expect(out.contains("…"))
    }

    // MARK: - Local day vs UTC directories

    @Test("a local day spans more than one UTC directory, east and west")
    func localDaySpansUTCDirectories() {
        // Codex partitions rollouts into YYYY/MM/DD by UTC. Scanning only the
        // matching UTC directory silently drops part of every local day — eight
        // hours of it in Beijing, ten in Honolulu.
        let day = Date(timeIntervalSince1970: 1_785_000_000)
        for calendar in [beijing, honolulu] {
            let dirs = JournalCollector.utcDayDirectories(forLocalDay: day, calendar: calendar)
            #expect(dirs.count == 3)
            // The days must be distinct and consecutive.
            let days = dirs.compactMap(\.day)
            #expect(Set(days).count == 3)
        }
    }

    @Test("the UTC window brackets the local day on both sides")
    func utcWindowBracketsLocalDay() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let day = Date(timeIntervalSince1970: 1_785_000_000)
        let dirs = JournalCollector.utcDayDirectories(forLocalDay: day, calendar: beijing)

        // Both the first and last instant of the local day must fall inside
        // one of the returned directories.
        let start = beijing.startOfDay(for: day)
        let end = beijing.date(byAdding: .second, value: -1,
                               to: beijing.date(byAdding: .day, value: 1, to: start)!)!
        for instant in [start, end] {
            let c = utc.dateComponents([.year, .month, .day], from: instant)
            #expect(dirs.contains { $0.year == c.year && $0.month == c.month && $0.day == c.day },
                    "UTC window misses \(instant)")
        }
    }

    @Test("entries are filed by their own timestamp, not the file's")
    func entriesFiledByOwnTimestamp() {
        // A session left open across midnight has work on both days; the file's
        // modification time claims all of it for the second one.
        let day = beijing.startOfDay(for: Date(timeIntervalSince1970: 1_785_000_000))
        let justBefore = beijing.date(byAdding: .second, value: -1, to: day)!
        let justAfter = beijing.date(byAdding: .second, value: 1, to: day)!
        #expect(JournalCollector.isSameLocalDay(justAfter, as: day, calendar: beijing))
        #expect(!JournalCollector.isSameLocalDay(justBefore, as: day, calendar: beijing))
    }
}
