# Permission Buttons Per Session — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Relocate the `Deny` / `Allow Once` buttons from the bottom of the expanded notch panel into each pending session's card, so the buttons stay visually anchored to the session that triggered them.

**Architecture:** SwiftUI layout move inside `NotchExpandedView.swift`, plus a session-scoped `approve(sessionId:)` / `deny(sessionId:)` pair on `NotchViewModel` that delegates to the already-existing `SessionStore.resolvePermission(sessionId:allow:)`. Keyboard shortcuts (`⌘Y` / `⌘N`) are gated to the primary session only, to avoid duplicate bindings when multiple sessions have pending permissions.

**Tech Stack:** Swift 6, SwiftUI, Swift Testing (`@Test`), SPM.

**Spec:** [`docs/superpowers/specs/2026-04-17-permission-buttons-per-session-design.md`](../specs/2026-04-17-permission-buttons-per-session-design.md)

---

### Task 1: Regression test — `resolvePermission` is session-scoped

The new UI depends on the store resolving one session's permission without touching another's. `SessionStore.resolvePermission` already implements this, but no test guards it. Add a regression test.

**Files:**
- Modify: `Tests/AppLibTests/SessionStoreTests.swift` (append new `@Test`)

- [ ] **Step 1: Add the test**

Append the following method inside the `SessionStoreTests` struct in `Tests/AppLibTests/SessionStoreTests.swift`, placed after the existing `resolvePermissionAllowReturnsToWorking` test (around line 69):

```swift
    // 5b. resolvePermission(sessionId:allow:) only clears the named session,
    //     leaves other pending sessions intact. Guards the contract relied on
    //     by per-session approval buttons in the notch panel.
    @Test func resolvePermissionScopedToNamedSession() {
        // Swift 6 @Sendable closures cannot capture `var`; use a reference box.
        // `PermissionResponse` is a struct (not an enum), so the deny-check
        // compares the `behavior` field rather than pattern-matching a case.
        final class Box<T>: @unchecked Sendable { var value: T? }
        let store = SessionStore()
        store.handleEvent(BridgeEvent(bridgeEvent: "SessionStart", sessionId: "s1", cwd: "/a"))
        store.handleEvent(BridgeEvent(bridgeEvent: "SessionStart", sessionId: "s2", cwd: "/b"))

        let s1Box = Box<PermissionResponse>()
        let s2Box = Box<PermissionResponse>()
        let s1Permission = PendingPermission(
            toolName: "Bash", toolInput: [:], cwd: "/a",
            responder: { s1Box.value = $0 }
        )
        let s2Permission = PendingPermission(
            toolName: "Write", toolInput: [:], cwd: "/b",
            responder: { s2Box.value = $0 }
        )
        store.handlePermissionRequest(sessionId: "s1", permission: s1Permission)
        store.handlePermissionRequest(sessionId: "s2", permission: s2Permission)

        store.resolvePermission(sessionId: "s2", allow: false)

        // s2 cleared and denied
        #expect(store.sessions["s2"]?.pendingPermission == nil)
        #expect(store.sessions["s2"]?.state == .working)
        #expect(s2Box.value?.hookSpecificOutput.decision.behavior == "deny",
                "s2 should have been denied")

        // s1 untouched
        #expect(store.sessions["s1"]?.pendingPermission != nil)
        #expect(store.sessions["s1"]?.state == .waiting)
        #expect(s1Box.value == nil)
    }
```

- [ ] **Step 2: Run the test**

Run: `swift test --filter AppLibTests.SessionStoreTests/resolvePermissionScopedToNamedSession`
Expected: PASS. (The behavior already exists; the test locks it in.)

- [ ] **Step 3: Run the full AppLib suite as a sanity check**

Run: `swift test --filter AppLibTests`
Expected: all green.

- [ ] **Step 4: Commit**

```bash
git add Tests/AppLibTests/SessionStoreTests.swift
git commit -m "test(session): guard resolvePermission session-scoped isolation"
```

---

### Task 2: Session-scoped `approve` / `deny` on `NotchViewModel`

Replace the `primarySession`-only methods on `NotchViewModel` with session-scoped variants that take the target session id. Update the two existing call sites in `NotchExpandedView` to pass `primarySession?.id` so layout stays unchanged — this isolates the API change to one commit.

**Files:**
- Modify: `Sources/AppLib/Notch/NotchViewModel.swift:51-57`
- Modify: `Sources/AppLib/Notch/NotchExpandedView.swift:543,560`

- [ ] **Step 1: Update `NotchViewModel`**

Replace lines 51-57 of `Sources/AppLib/Notch/NotchViewModel.swift`:

```swift
    public func approve(sessionId: String) {
        sessionStore.resolvePermission(sessionId: sessionId, allow: true)
    }

    public func deny(sessionId: String) {
        sessionStore.resolvePermission(sessionId: sessionId, allow: false)
    }
```

(Remove the old parameterless `approve()` and `deny()` entirely. No other callers reference them — verified via grep across `Sources/`.)

- [ ] **Step 2: Update call sites in `NotchExpandedView.swift`**

