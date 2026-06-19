# Candidate patch — T-9: kqueue tailer unbounded buffer (issue #133)

**File:** `Sources/AppLib/Session/CodexJsonlTailer.swift`
**Finding:** TRIAGE T-9 (folds F-009 + F-026).

> ⚠️ **INERT — for human review only.** Not applied, not built, not tested.

## What it does
1. **Caps the carried partial line** (`maxPendingBytes` = 8 MB): `parseTaskLifecycleEvents`
   drops an over-long newline-free partial instead of carrying it across kqueue
   events forever (closes F-009's unbounded `pendingBuffer` growth).
2. **Bounds a single read** (`maxReadBytes` = 16 MB): on a huge newline-free
   append, `readNewBytes` skips to a bounded tail rather than reading the whole
   gap into memory at once, and clears the now-meaningless stale partial.
3. **Handles in-place truncation** (`endSize < offset`): resets `offset` to the
   new EOF and clears the buffer, so the watcher no longer goes permanently
   silent or resumes mid-record (closes F-026).

## Trade-offs / watch-items
- On a **legitimate** catch-up larger than 16 MB between kqueue events (app was
  closed while the rollout grew a lot), the older part of that gap is skipped —
  acceptable for a *live* "task complete" tailer (it's not the historical usage
  scanner, which is separate). Confirm 16 MB is comfortably above real
  inter-event growth; raise if needed.
- No underflow: `endSize - offset > maxReadBytes` implies `endSize > maxReadBytes`,
  so `endSize - maxReadBytes` is safe in `UInt64`. Confirm in review.
- Tests: any `CodexJsonlTailer` test asserting exact resume/offset behavior on
  truncation may need updating (the new reset path is intended).

## Verify
`git apply PATCHES/bug_T9/patch.diff`; `swift build`; run `AppLibTests`
(tailer tests); smoke-test that normal codex rollouts still surface task-complete
notifications.
