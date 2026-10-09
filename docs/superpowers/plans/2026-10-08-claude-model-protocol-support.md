# Claude support implementation

1. Regressions for live effort snapshots/patches/child isolation, then Shared + SessionStore metadata support.
2. Exact current model rates and explicit 1h write rates, with backward-compatible decoding.
3. Response speed/TTL weighted billing; retain raw tokens, scanner cache, dedup and aggregation.
4. Reuse #39: observe failed tool/turn hooks; concurrent IDs; installer fixture and state regressions; model-change hook.
5. Full suite/build/app, real local session observation, independent conventional commits and stacked draft PR.

Quota/workflow/variable-price follow-ups remain separately tracked; see spec evidence matrix for boundaries.

## Verification — 2026-10-08

- Full `swift test`: 808 Swift Testing tests in 87 suites plus 135 XCTest tests; all 943 passed.
- `make app`: both executables built and the local app bundle assembled and signed.
- Regression probes first reproduced child compaction/session hooks changing their parent's state and synthetic API errors replacing recovered replies. Both pass after the fixes; child approvals remain actionable.
- Explicitly withdrawn model metadata clears the previous model and effort. Startup recovery skips synthetic/API-error assistant envelopes.
- Latest local app launched successfully; its socket was recreated at 14:55. Real Claude Code 2.1.295 interactive session with Opus 5.5, high effort and all tools disabled replied `OK`; its actual Stop hook included `effort.level = high` and the card displayed `Opus 5.5 · high` and `OK`. SessionStart and UserPromptSubmit omitted effort in this probe, so the value appeared after Stop. Accessibility also confirmed an existing Claude card displaying `Opus 5.5 · xhigh`.
- The user's notch visibility is Hidden and their expand shortcut is Cmd+Shift+/. Opening the panel and clicking Recent kept ZackEyes `frontmost = false`. No display or shortcut settings were changed. Test hooks used an isolated temporary settings file, preserving user hook settings. Screenshot evidence: `/private/tmp/zackeyes-claude-effort-verified.png`.
- Draft PR #258 targets the Codex support branch; issue #254 tracks #255, #256, #257 and existing #39.

## Review follow-up — 2026-10-08

Both P2 notification findings are fixed. AppDelegate now consumes a tested SessionNotificationPolicy: child Claude Stop cannot notify parent completion, and API error detail takes precedence over prior conversational text. Regressions reproduced both failures before the corrections; normal parent completion, old error fallback, replay suppression and failed/idle turn gates remain covered. Full suite: 811 Swift Testing tests in 88 suites + 135 XCTest = 946 passed.
