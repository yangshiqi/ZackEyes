import Testing
import Foundation
@testable import AppLib

/// #77 — per-session git branch + dirty state.
///
/// The parser is a pure function over `git status --porcelain=v2 --branch`
/// output, so every shape git can emit is testable without a repo. A handful
/// of tests drive real `git` against temporary repos to prove the parser is
/// reading the format git actually produces, not the format I remembered.
struct GitStatusReaderTests {

    // MARK: - Branch

    @Test func readsTheBranchName() {
        let out = """
        # branch.oid e6a0e1e540cb337735b38d88b980da37220862fc
        # branch.head feat/76-session-port-badge
        # branch.upstream origin/feat/76-session-port-badge
        # branch.ab +0 -0
        """
        let s = GitStatusReader.parse(out)
        #expect(s?.branch == "feat/76-session-port-badge")
        #expect(s?.isDetached == false)
    }

    /// Detached HEAD reports the literal `(detached)`, which is useless on a
    /// card. Fall back to the short oid — that is what the user recognises.
    @Test func detachedHeadFallsBackToShortSha() {
        let out = """
        # branch.oid ce1c53c907591d886a19fb04492b5a845d2ccdac
        # branch.head (detached)
        """
        let s = GitStatusReader.parse(out)
        #expect(s?.branch == "ce1c53c")
        #expect(s?.isDetached == true)
    }

    /// A repo with no commits yet has an all-zero oid; there is no useful
    /// short sha to show, so the branch name stands on its own.
    @Test func unbornBranchKeepsItsName() {
        let out = """
        # branch.oid (initial)
        # branch.head master
        """
        let s = GitStatusReader.parse(out)
        #expect(s?.branch == "master")
        #expect(s?.isDetached == false)
    }

    // MARK: - Ahead / behind

    @Test func readsAheadAndBehind() {
        let out = """
        # branch.oid abc
        # branch.head main
        # branch.upstream origin/main
        # branch.ab +3 -2
        """
        let s = GitStatusReader.parse(out)
        #expect(s?.ahead == 3)
        #expect(s?.behind == 2)
    }

    /// No upstream means no `branch.ab` line at all — not zeros.
    @Test func missingUpstreamYieldsZeroAheadBehind() {
        let out = """
        # branch.oid abc
        # branch.head local-only
        """
        let s = GitStatusReader.parse(out)
        #expect(s?.ahead == 0)
        #expect(s?.behind == 0)
    }

    // MARK: - Dirty counting

    @Test func cleanTreeIsNotDirty() {
        let out = """
        # branch.oid abc
        # branch.head main
        # branch.ab +0 -0
        """
        let s = GitStatusReader.parse(out)
        #expect(s?.dirtyCount == 0)
        #expect(s?.isDirty == false)
    }

    @Test func countsChangedTrackedFiles() {
        let out = """
        # branch.head main
        1 .M N... 100644 100644 100644 aaa bbb Sources/A.swift
        1 M. N... 100644 100644 100644 aaa bbb Sources/B.swift
        """
        #expect(GitStatusReader.parse(out)?.dirtyCount == 2)
    }

    /// Untracked files are uncommitted work too — a session that wrote ten new
    /// files has ten things to lose. `--porcelain` already respects
    /// .gitignore, so genuinely ignored build output never reaches us.
    @Test func countsUntrackedFiles() {
        let out = """
        # branch.head main
        ? docs/new-plan.md
        ? Sources/New.swift
        """
        #expect(GitStatusReader.parse(out)?.dirtyCount == 2)
    }

    @Test func countsRenamedAndUnmergedEntries() {
        let out = """
        # branch.head main
        2 R. N... 100644 100644 100644 aaa bbb R100 new.swift\told.swift
        u UU N... 100644 100644 100644 100644 aaa bbb ccc conflicted.swift
        """
        #expect(GitStatusReader.parse(out)?.dirtyCount == 2)
    }

    @Test func countsAMixedTree() {
        let out = """
        # branch.oid b802aa2
        # branch.head release-2606.v2.2.x
        # branch.upstream origin/release-2606.v2.2.x
        # branch.ab +0 -0
        1 .M SC.U 160000 160000 160000 aaa bbb packages/kubernetes-dashboard
        ? .claude/settings.json
        ? .superpowers/
        """
        let s = GitStatusReader.parse(out)
        #expect(s?.dirtyCount == 3)
        #expect(s?.isDirty == true)
        #expect(s?.branch == "release-2606.v2.2.x")
    }

