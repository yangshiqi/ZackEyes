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

- [x] Add failing equivalence test: parse a task/tool/question prefix, encode/decode State, consume completion/counters suffix; compare records by ID/revision to `parse(prefix+suffix)`.
- [x] Test serialized state excludes PRIVATE prompt/reply/arguments/path/raw IDs, while cross-chunk waits and cumulative resets retain exact counts.
- [x] Implement state extraction without changing count/interval semantics; run `swift test --filter 'Usage.*Parser|UsageLedgerTests'` and commit.

### Task 2: SQLite counts, cursor and daily archives

Files: new `UsageArchiveDatabase.swift`; extend `UsageLedgerSummary` Codable/raw cache totals; new `UsageArchiveDatabaseTests.swift`.

Interface: database actor `apply(records:source:checkpoint:)`, `checkpoint(source:)`, `records(for:start:end:)`, `archive(day:calendar:)`, `summary(days:now:calendar:)`, metadata reads/writes. Apply combines counts/cursor in one transaction.

- [x] Add failing tests for duplicate upserts, revisions, counter predecessor at midnight, rollback preserving cursor, archive-only restore after reopen, privacy/schema/symlink rejection and DST.
- [x] Implement SDK SQLite prepared statements, private filesystem validation, indexed day/session queries, full per-day ranks/cache totals and small archive combination.
- [x] Compare archived multi-day results against existing full-record summary for fixed fixtures; run relevant tests and commit.

### Task 3: Bounded importer, scheduler and Settings

Files: new `UsageArchiveImporter.swift`, `UsageArchiveEngine.swift`, replace service scheduling; update Usage view/tests and old collector integration as needed.

Interface: importer `run(mode:now:calendar:onProgress:)` streams rows and commits offset/state per chunk; engine `settleIfDue`, `updateNow`, `importLegacy`, `importHistory`, archive-only `summary`; service `start/stop/refresh/setDays/pause/import...`.

- [x] Add failing tests: unchanged file after importer restart reads 0 bytes; append reads suffix only; partial-line resume/replacement/truncation, cancellation rollback and incremental-vs-full counts match.
- [x] Test bounded legacy count import preserves source bytes, resumes and deduplicates; oversized/unsupported rows report errors without replacing files.
- [x] Test schedule at local 03:00, first startup, same-day no repeat, sleeping/off catch-up, timezone change, recent-day correction and refresh without source reads.
- [x] Implement background/throttled single-flight jobs, persisted checkpoints and daily metadata; Settings shows through-yesterday/unsettled-today, progress/errors, Update now, optional imports and Pause/Resume.
- [x] Run all ledger/archive/scheduler tests and commit.

### Task 4: Verification, migration evidence and delivery

- [x] Update README/ARCHITECTURE and this plan around final implementation; preserve release metadata.
- [x] Full `swift build`, `swift test`, `make app`, strict codesign/diff checks.
- [x] Native isolated-home checks for archive-only startup/period switch, daily job/import/pause; actual user data migration only through explicit authorized one-time import, preserve legacy/source/config files. Measure startup RSS/latency and unchanged-source byte reads separately from other app collectors.
- [x] Independent Spec and Standards review; fix findings, rerun affected checks, prepare the tested PR and leave a normally launched local app running. Merge tracking is recorded in GitHub and local memory.

## Verified delivery evidence (2026-10-14)

- PR: https://github.com/yangshiqi/ZackEyes/pull/273. Production source verified at `79186c9`; subsequent changes add regression coverage and documentation only.
- `swift build`, full `swift test`: 919 Swift Testing tests (two opt-in real-SSH integrations skipped), plus 138 XCTest tests, no failures. The focused parser/archive/importer/scheduler/service coverage comprises 40 tests. `make app`, strict deep code-sign verification and `git diff --check` pass.
- Independent Spec and Standards reviews report no remaining findings after counter-predecessor, delayed-revision, optional-import recovery, refresh-publication, timezone and interval-query fixes.
- Native Settings verifies yesterday-only 250-token fixtures (today and intentionally skipped old history excluded), explicit saved-count import to270, pause/restart/resume of a large older transcript to1170, all period controls, source removal, private permissions and absence of prompt/reply/argument/raw-ID/path markers. User config/hooks/launcher hashes remain unchanged. Archive-only fixture restart measured about2.6seconds including native UI automation; initial setup is allowed to run in the background.
- Two independently interrupted/resumed imports of a read-only ~250MiB legacy snapshot produce identical90daily reports, with798647 indexed observations, SQLite integrity checks passing and the legacy snapshot hash unchanged. Time aggregates compare to millisecond precision. Freshly opened archive-only90day summaries average27–52ms and read zero observation rows; unchanged-source retries read zero source bytes.
- Isolated archive/import benchmark peak RSS:189–209MiB. One timed continuation read84.9MB from its checkpoint and rebuilt90reports in530seconds under concurrent debug/test load; another complete-source restart read0source bytes and rebuilt the reports in193seconds. These are continuation/rebuild measurements, **not fresh full-import timings or whole-app memory guarantees**. Initial import remains an explicit, potentially lengthy background operation. Other live Today/session scanners retain their existing behavior.
- Covering interval index: on the same ~800k-observation database, an empty-day overlap query fell from6.003s to0.103s by filtering both interval boundaries from the index before loading record bodies. Existing databases add the index without replacing counts/checkpoints.
- Source logs, old history and release metadata are preserved. The normally launched local app uses the new backend; initial automatic recent-day settlement can continue after delivery. Earlier history stays opt-in. No release is published.
