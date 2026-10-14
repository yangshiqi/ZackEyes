# Local Usage Ledger Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** Add an append-only, local-only statistics ledger and Settings Usage page satisfying #263.

**Architecture:** Parse transcripts into bounded, content-free observations, persist latest revisions by hashed identity in an actor-owned append-only file, and compute calendar-aware summaries off the main actor. One observable service schedules collection and supplies Settings; existing quota/session paths remain independent.

**Tech Stack:** Foundation, CryptoKit (system framework), Swift Testing, SwiftUI Charts (macOS 14+). No external packages.

**Spec:** `docs/superpowers/specs/2026-10-14-local-usage-ledger-design.md`

## Global Constraints

- Never read or write Codex config.toml; only read the two transcript roots.
- Persist only counts, bounded project/model/tool metadata, hashed identities and UTC times/intervals; never prompts, replies or tool arguments.
- New writes use owner-only permissions, serialized append + sync; restart/source removal/duplicate delivery must not inflate totals.
- Agent-hours union paired work intervals, subtract explicit question waits, cap unpaired genuine-event gaps at five minutes; no stretching to scan time.
- Daily/hour buckets use the selected local Calendar, including DST; ranges are 7/30/90 days.
- Preserve existing Bridge, hooks, quota, journal, notifications and panel focus behavior.

### Task 1: Transcript observation and statistical core

**Files:** create `Sources/AppLib/Usage/Ledger/UsageLedgerTypes.swift`, `UsageLedgerParser.swift`, `UsageLedgerSummary.swift`; test `Tests/AppLibTests/UsageLedgerTests.swift`.

**Interfaces:** `UsageLedgerParser.parse(text: String, agent: AgentKind, sourceID: String) -> [UsageLedgerRecord]`; `UsageLedgerSummary.make(records: [UsageLedgerRecord], days: Int, now: Date, calendar: Calendar) -> UsageLedgerSummary`. Records carry version/id/session/agent/project/model/date, four token counters, optional tool, kind and optional interval end.

- [ ] Write fixture assertions for Claude repeated message revisions and tools; Codex cumulative deltas/reset and copied session identities; no content-bearing keys in encoded records; ten-minute sparse/dense tool activity equality, interval overlap/question subtraction and midnight/DST buckets.

```swift
let records = UsageLedgerParser.parse(text: fixture, agent: .claude, sourceID: "fixture")
let report = UsageLedgerSummary.make(records: records, days: 7, now: now, calendar: utc)
#expect(report.totalTokens == 150)
#expect(report.activeSeconds == 600)
```

- [ ] Run `swift test --filter UsageLedgerTests` and confirm missing types/behavior fails.
- [ ] Implement validated records, SHA256 natural identities, per-agent pure parsers, per-session interval union/subtraction and local-day/hour clipping. Use `#expect` fixtures to pin each statistical definition.
- [ ] Re-run the focused tests and fix failures before proceeding. Commit `feat(usage): parse private ledger observations`.

### Task 2: Durable append-only store and cached collector

**Files:** create `Sources/AppLib/Usage/Ledger/UsageLedgerStore.swift`, `UsageLedgerCollector.swift`; test `Tests/AppLibTests/UsageLedgerStorageTests.swift`.

**Interfaces:** actor `UsageLedgerStore(url:)` with `upsert(_ records:) async throws`, `summary(days:now:calendar:) async throws`; actor `UsageLedgerCollector(claudeRoot:codexRoot:)` with `scan() async throws -> Scan` (observations + nonfatal scan issues). Persist updates only when changed and only mark recorded after successful append+sync.

- [ ] Write and run failing restart/duplicate/revision, deleted-source retention, partial-tail recovery, unsupported schema, file permissions and write-error tests using temporary directories.

```swift
try await store.upsert(records)
try await store.upsert(records)
let restored = UsageLedgerStore(url: url)
#expect(try await restored.summary(days: 7, now: now, calendar: utc).totalTokens == 150)
```

- [ ] Implement owner-only regular-file I/O with no symlink/FIFO reads, newline separation after a partial tail, bounded decode/validation and visible warnings. Collector recursively walks only allowed roots, skips symlinks/oversized files, caches unchanged metadata, reports incomplete scans and honors cancellation.
- [ ] Run focused tests; commit `feat(usage): persist deduplicated local history`.

### Task 3: Observable lifecycle and native Usage page

**Files:** create `UsageLedgerService.swift`, `UsageLedgerView.swift` under the Ledger directory; modify `SettingsRootView.swift`, `SettingsWindowController.swift`, `AppDelegate.swift`; test `UsageLedgerServiceTests.swift`.

**Interfaces:** `@MainActor public final class UsageLedgerService: ObservableObject` owns published summary/loading/error/last-successful-date and selected range; `start()`, `stop()`, `refresh() async`, `setDays(_:)`. AppDelegate owns one instance, starts it after initialization and cancels on shutdown. Settings accepts the same service and requests refresh when opened.

- [ ] Write/run failing service tests for first collection, range change, visible scan/write failures, overlapping refresh prevention and canceled generation not publishing.
- [ ] Implement the service using actor work and a 60-second loop. Settings sidebar adds Usage; page shows totals, two per-agent daily charts, cache rate, top project/model/tool lists, a 24-hour heatmap, loading/error/empty states, last update and explicit estimation/privacy copy.

```swift
.task { await ledger.refresh() }
Picker("Period", selection: rangeBinding) {
    Text("7 days").tag(7)
    Text("30 days").tag(30)
    Text("90 days").tag(90)
}
```

- [ ] Run focused tests and compile native Charts/Settings; commit `feat(usage): show local history in settings`.

### Task 4: Review, integration verification and merge

**Files:** update `ARCHITECTURE.md`, `README.md`, this plan, local memory; no SSH code/spec in this PR.

- [ ] Run full `swift build`, `swift test`, `make app`, strict deep codesign and `git diff --check`; inspect exit statuses and totals.
- [ ] Use an isolated CFFIXED_USER_HOME with seeded Claude/Codex fixtures to exercise actual Settings Usage, all ranges, populated/empty/error paths, restart and source deletion; inspect persisted JSONL for content leakage and actual-user config hashes for changes.
- [ ] Apply code-review skill with independent Spec and Standards agents against base `5f389ec`; fix concrete findings with regression coverage and repeat affected checks.
- [ ] Update developer-build README/architecture and plan with actual results. Commit, push feature branch, create PR closing #263 using a body file, inspect checks and merge the exact tested full head.
- [ ] Verify merged state and #263 closure, update #265 checkbox and memory, sync master. Continue #261 from its separately approved spec; final roadmap/site reconciliation follows both features.