    /// Ignored entries only appear with --ignored, which we do not pass; if a
    /// future caller adds it, they must not inflate the dirty count.
    @Test func ignoresIgnoredEntries() {
        let out = """
        # branch.head main
        ! node_modules/
        """
        #expect(GitStatusReader.parse(out)?.dirtyCount == 0)
    }

    // MARK: - Degradation

    @Test func emptyOutputYieldsNil() {
        #expect(GitStatusReader.parse("") == nil)
        #expect(GitStatusReader.parse("   \n  \n") == nil)
    }

    /// A non-git directory makes git write to stderr and produce no stdout.
    /// Without a branch line there is nothing worth showing.
    @Test func outputWithoutABranchLineYieldsNil() {
        #expect(GitStatusReader.parse("? stray.txt") == nil)
    }

    @Test func garbageDoesNotCrash() {
        #expect(GitStatusReader.parse("\u{0}\u{1}not git output at all") == nil)
        // A branch line among garbage is still usable.
        let s = GitStatusReader.parse("garbage\n# branch.head main\nmore garbage")
        #expect(s?.branch == "main")
    }

    // MARK: - Against real git

    private func makeRepo(_ body: (String) throws -> Void) throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("zeg-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        func git(_ args: [String]) {
            _ = TerminalLocator.runWithTimeout(
                "/usr/bin/git",
                args: ["-C", dir, "-c", "user.email=t@t", "-c", "user.name=t"] + args,
                timeoutSeconds: 10)
        }
        git(["init", "-q", "-b", "main", "."])
        git(["commit", "-q", "--allow-empty", "-m", "init"])
        try body(dir)
        return dir
    }

    @Test func realRepoReportsBranchAndCleanTree() throws {
        let dir = try makeRepo { _ in }
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let s = try #require(GitStatusReader.read(cwd: dir))
        #expect(s.branch == "main")
        #expect(s.isDirty == false)
    }

    @Test func realRepoReportsUntrackedWork() throws {
        let dir = try makeRepo { dir in
            try "hello".write(toFile: dir + "/new.txt", atomically: true, encoding: .utf8)
        }
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let s = try #require(GitStatusReader.read(cwd: dir))
        #expect(s.dirtyCount == 1)
        #expect(s.isDirty == true)
    }

    /// Silent degradation: a plain directory is not an error to surface.
    @Test func nonGitDirectoryYieldsNil() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("zeg-plain-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        #expect(GitStatusReader.read(cwd: dir) == nil)
    }

    @Test func missingDirectoryYieldsNil() {
        #expect(GitStatusReader.read(cwd: "/nonexistent/\(UUID().uuidString)") == nil)
    }

    // MARK: - Scan targets

    /// Several sessions commonly share one repo. Running `git status` once per
    /// session would multiply a 20-80ms subprocess by the session count for
    /// identical answers.
    @Test func scanCwdsAreDeduplicated() {
        var a = SessionInfo(id: "a", cwd: "/repo/one")
        var b = SessionInfo(id: "b", cwd: "/repo/one")
        let c = SessionInfo(id: "c", cwd: "/repo/two")
        a.state = .working
        b.state = .working
        #expect(Set(GitStatusReader.scanCwds([a, b, c])) == ["/repo/one", "/repo/two"])
    }

    @Test func scanCwdsSkipsSessionsWithoutACwd() {
        let a = SessionInfo(id: "a", cwd: nil)
        #expect(GitStatusReader.scanCwds([a]).isEmpty)
        let b = SessionInfo(id: "b", cwd: "")
        #expect(GitStatusReader.scanCwds([b]).isEmpty)
    }

    // MARK: - Badge text

    @Test func badgeHidesWhenClean() {
        #expect(GitBadge.dirtyLabel(for: 0) == nil)
    }

    @Test func badgeShowsDirtyCount() {
        #expect(GitBadge.dirtyLabel(for: 3) == "●3")
    }

    /// Cards are narrow — a repo mid-rebase with 400 changes must not stretch
    /// the row.
    @Test func badgeCapsLargeDirtyCounts() {
        #expect(GitBadge.dirtyLabel(for: 99) == "●99")
        #expect(GitBadge.dirtyLabel(for: 100) == "●99+")
        #expect(GitBadge.dirtyLabel(for: 4000) == "●99+")
    }
}

