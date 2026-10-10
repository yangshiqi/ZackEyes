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


## Local app launch smoke test (2026-10-08)

Launched `.build/ZackEyes.app` (PID 40568) and verified the owner-only socket at `~/.zackeyes/zackeyes.sock`. Accessibility inspection reported `frontmost == false` both at launch and while the permission panel was expanded, so the app did not steal foreground focus. Cropped screenshots confirmed the permission panel and existing GPT-6.1 Sol cards with `est.` costs.

A uniquely named synthetic session sent events through the bundled Bridge: completed old turn → identifier-less prompt → new-ID PermissionRequest. The request remained pending (not prematurely denied); Interrupt returned `Turn interrupted` to the Bridge and exited cleanly. Manual PreCompact/PostCompact hooks were delivered; SessionEnd cleaned up the test session. No model inference was executed. Rollout-first compaction dedup and tier-change cost parity remain covered by the regression tests, not by this live smoke sequence.

The app remains running for user inspection. Startup ran the normal HookRepair path. No manual edits to user configuration were made and config.toml was not accessed. Screenshots remain local under /private/tmp and were not attached to the PR.


## Reasoning effort display (#253)

The user requested effort beside the model. Session cards now show observed Codex effort, including before context usage becomes available. Turn-context effort and settings-snapshot reasoning_effort update the same SessionInfo field. Missing fields preserve the current value; explicit null/empty values clear it, and a model switch drops an unknown effort. Startup metadata folds bounded head/tail records so recent settings replace the first-turn snapshot.

Three regressions failed before implementation; a fourth test covers startup settings overrides/null resets. 112 relevant tests and all 925 tests pass (135 XCTest + 790 Swift Testing); make app/build and strict deep codesign pass. The rebuilt local app was restarted (PID 46260); a live GPT-6.1 Sol card visibly displayed `gpt-6.1-sol · medium`. The synthetic permission request used to expand the panel received a valid Allow response before the smoke harness's expected Interrupt denial, so that harness assertion was not a successful re-verification of Interrupt in this run. The test session was cleaned up. No model inference or config.toml access was performed by this task; screenshots stay local and are not attached.
