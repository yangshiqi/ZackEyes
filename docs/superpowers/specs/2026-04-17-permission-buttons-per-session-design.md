# Permission Approval Buttons — Move Into Session Card

**Date**: 2026-04-17
**Status**: Draft
**Scope**: `NotchExpandedView.swift`, `NotchViewModel.swift`

## Problem

In the expanded notch panel, the regular permission approval buttons (`Deny` / `Allow Once`) are rendered at the very bottom of the outer `VStack` — outside any session card. When a session card is tall (context bar + tasks + tool preview + permission detail) or when multiple sessions coexist, the buttons are visually detached from the session that triggered them. Users report the buttons are easy to miss because they sit far below the session they belong to.

Current layout (`NotchExpandedView.swift:29-33`):

```
┌─ popup ──────────────────┐
│ Session A (pending)      │
│   …permission details…   │
│ Session B (idle)         │
│                          │
│ [Deny]   [Allow Once]    │ ← detached from A
└──────────────────────────┘
```

AskUserQuestion has a different layout (`askUserQuestionBlock`, line 410). It already renders inside the session card and has its own "Answer in terminal" CTA as a footer. Its position is already correct — no change needed.

## Goal

The Deny / Allow Once buttons should render inside the session card that has the pending permission, directly below `permissionDetailBlock`. Each session with a pending permission shows its own buttons; the buttons operate on that specific session.

## Design

### UI change

Move `permissionApprovalButtons` (`NotchExpandedView.swift:541`) from the top-level `VStack` into `sessionCardContent`. Render it after `permissionDetailBlock` (line 208), inside the same inner `VStack(alignment: .leading, spacing: 6)`. The button row stays inside the card's rounded-rect background, sharing the card's padding.

Condition for rendering (unchanged): `session.pendingPermission != nil && !pending.isAskUserQuestion`.

### ViewModel change

Current `NotchViewModel.approve()` / `deny()` hardcodes `sessionStore.resolvePrimaryPermission(allow:)`, which only resolves the primary session's permission. With per-session buttons, each button must resolve the permission of *its own* session, not the primary one.

Replace:

```swift
public func approve() { sessionStore.resolvePrimaryPermission(allow: true) }
public func deny()    { sessionStore.resolvePrimaryPermission(allow: false) }
```

With:

```swift
public func approve(sessionId: String) { sessionStore.resolvePermission(sessionId: sessionId, allow: true) }
public func deny(sessionId: String)    { sessionStore.resolvePermission(sessionId: sessionId, allow: false) }
```

`SessionStore.resolvePermission(sessionId:allow:)` already exists (`SessionStore.swift:254`) and is the per-session primitive `resolvePrimaryPermission` wraps.

### Keyboard shortcuts

Today `⌘Y` / `⌘N` are attached via `.keyboardShortcut` on the bottom buttons. With buttons moved into each pending-session's card, multiple simultaneous pending permissions would bind the same shortcut multiple times — SwiftUI behavior is undefined.

Rule: only the `primarySession`'s buttons get `.keyboardShortcut`. Non-primary pending sessions' buttons are click-only. This preserves the current "hotkey resolves the most urgent one" behavior. `primarySession` is already defined as the first session with a pending permission (`SessionStore.swift:85`).

Implementation: `permissionApprovalButtons(for session: SessionInfo, isPrimary: Bool)` conditionally applies `.keyboardShortcut` based on `isPrimary`.

### Call sites to update

Only two call sites reference `approve()` / `deny()` — both in `NotchExpandedView.swift` (lines 543, 560). Both get updated to pass the owning session's id.

## Non-goals

- No change to `askUserQuestionBlock` layout or routing.
- No change to socket protocol, `PendingPermission` model, or hook wiring.
- No change to `SessionStore.resolvePermission` or `resolvePrimaryPermission`.
- No change to the outer panel layout outside removing the now-empty trailing approval block.

## Testing

- `SessionStoreTests.resolvePermissionAllowReturnsToWorking` exercises `resolvePrimaryPermission` — still green (method unchanged).
- Manual verification: drive a `PermissionRequest` hook via stdin to the bridge binary (see `CLAUDE.md` → Bridge manual test), confirm buttons render inside the card and resolve the correct session. Add a second pending session via a second hook call and confirm each card's buttons are independent.

## Risks

- **Single session case (dominant)**: no behavior change; just a layout move. Low risk.
- **Multi-session pending**: new capability — previously impossible to resolve non-primary permission via UI without waiting for the primary to clear. This is an improvement, but regressions in shortcut behavior are possible if the shortcut gate is wrong. Covered by restricting `.keyboardShortcut` to primary.
- **Card height**: adding buttons inside the card makes the card taller. `SimulatedNotchController` height heuristic (per ARCHITECTURE.md) may need re-tuning if the cumulative session-stack height overflows. Verify during manual test; adjust heuristic only if overflow is observed.
