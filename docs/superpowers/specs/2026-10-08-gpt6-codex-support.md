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
