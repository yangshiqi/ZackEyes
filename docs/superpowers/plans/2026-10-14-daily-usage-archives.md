# Daily Usage Archives Implementation Plan

> **For agentic workers:** Use executing-plans to implement task-by-task. Keep production implementation inline; use independent review agents only for review. Steps use checkbox syntax.

**Goal:** Replace frequent full-history Usage scans with daily incremental settlement and small archived summaries.

**Architecture:** A resumable parser feeds bounded source chunks into an actor-owned system SQLite database. Counts and hashed cursor state commit together; day queries generate small daily archives. The service schedules yesterday/catch-up once and Settings reads archives without starting imports.

**Tech Stack:** Swift 6, Foundation, SDK SQLite3, Swift Testing, existing SwiftUI/Charts.

**Spec:** `docs/superpowers/specs/2026-10-14-daily-usage-archives-design.md` (user-approved direction).

## Global constraints

- No third-party dependency, no agent config/source writes, no daemon, no release.
- Private owned 0700 directory/0600 database and sidecars; schema mismatch preserves data.
- Counts, bounded names, hashes and timing only; never persist raw paths/IDs/content in checkpoints.
- Complete local days through yesterday; 03:00 daily, startup/wake catch-up, recent three-day correction, delayed updates of existing older days.
- Archive-only Settings reads; explicit older-history import with pause/resume; unchanged sources read zero bytes after restart.
- Observation IDs/revisions and Codex counter baselines must survive chunking, retries and migration unchanged.

### Task 1: Resumable parser

Files: `UsageLedgerParser.swift`, new `UsageIncrementalParserTests.swift`.

Interface: `UsageLedgerParser.State: Codable, Sendable`; `seed(objects:agent:sourceID:)`; `consume(objects:state:onIssue:) -> [UsageLedgerRecord]`; existing `parse(text:...)` wraps this state machine. Pending tools use hashed keys.

- [ ] Add failing equivalence test: parse a task/tool/question prefix, encode/decode State, consume completion/counters suffix; compare records by ID/revision to `parse(prefix+suffix)`.
- [ ] Test serialized state excludes PRIVATE prompt/reply/arguments/path/raw IDs, while cross-chunk waits and cumulative resets retain exact counts.
- [ ] Implement state extraction without changing count/interval semantics; run `swift test --filter 'Usage.*Parser|UsageLedgerTests'` and commit.

### Task 2: SQLite counts, cursor and daily archives

Files: new `UsageArchiveDatabase.swift`; extend `UsageLedgerSummary` Codable/raw cache totals; new `UsageArchiveDatabaseTests.swift`.

Interface: database actor `apply(records:source:checkpoint:)`, `checkpoint(source:)`, `records(for:start:end:)`, `archive(day:calendar:)`, `summary(days:now:calendar:)`, metadata reads/writes. Apply combines counts/cursor in one transaction.

- [ ] Add failing tests for duplicate upserts, revisions, counter predecessor at midnight, rollback preserving cursor, archive-only restore after reopen, privacy/schema/symlink rejection and DST.
- [ ] Implement SDK SQLite prepared statements, private filesystem validation, indexed day/session queries, full per-day ranks/cache totals and small archive combination.
- [ ] Compare archived multi-day results against existing full-record summary for fixed fixtures; run relevant tests and commit.

### Task 3: Bounded importer, scheduler and Settings

Files: new `UsageArchiveImporter.swift`, `UsageArchiveEngine.swift`, replace service scheduling; update Usage view/tests and old collector integration as needed.

Interface: importer `run(mode:now:calendar:onProgress:)` streams rows and commits offset/state per chunk; engine `settleIfDue`, `updateNow`, `importLegacy`, `importHistory`, archive-only `summary`; service `start/stop/refresh/setDays/pause/import...`.

- [ ] Add failing tests: unchanged file after importer restart reads 0 bytes; append reads suffix only; partial-line resume/replacement/truncation, cancellation rollback and incremental-vs-full counts match.
- [ ] Test bounded legacy count import preserves source bytes, resumes and deduplicates; oversized/unsupported rows report errors without replacing files.
- [ ] Test schedule at local 03:00, first startup, same-day no repeat, sleeping/off catch-up, timezone change, recent-day correction and refresh without source reads.
- [ ] Implement background/throttled single-flight jobs, persisted checkpoints and daily metadata; Settings shows through-yesterday/unsettled-today, progress/errors, Update now, optional imports and Pause/Resume.
- [ ] Run all ledger/archive/scheduler tests and commit.

### Task 4: Verification, migration evidence and delivery

- [ ] Update README/ARCHITECTURE and this plan around final implementation; preserve release metadata.
- [ ] Full `swift build`, `swift test`, `make app`, strict codesign/diff checks.
- [ ] Native isolated-home checks for archive-only startup/period switch, daily job/import/pause; actual user data migration only through explicit authorized one-time import, preserve legacy/source/config files. Measure startup RSS/latency and unchanged-source byte reads separately from other app collectors.
- [ ] Independent Spec and Standards review; fix findings, rerun affected checks, create/merge PR and leave a normally launched local app running.