In `permissionApprovalButtons` (around line 541), change:

```swift
            Button(action: { viewModel.deny() }) {
```

to:

```swift
            Button(action: {
                if let id = viewModel.primarySession?.id { viewModel.deny(sessionId: id) }
            }) {
```

and change:

```swift
            Button(action: { viewModel.approve() }) {
```

to:

```swift
            Button(action: {
                if let id = viewModel.primarySession?.id { viewModel.approve(sessionId: id) }
            }) {
```

(These are intermediate call sites — Task 3 rewrites `permissionApprovalButtons` to receive the session directly. Keeping the intermediate form lets this task ship as a clean API-only change.)

- [ ] **Step 3: Build**

Run: `swift build`
Expected: builds clean.

- [ ] **Step 4: Run the test suite**

Run: `swift test`
Expected: all existing tests (including `resolvePermissionAllowReturnsToWorking` which uses `resolvePrimaryPermission`) still pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/AppLib/Notch/NotchViewModel.swift Sources/AppLib/Notch/NotchExpandedView.swift
git commit -m "refactor(notch): session-scoped approve/deny on NotchViewModel"
```

---

### Task 3: Move approval buttons into the session card

Convert `permissionApprovalButtons` (currently a computed `var`) into a function taking `session: SessionInfo` and `isPrimary: Bool`. Gate `.keyboardShortcut` on `isPrimary`. Call it from inside `sessionCardContent` right after `permissionDetailBlock(pending)`. Remove the body-level block.

**Files:**
- Modify: `Sources/AppLib/Notch/NotchExpandedView.swift:27-33` (remove body-level block)
- Modify: `Sources/AppLib/Notch/NotchExpandedView.swift:203-210` (add call inside card)
- Modify: `Sources/AppLib/Notch/NotchExpandedView.swift:541-577` (convert to function)

- [ ] **Step 1: Rewrite `permissionApprovalButtons` as a function**

Replace the entire existing computed property (lines 539-577) in `Sources/AppLib/Notch/NotchExpandedView.swift`:

```swift
    // MARK: - Approval buttons (rendered inside the owning session's card)

    @ViewBuilder
    private func permissionApprovalButtons(sessionId: String, isPrimary: Bool) -> some View {
        HStack(spacing: 8) {
            denyButton(sessionId: sessionId, isPrimary: isPrimary)
            allowButton(sessionId: sessionId, isPrimary: isPrimary)
        }
    }

    @ViewBuilder
    private func denyButton(sessionId: String, isPrimary: Bool) -> some View {
        let base = Button(action: { viewModel.deny(sessionId: sessionId) }) {
            HStack(spacing: 4) {
                Text("Deny")
                if isPrimary {
                    Text("⌘N")
                        .font(.system(size: 8, weight: .regular, design: .monospaced))
                        .opacity(0.6)
                }
            }
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.red)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(Color.red.opacity(0.15))
                .cornerRadius(8)
        }
        .buttonStyle(.plain)

        if isPrimary {
            base.keyboardShortcut("n", modifiers: .command)
        } else {
            base
        }
    }

    @ViewBuilder
    private func allowButton(sessionId: String, isPrimary: Bool) -> some View {
        let base = Button(action: { viewModel.approve(sessionId: sessionId) }) {
            HStack(spacing: 4) {
                Text("Allow Once")
                if isPrimary {
                    Text("⌘Y")
                        .font(.system(size: 8, weight: .regular, design: .monospaced))
                        .opacity(0.6)
                }
            }
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Color(red: 0.31, green: 0.80, blue: 0.77))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(Color(red: 0.31, green: 0.80, blue: 0.77).opacity(0.15))
                .cornerRadius(8)
        }
        .buttonStyle(.plain)

        if isPrimary {
            base.keyboardShortcut("y", modifiers: .command)
        } else {
            base
        }
    }
```

(Splitting into `denyButton` / `allowButton` helpers keeps the conditional `.keyboardShortcut` readable — SwiftUI can't attach a modifier conditionally inline without the `if` branching each whole button.)

- [ ] **Step 2: Call the function inside `sessionCardContent`**

In `Sources/AppLib/Notch/NotchExpandedView.swift`, locate the block around lines 203-210:

```swift
                // Permission request details
                if let pending = session.pendingPermission {
                    if pending.isAskUserQuestion {
                        askUserQuestionBlock(session: session, pending: pending)
                    } else {
                        permissionDetailBlock(pending)
                    }
                }
```

Replace with:

```swift
                // Permission request details + approval buttons (regular PermissionRequest only).
                // AskUserQuestion renders its own block with a terminal CTA footer.
                if let pending = session.pendingPermission {
                    if pending.isAskUserQuestion {
                        askUserQuestionBlock(session: session, pending: pending)
                    } else {
                        permissionDetailBlock(pending)
                        permissionApprovalButtons(
                            sessionId: session.id,
                            isPrimary: viewModel.primarySession?.id == session.id
                        )
                        .padding(.top, 4)
                    }
                }
