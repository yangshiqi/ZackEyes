# GPT-6 and Codex Support Implementation Plan

**Goal:** Fix the confirmed protocol gaps sequentially, with native GitHub sub-issues and independent commits.
**Architecture:** Existing hooks feed Bridge/Socket/Session; rollout tailing remains a fallback. Prices use exact IDs. Request-level data is retained before aggregation where available.
**Tech Stack:** Swift 6 / Foundation / Swift Testing / macOS 14+.
**Spec:** docs/superpowers/specs/2026-10-08-gpt6-codex-support.md

## Global constraints

Never read/write ~/.codex/config.toml. Preserve unrelated user configuration, back up hooks.json before writes, and use temporary fixtures. Controlled Bridge failures silently exit(0). No new third-party dependencies or NSPanel changes.

## Execution (sequential)

For every task: add behavioral regression, observe expected failure, implement minimally, run relevant suite, update architecture when needed, commit with corresponding issue reference.

- [x] Shared: EventProtocol.swift + EventProtocolTests.swift; dual model input, optional identifiers, round-trip and malformed metadata.
- [x] Usage: Resources/pricing.json + PricingTableTests.swift; exact GPT-6 prices and monotonic resource version.
- [x] Lifecycle: CodexHookInstaller.swift + SessionStore.swift + installer/session tests; end/interruption and safe cleanup.
- [x] Compaction (#233): CodexJsonlTailer.swift + SessionStore.swift + AppDelegate.swift; fallback completion and dual-source deduplication.
- [x] Subagents: installer/store/tailer and tests; exact parent pairing and spawned-thread display filtering.
- [x] Concurrency: Shared identifiers → SessionInfo turn/tool tracking → store/tailer/AppDelegate; stale events, concurrent tools and prompt updates.
- [x] Request pricing: ModelPrice/DailyUsage/SessionStore and tests; model attribution, tiers, input threshold, explicit estimate semantics.
- [x] App Server: official docs plus read-only local help/schema evidence; record existing-session ownership boundary in docs.
- [x] Final verification: swift build, swift test, make app, disconnected/malformed Bridge smoke checks, update memory and parent issue.


## Final verification (2026-10-08)

- `swift build`: passed, both executables built.
- `swift test`: passed, 135 XCTest + 782 Swift Testing tests (917 total).
- `make app`: passed; `codesign --verify --deep --strict .build/ZackEyes.app`: passed.
- Bridge binary: empty stdin, malformed/non-object JSON, missing args and invalid flags all return 0 with empty stdout/stderr. Missing-socket and live-socket paths are covered by the full BridgeLib suite.
- Installer fixtures verify backups, unrelated metadata preservation and restoration. Real user hook/config files were not modified by this development task.
- `git diff --check`: passed. No agent inference/runtime takeover or manual GUI interaction was performed. UI change is limited to the estimate label; panel behavior is unchanged.


## PR #252 review corrections (2026-10-08)

- Completed-turn state resets when the next UserPromptSubmit omits turn_id; active identifier-less steering preserves tools and pending approvals (3fe28df, #249).
- PostCompact always saves its manual completion state even when the rollout has already incremented the counter (2de407e, #233).
- Streamed turn_context propagates service_tier updates, preserving absent fields and clearing explicit nulls; live and daily cost estimates agree through tier changes (137f8b2, #248).
- Four new tests: three regressions reproduced before fixes; the active-steering preservation test passed both before and after.
- 123 relevant tests passed. Final swift build and all 921 tests passed (135 XCTest + 786 Swift Testing), including socket/process tests with the required sandbox permissions. make app and deep strict codesign verification passed; git diff --check passed.
