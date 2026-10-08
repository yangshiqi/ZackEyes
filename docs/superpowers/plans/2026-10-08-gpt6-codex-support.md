# GPT-6 and Codex Support Implementation Plan

**Goal:** Fix the confirmed protocol gaps sequentially, with native GitHub sub-issues and independent commits.
**Architecture:** Existing hooks feed Bridge/Socket/Session; rollout tailing remains a fallback. Prices use exact IDs. Request-level data is retained before aggregation where available.
**Tech Stack:** Swift 6 / Foundation / Swift Testing / macOS 14+.
**Spec:** docs/superpowers/specs/2026-10-08-gpt6-codex-support.md

## Global constraints

Never read/write ~/.codex/config.toml. Preserve unrelated user configuration, back up hooks.json before writes, and use temporary fixtures. Controlled Bridge failures silently exit(0). No new third-party dependencies or NSPanel changes.

## Execution (sequential)

For every task: add behavioral regression, observe expected failure, implement minimally, run relevant suite, update architecture when needed, commit with corresponding issue reference.

- [ ] Shared: EventProtocol.swift + EventProtocolTests.swift; dual model input, optional identifiers, round-trip and malformed metadata.
- [ ] Usage: Resources/pricing.json + PricingTableTests.swift; exact GPT-6 prices and monotonic resource version.
- [ ] Lifecycle: CodexHookInstaller.swift + SessionStore.swift + installer/session tests; end/interruption and safe cleanup.
- [ ] Compaction (#233): CodexJsonlTailer.swift + SessionStore.swift + AppDelegate.swift; fallback completion and dual-source deduplication.
- [ ] Subagents: installer/store/tailer and tests; exact parent pairing and spawned-thread display filtering.
- [ ] Concurrency: Shared identifiers → SessionInfo turn/tool tracking → store/tailer/AppDelegate; stale events, concurrent tools and prompt updates.
- [ ] Request pricing: ModelPrice/DailyUsage/SessionStore and tests; model attribution, tiers, input threshold, explicit estimate semantics.
- [ ] App Server: official docs plus read-only local help/schema evidence; record existing-session ownership boundary in docs.
- [ ] Final verification: swift build, swift test, make app, disconnected/malformed Bridge smoke checks, update memory and parent issue.
