import Foundation

/// Per-session git branch + dirty state (#77).
///
/// ## Why one subprocess rather than two sources
///
/// The branch name is available for free in both agents' transcripts —
/// Claude writes `gitBranch` on every user line, Codex writes
/// `session_meta.payload.git.branch` — and the issue suggested taking it from
/// there. Two things argue against it:
///
/// 1. Codex records the branch once, on line 1. Switch branches mid-session
///    and the card lies for the rest of the session.
/// 2. The dirty count needs `git` regardless, and `--porcelain=v2 --branch`
///    returns branch, upstream divergence and dirty state in that same call.
///
/// So the branch rides along on a subprocess we were going to pay for anyway,
/// stays correct across branch switches, and needs one code path instead of
/// two agent-specific ones (which also makes it work for `.detected` sessions
/// that have no live transcript feed).
///
/// ## Cost
///
/// Measured warm on real repos: 0.02s (291 files) to 0.08s (2833 files).
/// That is ~10-30x the entire port scan, so unlike #81 this one genuinely
/// must not run hot: it is deduplicated per cwd (sessions commonly share a
/// repo), runs off-main, and refreshes on the same 60s-sweep + on-expand
/// cadence as the port badge.
public enum GitStatusReader {

    /// What a card needs to know about a session's working tree.
    public struct Snapshot: Sendable, Equatable {
        /// Branch name, or the short oid when HEAD is detached.
        public let branch: String
        /// True when `branch` is a short oid rather than a real branch name.
        public let isDetached: Bool
        /// Changed tracked files plus untracked files.
        public let dirtyCount: Int
        public let ahead: Int
        public let behind: Int

        public var isDirty: Bool { dirtyCount > 0 }
    }

    /// Which working trees to inspect, deduplicated.
    ///
    /// Several sessions commonly sit in one repo; running `git status` once
    /// per session would multiply a 20-80ms subprocess by the session count
    /// to obtain identical answers.
    public static func scanCwds(_ sessions: [SessionInfo]) -> [String] {
        var seen: Set<String> = []
        var out: [String] = []
        for session in sessions {
            guard let cwd = session.cwd, !cwd.isEmpty else { continue }
            guard seen.insert(cwd).inserted else { continue }
            out.append(cwd)
        }
        return out
    }

    /// Run git against `cwd`. Nil for anything that is not a readable repo —
    /// a plain directory, a deleted directory, or a git that timed out. None
    /// of those are worth surfacing to the user, so they render as no badge.
    public static func read(cwd: String) -> Snapshot? {
        // Skip directories that are gone before paying for a subprocess.
        // Sessions outlive their working trees: on a live machine 15 of 18
        // scanned cwds were deleted `.claude/worktrees/*` paths from finished
        // sessions, each costing a ~20ms fork+exec to be told "not a repo".
        // A stat is roughly free by comparison.
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { return nil }

        // `-C` rather than setting the child's working directory: the shared
        // runner does not expose one, and this avoids a chdir race entirely.
        //
        // `status.showUntrackedFiles` is pinned rather than inherited: a user
        // who set it to `no` would otherwise get a dirty count that silently
        // ignores every new file, and the badge would disagree with their own
        // `git status` for reasons neither of us could see. `normal` (not
        // `all`) is deliberate — `all` makes git walk the entire untracked
        // tree, which is exactly the cost this reader is designed to avoid.
        let output = TerminalLocator.runWithTimeout(
            "/usr/bin/git",
            args: ["-C", cwd,
                   "-c", "status.showUntrackedFiles=normal",
                   "status", "--porcelain=v2", "--branch"],
            timeoutSeconds: 5
        )
        guard let output else { return nil }
        return parse(output)
    }

    /// Parse `git status --porcelain=v2 --branch`.
    ///
    /// Pure function — every shape git emits is testable without a repo.
    /// Format (git docs, "Porcelain Format Version 2"):
    ///   `# branch.oid <sha>|(initial)`
    ///   `# branch.head <name>|(detached)`
    ///   `# branch.ab +<ahead> -<behind>`   (absent when there is no upstream)
    ///   `1 <XY> ...` ordinary change   `2 <XY> ...` rename/copy
    ///   `u <XY> ...` unmerged          `? <path>` untracked
    ///   `! <path>` ignored (only with --ignored, which we never pass)
    public static func parse(_ output: String) -> Snapshot? {
        var head: String?
        var oid: String?
        var ahead = 0
        var behind = 0
        var dirty = 0

        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine)
            if line.hasPrefix("# branch.head ") {
                head = String(line.dropFirst("# branch.head ".count))
                    .trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("# branch.oid ") {
                oid = String(line.dropFirst("# branch.oid ".count))
                    .trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("# branch.ab ") {
                let parts = line.dropFirst("# branch.ab ".count).split(separator: " ")
                for part in parts {
                    if part.hasPrefix("+") { ahead = Int(part.dropFirst()) ?? 0 }
                    if part.hasPrefix("-") { behind = Int(part.dropFirst()) ?? 0 }
                }
            } else if line.hasPrefix("1 ") || line.hasPrefix("2 ")
                        || line.hasPrefix("u ") || line.hasPrefix("? ") {
                // Untracked (`?`) entries count too — new files are
                // uncommitted work, and `--porcelain` already honours
                // .gitignore so real build output never reaches this line.
                //
                // "Entries", not "files": in `normal` mode git collapses an
                // untracked directory into a single `? dir/` row, so ten new
                // files under one new directory count as 1. That is a
                // deliberate trade — counting them individually needs
                // `-uall`, which walks the whole untracked tree and costs far
                // more than the badge is worth. The badge answers "is there
                // uncommitted work here, roughly how much", not "exactly how
                // many files".
                dirty += 1
            }
            // `! ` (ignored) deliberately falls through uncounted.
        }

        guard let head, !head.isEmpty else { return nil }

        // `(detached)` is useless on a card; show the short oid instead —
        // that is the form the user recognises. An unborn branch reports
        // `(initial)` as its oid and has no sha to fall back to, so it keeps
        // its real branch name.
        if head == "(detached)" {
            guard let oid, oid.count >= 7, oid != "(initial)" else { return nil }
            return Snapshot(branch: String(oid.prefix(7)), isDetached: true,
                            dirtyCount: dirty, ahead: ahead, behind: behind)
        }

        return Snapshot(branch: head, isDetached: false,
                        dirtyCount: dirty, ahead: ahead, behind: behind)
    }
}
