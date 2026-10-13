# PR #266 local continuation

Scope: issue #260, opt-in AskUserQuestion answers through the existing Bridge.

1. Build the incoming PR on macOS and reproduce answer/lifecycle defects with Swift Testing.
2. Release live question responders and cancel timers on every existing question cleanup path. Preserve unrelated approvals.
3. Reject incomplete or ambiguous questions/answers and hand unsupported input to the terminal. Release the bridge before any failed-submit terminal jump.
4. Verify socket answer/defer behavior, timeout/cancellation, and request identity in the UI.
5. Run `swift build`, full `swift test`, `make app`, and signing verification. Exercise the UI where local facilities allow it; record actual verification limits.
6. Compare the final behavior against every requirement in issue #260, inspect the whole branch diff, update architecture/memory, and commit locally.

Acceptance: default OFF; enabled requests have a 120-second fallback; an explicit terminal escape hatch remains available; unsupported/partial choices never get submitted as complete answers. Bridge controlled failures stay silent with exit 0. Both notch surfaces share the same view. No release or merge is part of this task.

## Review against issue #260

| Requirement | Final behavior and evidence |
| --- | --- |
| Opt-in, default OFF | Missing/corrupt config returns false; ConfigStore tests cover persistence and defaults. Actual app/Bridge probe with the preference absent returns immediately with exit 0 and empty output. |
| Settings toggle | Attention section includes “Answer questions from the notch”; AppDelegate reads the persisted preference for each incoming question. |
| Two-minute fallback | Production countdown is 120 seconds; timeout/replacement-cancellation tests exercise the same implementation with shorter durations. The actual app countdown is also exercised locally. |
| Explicit terminal escape | “Answer in terminal” closes the live responder before attempting terminal activation. Actual UI probe confirms empty Bridge output and exit 0. Failed submissions use the same release-before-jump policy. |
| Simple complete choices only | Strict question/option field whitelist rejects rich previews and future content fields. Empty, duplicate, malformed or ambiguous labels/questions go to the terminal. Invalid/partial multi-select answers are never filtered into a successful partial answer. |
| Preserve native default | OFF and unsupported input immediately defer and keep a notice-only card. The AskUserQuestion PermissionRequest companion never auto-allows. |

Two-axis code review found and then verified fixes for exact-ID completion being shadowed by an earlier uncorrelated notice (Standards), and rich option previews being accepted while invisible in the notch (Spec). Both final reviews report no remaining blockers. Official preview evidence: https://code.claude.com/docs/en/agent-sdk/user-input#option-previews-type-script .

Additional regressions cover six formerly stranded lifecycle paths, SessionStart compact waiting-state cleanup, first-question completion not affecting its waiting sibling, fresh SwiftUI selections per request, strict multi-select validation and cancellation of a replaced timeout. Socket tests use isolated Unix sockets; UI smoke uses `CFFIXED_USER_HOME` to isolate app config/hook deployment from the real user home.

Verification logs are local temporary artifacts: `/tmp/zackeyes-266-tests-complete.log`, `/tmp/zackeyes-266-app-complete.log`, `/tmp/zackeyes-266-ui-results.log`. Full suite: 837 Swift Testing + 138 XCTest = 975 passing. `make app` builds both executables; deep strict signing verification passes. The actual timeout returned with empty output and exit 0 after 119.83 seconds measured from rendering (120 seconds from enqueue). Final probe verified hashes of the real user configs, launcher and app-path marker were unchanged, and terminated the isolated app.

Manual scope: actual built app and Bridge on the simulated-notch path (all connected displays have zero top safe-area inset), Accessibility-driven single/multi choices, reset of selection on the next request, escape/default-OFF/preview fallback, real 120-second countdown, and no app activation on selection/submit. This does not establish a live Claude Code tool invocation or behavior on a separate physical notched Mac.
