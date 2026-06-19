# Mechanical batch — T-2, T-8, T-3

Three small, high-confidence fixes. Unlike T-1/T-4, these have **no
release-pipeline coupling** — they close their findings in code.

> ⚠️ **INERT — for human review only.** Not applied, not built, not tested. The
> verify ladder + independent reviewer could not run (spend limit). Pure
> string/stat changes, low risk, but **expect some unit tests to need updating**.

## T-2 — bound the sibling transcript readers (issue #132)
`PATCHES/bug_T2/patch.diff` — `UsageTracker.swift` (codex scan), `TaskExtractor.swift`

Routes the two uncapped whole-file readers through the **existing**
`shouldScanTranscript(isSymbolicLink:fileSize:)` (256MB cap + symlink skip) that
PR #119 added to the Claude path only. No new policy — reuses the shipped helper.
- Codex scan: adds `.isSymbolicLinkKey` to the already-fetched resource values
  and gates before the `String(contentsOf:)`.
- `TaskExtractor`: stats first (mirrors the Claude path's fail-closed
  guard — stat failure → `return []`).

## T-8 — clamp untrusted token counts (issue #133)
`PATCHES/bug_T8/patch.diff` — `UsageTracker.swift`, `DailyUsage.swift`

Adds `UsageTracker.clampTokens(_:)` (`min(max(0, v), 1_000_000_000)`) and applies
it at the **two parse sites** (`parseFileRecords`, `parseCodexDailyTallies`).
Clamping at ingestion means every downstream `+`/`+=` is bounded far below
`Int.max`, so the trapping accumulation can no longer overflow — without touching
the fold arithmetic. `1e9`/field is ~1000× any real per-message count yet leaves
~9 orders of magnitude of headroom before `Int64` overflow.

**Watch-item:** a legitimately huge cumulative codex total (>1e9 tokens in one
rollout — economically absurd) would be capped in the *display*. Acceptable for a
usage indicator; confirm no test asserts exact totals above 1e9.

## T-3 — centralize control-char sanitization (issues #124, #133-adjacent)
`PATCHES/bug_T3/patch.diff` — `TerminalTitleWriter.swift`, `TerminalLocator.swift`, `NotificationManager.swift`

The cwd basename bypassed all three sanitizers. Fix sanitizes the **whole composed
title at the write/escape boundary** so no field can bypass, in *both* OSC writers:
- `TerminalTitleWriter.oscEscape` now runs the full title through `sanitizePrompt`
  (no-truncate); `sanitizePrompt` also now strips C1 (0x80–0x9F).
- `TerminalLocator` gains a no-truncate `stripControls` used in `writeSessionTitle`
  on the whole title; `sanitizeTitlePrompt` is refactored to reuse it.
- `NotificationManager` gains `displaySafe` (strips C0/C1/DEL + bidi/zero-width
  overrides), applied to the notification **title** `projectName` and folded into
  the body `sanitizePrompt` (closes T-10/F-008 UI-spoofing too).

**Watch-item:** confirm normal titles/prompts (printable text, CJK) are unchanged
— these filters only drop control/bidi scalars. Update any sanitizer unit tests
that assert the old per-field behavior.

## Verify (all three, when spend allows)
1. `git apply PATCHES/bug_T{2,8,3}/patch.diff`; `swift build` / `make app`.
2. Run `SharedTests` / `AppLibTests` / `BridgeLibTests` — expect targeted test
   updates (sanitizer behavior, clamp ceiling), not regressions.
3. Manual smoke: titles still render; notifications still readable; usage panel
   still tallies; an oversized/symlinked transcript is now skipped.
