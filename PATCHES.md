# Patches: ZackEyes

Candidate fixes for triaged findings (`TRIAGE.json`). **All diffs here are inert
— for human review only.** None has been applied to the source, built, or tested:
the `/patch` verification ladder (apply → rebuild → re-attack) and the independent
reviewer pass require subagents, which could not run (monthly Claude spend limit).
ZackEyes is a Swift app, so the execution-verified `vuln-pipeline patch` ladder
(C/C++ + ASAN) does not apply either — confirmation is manual build + test.

| bug | finding | file | status | closes | issue |
|-----|---------|------|--------|--------|-------|
| [T-1](PATCHES/bug_T1/) | Launcher-chain code-exec (folds F-010/011/012/014) | `HookInstaller.swift` | candidate, **unverified** | cross-uid fully; same-uid partial (coupled to T-4) | #131 |
| [T-4](PATCHES/bug_T4/) | Update integrity (folds F-013/018/019/022/025/027) | `Update/{Checker,Downloader}.swift` | candidate, **unverified** | host-control + filename; integrity core needs release change | #121 |
| [T-2](PATCHES/bug_T2/) | Uncapped sibling reads (folds F-001/002/017/020) | `UsageTracker.swift`, `TaskExtractor.swift` | candidate, **unverified** | **fully** (reuses shipped cap helper) | #132 |
| [T-8](PATCHES/bug_T8/) | Token int-overflow crash-loop | `UsageTracker.swift`, `DailyUsage.swift` | candidate, **unverified** | **fully** (parse-time clamp) | #133 |
| [T-3](PATCHES/bug_T3/) | OSC + notification injection (folds F-004/005/008/023) | `TerminalTitleWriter.swift`, `TerminalLocator.swift`, `NotificationManager.swift` | candidate, **unverified** | **fully** (sanitize whole title at boundary) | #124 |
| [T-9](PATCHES/bug_T9/) | kqueue tailer unbounded buffer (folds F-009/026) | `CodexJsonlTailer.swift` | candidate, **unverified** | **fully** (cap buffer + read, reset on truncation) | #133 |

## Drafted

### T-1 — launcher lockdown
`PATCHES/bug_T1/{patch.diff, notes.md, patch_result.json}`

Hardens `~/.zackeyes` perms (`0700` dirs, `0700` launcher, `0600` marker),
prefers the deploy-time-baked path over the mutable marker, and scaffolds a
(disabled) signature gate. **Key caveat:** perms close the *cross-uid* surface
but a *same-uid* attacker owns these files; the real same-uid control is
signature verification before `exec`, which only works once the app is
Developer-ID signed + notarized — i.e. **T-1 is coupled to T-4.** See
`PATCHES/bug_T1/notes.md` for the verify steps and reviewer watch-items.

### T-4 — update integrity (tracks #121)
`PATCHES/bug_T4/{patch.diff, notes.md, patch_result.json}`

Reconstructs the download URL from trusted components (kills the
server-controlled-host primitive) and validates the asset filename. **Key
caveat:** the integrity *core* — verifying the DMG before `NSWorkspace.open` —
is NOT closed in code: it requires **Developer-ID signing + notarization of the
DMG + stop stripping quarantine** (a release-pipeline change, = #121), the same
change that unblocks T-1's signature gate. The in-app gate is scaffolded but
disabled. See `PATCHES/bug_T4/notes.md`.

### Mechanical batch — T-2, T-8, T-3
`PATCHES/bug_T2/`, `PATCHES/bug_T8/`, `PATCHES/bug_T3/` + `PATCHES/mechanical-batch-notes.md`

Three code-only fixes with **no release coupling** — each fully closes its
finding: T-2 routes the uncapped sibling readers through the shipped
`shouldScanTranscript` cap; T-8 clamps untrusted token counts at parse time so
the trapping sums can't overflow; T-3 sanitizes the whole composed title at the
write boundary in both OSC writers and strips control/bidi from notifications
(also closes T-10/F-008). See `mechanical-batch-notes.md`.

### T-9 — kqueue tailer buffer cap (tracks #133)
`PATCHES/bug_T9/{patch.diff, notes.md}`

Caps the carried partial line + bounds a single read + resets on in-place
truncation. Code-only, fully closes the finding. See `PATCHES/bug_T9/notes.md`.

## Not yet drafted (from TRIAGE.json, by priority)

- **T-5 / T-7** socket → per-user 0700 dir + client-side peer auth; spool perms
  — these touch IPC design / cross-uid posture, not mechanical edits.
- **T-6** spool replay event allowlist (read-side filter mirroring the write side).
- **T-11** `lsof --` end-of-options guard (one-line, LOW).
