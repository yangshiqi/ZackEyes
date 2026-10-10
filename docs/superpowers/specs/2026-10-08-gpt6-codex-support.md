# GPT-6 model and Codex protocol support

User authorized sequential implementation after the official-documentation research on 2026-10-08. This work keeps ZackEyes an observer of the user's existing CLI.

## Components and behavior

1. Shared/Bridge: accept both Codex's string model and Claude's model object, normalizing the string to the existing `{id, display_name}` representation. Preserve optional turn/tool identifiers. Invalid optional model metadata must not discard an approval event.
2. Usage: add exact model IDs and standard prices to the versioned bundled table. Compute per-request costs before aggregation when the transcript supplies sufficient information. Keep legacy tallies, identify missing pricing metadata as estimates, and never infer charged cache writes without usage evidence.
3. Codex hooks/Session: add observation-only end/interruption, compaction and subagent lifecycle events. Back up only the injected temporary test configuration during tests; never change real user configuration during development. End removes a session; interruption clears the interrupted turn without a finished notification.
4. Compaction: reuse #233; hooks provide begin/end on new CLIs and rollout `context_compacted` provides completion on older ones. Deduplicate the two live paths; attaching at EOF must not replay historical completions.
5. Subagents: parent hook session_id + agent_id pairing; do not copy child replies or completion state into the parent. Existing guardian/review labels remain supported. Ordinary spawned child rollouts should not create duplicate top-level user cards.
6. Concurrency: identify active Codex turn and running tool calls; stale end/tool events must not close new work. Missing IDs retain legacy behavior. User updates during the same active turn preserve its running work.
7. App Server: document protocol and connection ownership, including evidence for the boundary around existing CLI sessions. Do not introduce a second agent runtime or mutate Codex configuration to claim existing-session control.

## Constraints

macOS 14+, Swift 6, no third-party dependencies. Never read/write ~/.codex/config.toml. Hooks include zackeyes and explicit --agent. Backup before changing hooks.json; preserve unrelated entries. Bridge controlled failures stay silent exit(0). No NSPanel behavior changes.

## Verification

Test each behavior before implementing; run relevant suites per atomic component change. Final swift build, swift test, make app. Test new hook install/uninstall against temporary files and confirm restoration/backup. Capture Bridge stdout/stderr for malformed/disconnected cases. No claims of real CLI payload verification without performing it.

## Sources

- https://developers.openai.com/api/docs/models/gpt-6.1-sol
- https://developers.openai.com/api/docs/models/gpt-6-astra
- https://developers.openai.com/api/docs/guides/latest-model
- https://learn.chatgpt.com/docs/hooks
- https://learn.chatgpt.com/docs/app-server


## Verified model differences and integration scope

| Property | GPT-6.1 Sol | GPT-6 Astra |
| --- | --- | --- |
| Context / max output | 1,050,000 / 128,000 tokens | 1,050,000 / 128,000 tokens |
| Standard input / output per MTok | $2 / $10 | $10 / $50 |
| Cache read / write per MTok | $0.10 / $2.50 | $1 / $12.50 |
| >272,000 input per request | Whole-request input/read/write ×2, output ×1.5 | Same |
| Observed API service tiers | Fast/priority ×2, Ultrafast ×6, Flex/Batch ×0.5 | Same |

Published GPT-6 improvements include asynchronous tool calling, steering and runtime reasoning reconfiguration. ZackEyes needs concurrent event correlation for observation, but these API/runtime capabilities are not automatically UI controls for an independently launched CLI. Responses tools are distinct from Chat Completions capabilities. API reasoning options and a Codex model catalog's effort labels must remain distinct; do not infer availability or billing from effort labels. The dedicated Responses multi-agent beta guide explicitly names Sol 6.1 and GPT-5.6; Astra beta support must not be assumed from the family name.

No context/window size is hardcoded into the observer: rollout model_context_window remains authoritative. No inference requests were made to benchmark these models or validate their claimed quality.

## Implementation outcome

Epic #243 owns native sub-issues #244–#250 and existing #233. Each implementation has an independent commit and behavioral regressions. App Server #250 is resolved by an ownership boundary decision, without introducing runtime control. Codex costs remain estimates, especially for missing tier/request metadata or history predating watcher attachment. Long-request multipliers are applied only when last-request components match the cumulative delta; unknown multi-request gaps retain the standard estimate.

Additional primary sources: [pricing](https://developers.openai.com/api/docs/pricing), [steering](https://developers.openai.com/api/docs/guides/steering), [Responses multi-agent](https://developers.openai.com/api/docs/guides/responses-multi-agent), [Codex protocol source](https://github.com/openai/codex/blob/main/codex-rs/protocol/src/protocol.rs).