```

- [ ] **Step 3: Remove the body-level approval block**

In `Sources/AppLib/Notch/NotchExpandedView.swift`, locate the block around lines 27-33:

```swift
                // If primary session has a regular permission request (not AskUserQuestion),
                // show approval buttons at bottom
                if let primary = viewModel.primarySession,
                   let pending = primary.pendingPermission,
                   !pending.isAskUserQuestion {
                    permissionApprovalButtons
                }
```

Delete those lines entirely. The surrounding structure (the `VStack(spacing: 10) { ForEach(... ) }` ending at line 25 and the `Spacer(minLength: 0)` on line 36) should remain.

- [ ] **Step 4: Build**

Run: `swift build`
Expected: builds clean. If the compiler complains about the old `permissionApprovalButtons` computed property still being referenced, re-check Step 3 removed the call.

- [ ] **Step 5: Run the full test suite**

Run: `swift test`
Expected: all green.

- [ ] **Step 6: Commit**

```bash
git add Sources/AppLib/Notch/NotchExpandedView.swift
git commit -m "feat(notch): move permission buttons into each pending session card"
```

---

### Task 4: Manual smoke test via bridge stdin

SwiftUI layout can't be unit-tested meaningfully for this change — verify by driving a `PermissionRequest` hook through the real bridge binary and inspecting the notch panel. The bridge manual-test recipe is in `CLAUDE.md`.

**Files:**
- (None — runtime verification only)

- [ ] **Step 1: Build and launch the app**

Run: `make app && open .build/ZackEyes.app`
Expected: app launches, menu-bar icon appears, notch is idle.

- [ ] **Step 2: Simulate a single-session permission request**

The bridge routes on the `--event` CLI arg and injects `_bridge_event` into the JSON (see `Sources/Bridge/main.swift:53-65`). The app-side handler (`AppDelegate.swift:300-320`) reads `session_id`, `cwd`, `tool_name`, `tool_input` from the stdin JSON. `PermissionRequest` is blocking — the bridge waits on stdout for the response, so background the invocation.

In a terminal, run:

```bash
BRIDGE_BIN="$(swift build --show-bin-path)/bridge"
echo '{"hook_event_name":"SessionStart","session_id":"smoke-1","cwd":"/tmp","transcript_path":"/tmp/smoke-1.jsonl"}' \
  | "$BRIDGE_BIN" --event SessionStart
echo '{"hook_event_name":"PreToolUse","session_id":"smoke-1","cwd":"/tmp","tool_name":"Bash","tool_input":{"command":"echo hi"}}' \
  | "$BRIDGE_BIN" --event PermissionRequest &
BRIDGE_PID=$!
```

Expected:
- Notch panel expands showing the session card for `smoke-1` with `PERMISSION REQUEST` orange block inside
- `Deny ⌘N` and `Allow Once ⌘Y` buttons appear **inside the session card's rounded background**, directly below the permission detail — not at the bottom of the panel
- Background bridge process is waiting on stdout

- [ ] **Step 3: Verify hotkey + click both work**

Click `Allow Once` (or press `⌘Y`). Expected: buttons disappear, session returns to working state, bridge PID `$BRIDGE_PID` exits with code 0 (check with `wait $BRIDGE_PID; echo $?`).

- [ ] **Step 4: Simulate two concurrent pending sessions**

```bash
echo '{"hook_event_name":"SessionStart","session_id":"smoke-A","cwd":"/tmp/a","transcript_path":"/tmp/smoke-A.jsonl"}' \
  | "$BRIDGE_BIN" --event SessionStart
echo '{"hook_event_name":"SessionStart","session_id":"smoke-B","cwd":"/tmp/b","transcript_path":"/tmp/smoke-B.jsonl"}' \
  | "$BRIDGE_BIN" --event SessionStart
echo '{"hook_event_name":"PreToolUse","session_id":"smoke-A","cwd":"/tmp/a","tool_name":"Bash","tool_input":{"command":"a"}}' \
  | "$BRIDGE_BIN" --event PermissionRequest &
PID_A=$!
echo '{"hook_event_name":"PreToolUse","session_id":"smoke-B","cwd":"/tmp/b","tool_name":"Write","tool_input":{"file_path":"/tmp/x"}}' \
  | "$BRIDGE_BIN" --event PermissionRequest &
PID_B=$!
```

Expected:
- Two session cards visible, each with its own `Deny` / `Allow Once` buttons inside its card
- Only **one** card (the primary — whichever came first) shows the `⌘N` / `⌘Y` hint text next to the button labels
- Clicking `Allow Once` inside card A resolves only A; B remains pending with its buttons intact
- Clicking `Deny` inside card B then resolves B independently

- [ ] **Step 5: Verify both bridge processes exit cleanly**

```bash
wait $PID_A; echo "A exit: $?"
wait $PID_B; echo "B exit: $?"
```

Expected: both exit `0`.

- [ ] **Step 6: Document the verification**

If all steps passed, append a one-line note to the PR description (or commit message of the next change) confirming manual verification covered single + multi pending cases. If anything failed, open a follow-up issue — do not patch-over in this plan.

---

## Completion

After Task 4 passes, the implementation is done. No further commits required. The branch is ready for a PR against `master`.
