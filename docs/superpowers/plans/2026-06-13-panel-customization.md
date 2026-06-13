# Notch Customization — Lean Slice (#48) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `.whenActive` notch visibility (auto-hide when there are no sessions, auto-show when any appears) and fill the two remaining right-click-menu gaps from #48 (direct "Repair Hooks" + "Check for Updates") — both menu surfaces. Scoped lean per the project's "复杂度需要证明" rule: alignment offset and most of the context menu already exist; follow-keyboard-focus and panel-size live-preview are deliberately cut.

**Architecture:** `NotchVisibility` gains a third case `.whenActive`. ConfigStore already persists visibility as a raw string, so persistence is free. Both panel controllers' `applyVisibility` learn the new case by reading their existing `viewModel.sessionStore.sessions` (non-empty ⇒ show, empty ⇒ hide-unless-expanded). AppDelegate re-evaluates on the session-count 0↔non-0 boundary (tracked to avoid flicker) via the `objectWillChange` it can subscribe to. The binary "Show Dynamic Island" checkbox in each menu becomes a 3-item radio submenu. "Repair Hooks" calls the existing `HookRepair.run`; "Check for Updates" calls a new public `UpdateChecker.checkNow()` that reuses the existing publish→notification→red-dot path (no new "up to date" UI — consistent with the app's current update model).

**Branch:** `feat/48-panel-customization` off `f8b6fe6` (worktree, baseline 291 green).

**Invariants in blast radius:** NSPanel non-activating / click-through / `canBecomeMain=false` must stay intact (we only call `orderOut`/`orderFrontRegardless`, never restyle). `.whenActive` must NOT suppress event-driven `forceUiExpand` (PermissionRequest/errors always show — and they always coincide with a session existing, so they're compatible). ConfigStore corrupt-file-don't-clobber contract unchanged.

---

## File Structure

| File | Action | Responsibility |
|------|--------|----------------|
| `Sources/AppLib/Config/NotchVisibility.swift` | Modify | add `.whenActive` case + doc |
| `Sources/AppLib/SimulatedNotch/SimulatedNotchController.swift` | Modify | `applyVisibility` handles `.whenActive` |
| `Sources/AppLib/Notch/NotchWindowController.swift` | Modify | same |
| `Sources/ZackEyes/AppDelegate.swift` | Modify | session-boundary re-apply for `.whenActive` |
| `Sources/AppLib/Update/UpdateChecker.swift` | Modify | public `checkNow()` |
| `Sources/AppLib/MenuBar/StatusBarMenu.swift` | Modify | visibility submenu + Repair Hooks + Check for Updates |
| `Sources/AppLib/SimulatedNotch/GearMenuTarget.swift` | Modify | handlers: `visibilityClicked`, `repairHooksClicked`, `checkUpdatesClicked` |
| `Sources/AppLib/SimulatedNotch/SimulatedNotchFullView.swift` | Modify | gear visibility submenu + 2 items |
| `Tests/AppLibTests/ConfigStoreTests.swift` | Modify | `.whenActive` round-trip + default tests |
| `Tests/AppLibTests/NotchVisibilityTests.swift` | Create (if no existing home) | rawValue stability |
| `ARCHITECTURE.md` | Modify | visibility tri-state note |

---

### Task 1: `.whenActive` enum + persistence test

**Files:** `NotchVisibility.swift`; `Tests/AppLibTests/ConfigStoreTests.swift` (append — read its fixture style first).

- [ ] **Step 1.1 failing tests** — append to ConfigStoreTests (mirror existing visibility tests; if none exist, mirror another round-trip test in the file, using its tmp-config pattern):

```swift
    // MARK: - #48 whenActive visibility

    @Test func whenActiveVisibilityRoundTrips() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let store = ConfigStore(directory: tmpDir.path)   // match the real init signature
        store.saveNotchVisibility(.whenActive)
        #expect(store.loadNotchVisibility() == .whenActive)
    }

    @Test func unknownVisibilityRawFallsBackToAlways() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let configURL = tmpDir.appendingPathComponent("config.json")
        try #"{"notchVisibility":"bogus"}"#
            .write(to: configURL, atomically: true, encoding: .utf8)
        let store = ConfigStore(directory: tmpDir.path)
        #expect(store.loadNotchVisibility() == .always)
    }
```

⚠️ VERIFY ConfigStore's real init signature first (it may take `configPath:` or `directory:` — read the file). Adapt the fixture construction to match; keep the assertions. If ConfigStoreTests already has a `makeTmpDir`/config helper, reuse it verbatim.

- [ ] **Step 1.2** run → `whenActiveVisibilityRoundTrips` FAILs to compile (`.whenActive` undefined). Confirm.

- [ ] **Step 1.3 implement** — `NotchVisibility.swift`:

```swift
public enum NotchVisibility: String, Codable, Sendable {
    case always      // Default: compact pill always visible
    case whenActive  // Visible only while ≥1 session exists; auto-hides when empty (#48)
    case hidden      // Panel off-screen unless recalled by hotkey / menu / event
}
```
Extend the type doc comment to mention the tri-state and that `.whenActive` still yields to `forceUiExpand` (events/permissions always show).

- [ ] **Step 1.4** `swift test 2>&1 | tail -3` → 293 pass (291 + 2). The string-rawValue persistence needs no ConfigStore code change — confirm both tests green.

- [ ] **Step 1.5 commit** `feat(notch): add .whenActive visibility case`

---

### Task 2: controllers honor `.whenActive` + AppDelegate boundary re-apply

**Files:** both controllers + AppDelegate. (Panel ordering is AppKit-thin → no unit tests, per project convention; logic is exercised manually + by the enum/config tests.)

- [ ] **Step 2.1 — SimulatedNotchController.applyVisibility** (currently lines 587-595). Replace body:

```swift
    public func applyVisibility(_ v: NotchVisibility) {
        visibility = v
        guard let panel = panel else { return }
        let shouldShow: Bool
        switch v {
        case .always:     shouldShow = true
        case .hidden:     shouldShow = false
        case .whenActive: shouldShow = !viewModel.sessionStore.sessions.isEmpty
        }
        if !shouldShow && mode != .full {
            panel.orderOut(nil)
        } else if shouldShow && !panel.isVisible {
            panel.orderFrontRegardless()
        }
    }
```

- [ ] **Step 2.2 — NotchWindowController.applyVisibility** (lines 107-115). Same shape, using its `currentState != .expanded` guard instead of `mode != .full`:

```swift
    public func applyVisibility(_ v: NotchVisibility) {
        visibility = v
        guard let panel = panel else { return }
        let shouldShow: Bool
        switch v {
        case .always:     shouldShow = true
        case .hidden:     shouldShow = false
        case .whenActive: shouldShow = !viewModel.sessionStore.sessions.isEmpty
        }
        if !shouldShow && currentState != .expanded {
            panel.orderOut(nil)
        } else if shouldShow && !panel.isVisible {
            panel.orderFrontRegardless()
        }
    }
```

VERIFY both controllers expose `viewModel` as a stored property (SimulatedNotchController: confirmed `private let viewModel` at :15; NotchWindowController: confirm it holds one — if the property name differs, adapt).

- [ ] **Step 2.3 — AppDelegate session-boundary re-apply.** Add a stored property near the other AppDelegate state:

```swift
    /// #48 — tracks whether the store had any sessions last time we
    /// re-evaluated `.whenActive` visibility, so we only order the panel
    /// in/out on the 0↔non-0 boundary (not on every field mutation).
    private var lastHadSessionsForVisibility = false
```

In `applicationDidFinishLaunching`, after the controllers are created and the visibility-change observer is registered (near AppDelegate.swift:202-221), subscribe to session changes:

```swift
        // #48 — when visibility is .whenActive, show/hide the panel as
        // sessions come and go. Only act on the empty↔non-empty boundary to
        // avoid ordering the window on every event-field mutation.
        sessionStore.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                guard ConfigStore().loadNotchVisibility() == .whenActive else { return }
                let hasSessions = !self.sessionStore.sessions.isEmpty
                guard hasSessions != self.lastHadSessionsForVisibility else { return }
                self.lastHadSessionsForVisibility = hasSessions
                self.windowController?.applyVisibility(.whenActive)
                self.simulatedNotch?.applyVisibility(.whenActive)
            }
            .store(in: &cancellables)
```

VERIFY: (a) AppDelegate already imports Combine and has a `cancellables` set — if not, add `import Combine` and `private var cancellables = Set<AnyCancellable>()`. (b) `sessionStore.objectWillChange` is accessible (SessionStore is ObservableObject — confirmed via NotchViewModel's subscription). (c) `objectWillChange` fires BEFORE the mutation, so reading `sessions.isEmpty` in the sink sees the pre-change value — for a 0→1 transition the sink fires as the first session is being added and may still read empty. To get the post-change value, hop: wrap the body in `DispatchQueue.main.async { ... }` OR use `.receive(on:)` (already added) which defers delivery to the next runloop tick where the mutation has landed. Confirm `.receive(on: RunLoop.main)` is sufficient; if a 0→1 flip is missed in manual testing, switch to an explicit `DispatchQueue.main.async` inside the sink. Note what you used.

Also: when the user PICKS `.whenActive` from the menu (Task 3), the existing `.notchVisibilityChanged` observer calls `applyVisibility` immediately — seed `lastHadSessionsForVisibility` there too so the first boundary is correct. In the existing `.notchVisibilityChanged` observer (AppDelegate.swift:212-221), after applying, add: `self.lastHadSessionsForVisibility = !self.sessionStore.sessions.isEmpty`.

- [ ] **Step 2.4** `swift build 2>&1 | tail -3` clean; `swift test 2>&1 | tail -3` → 293.

- [ ] **Step 2.5 commit** `feat(notch): auto show/hide panel for .whenActive on session boundary`

---

### Task 3: menu surfaces — visibility submenu + Repair Hooks + Check for Updates

**Files:** `UpdateChecker.swift`, `StatusBarMenu.swift`, `GearMenuTarget.swift`, `SimulatedNotchFullView.swift`.

- [ ] **Step 3.1 — UpdateChecker.checkNow()**. The private `check()` is at :73. Add:

```swift
    /// Manual "Check for Updates" trigger. Runs the same poll as the timer;
    /// results surface through the existing publish path (availableVersion →
    /// onNewVersion notification + menu red-dot). No separate "up to date"
    /// UI — consistent with the app's auto-poll update model.
    public func checkNow() {
        Task { await check() }
    }
```

- [ ] **Step 3.2 — StatusBarMenu visibility submenu.** Replace the single `showIsland` checkable item (StatusBarMenu.swift:84-92) with a submenu builder. Add a private helper:

```swift
    private func visibilitySubmenuItem() -> NSMenuItem {
        let current = ConfigStore().loadNotchVisibility()
        let submenu = NSMenu()
        let options: [(String, NotchVisibility)] = [
            ("Always", .always),
            ("Only When Sessions Active", .whenActive),
            ("Hidden", .hidden),
        ]
        for (title, value) in options {
            let item = NSMenuItem(
                title: title,
                action: #selector(visibilityOptionClicked(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = value.rawValue
            item.state = (value == current) ? .on : .off
            submenu.addItem(item)
        }
        let parent = NSMenuItem(title: "Dynamic Island", action: nil, keyEquivalent: "")
        parent.submenu = submenu
        return parent
    }
```

Replace the old `toggleVisibilityClicked` action with a representedObject-driven one:

```swift
    @objc private func visibilityOptionClicked(_ sender: Any?) {
        guard let item = sender as? NSMenuItem,
              let raw = item.representedObject as? String,
              let v = NotchVisibility(rawValue: raw) else { return }
        let store = ConfigStore()
        store.saveNotchVisibility(v)
        NotificationCenter.default.post(
            name: .notchVisibilityChanged, object: nil,
            userInfo: ["visibility": v]
        )
    }
```

In `build()`, swap `menu.addItem(showIsland)` for `menu.addItem(visibilitySubmenuItem())`. (Remove the now-dead `showIsland` lines and the old `toggleVisibilityClicked` if it has no other callers — grep first; the gear path has its own copy so check before deleting shared symbols.)

- [ ] **Step 3.3 — StatusBarMenu maintenance items.** In the maintenance section (after "Uninstall Integrations…", before the final separator added in #46), add a direct Repair Hooks item and a Check for Updates item. Repair:

```swift
        let repair = NSMenuItem(
            title: "Repair Hooks",
            action: #selector(repairHooksClicked(_:)),
            keyEquivalent: ""
        )
        repair.target = self
        menu.addItem(repair)
```
```swift
    @objc private func repairHooksClicked(_ sender: Any?) {
        Task.detached(priority: .utility) {
            HookRepair.run(appPath: Bundle.main.bundlePath)
        }
    }
```
(Repair runs off-main — unlike the startup path it's a discrete user action; HookRepair is best-effort/silent.)

For "Check for Updates": the menu ALREADY conditionally shows an "Update Available" item when `updateChecker.availableVersion != nil` (StatusBarMenu.swift:34-48). Add a plain "Check for Updates" item (always present) that calls `checkNow()`:

```swift
        let checkUpdates = NSMenuItem(
            title: "Check for Updates",
            action: #selector(checkUpdatesClicked(_:)),
            keyEquivalent: ""
        )
        checkUpdates.target = self
        menu.addItem(checkUpdates)
```
```swift
    @objc private func checkUpdatesClicked(_ sender: Any?) {
        updateChecker.checkNow()
    }
```
Place both in the maintenance block (with Hook Status / Uninstall). Final order:
`… Theme | --- | Hook Status… | Repair Hooks | Uninstall Integrations… | Check for Updates | --- | Quit`.

- [ ] **Step 3.4 — gear menu (GearMenuTarget + SimulatedNotchFullView).** Mirror all three:
  - `GearMenuTarget`: add `@objc func visibilityOptionClicked(_:)` (save + post notification, same as StatusBarMenu's but clearing `modeStore?.isMenuOpen = false` first — match sibling handlers), `@objc func repairHooksClicked(_:)` (clear isMenuOpen, off-main HookRepair.run), `@objc func checkUpdatesClicked(_:)` (clear isMenuOpen; calls `GearMenuTarget.shared`'s injected updateChecker — VERIFY GearMenuTarget has an updateChecker reference; it has `dmgURL`/`releaseURL`/`downloader` injected at :489-493 but maybe not the checker itself — if absent, inject `updateChecker` in `popGearMenu`'s assignment block and store a `weak var updateChecker`). Keep the existing `toggleVisibilityClicked` only if other callers remain; otherwise replace.
  - `SimulatedNotchFullView.popGearMenu`: replace the single `showIsland` item (lines ~393-401) with a `Dynamic Island` submenu built inline (3 radio items targeting `GearMenuTarget.shared` / `visibilityOptionClicked`, representedObject rawValue, checkmark on current). Add `Repair Hooks` + `Check for Updates` items in the maintenance block next to Hook Status / Uninstall.

- [ ] **Step 3.5** `swift build 2>&1 | tail -3` clean; `swift test 2>&1 | tail -3` → 293; `make app 2>&1 | tail -2` builds.

- [ ] **Step 3.6 commit** `feat(menubar): visibility submenu + Repair Hooks + Check for Updates`

---

### Task 4: docs + ship

- [ ] **Step 4.1** ARCHITECTURE.md: update the Simulated Notch / visibility description to note the tri-state (`always` / `whenActive` / `hidden`) and that `.whenActive` auto-shows/hides on the session-empty boundary while still yielding to event-driven expansion. If there's a 双 agent / config table mentioning visibility, sync it. Commit plan + docs: `docs: document .whenActive visibility + menu additions (#48)`.
- [ ] **Step 4.2** Final whole-branch review (range `f8b6fe6..HEAD`).
- [ ] **Step 4.3** Push → PR (`Closes #48`; body: lean-scope rationale — what was built, what was already-done [offset, most of context menu], what was CUT [follow-focus, live-preview panel size] and why; acceptance mapping; note defaults preserve current `.always` behavior). → bot dispositions → **PAUSE for user manual verification** (visibility tri-state switching, auto-hide on last-session-close, panel doesn't flicker, NSPanel click-through intact, the two new menu items) → squash-merge on user OK → #92 tick → memory.

---

## Self-Review Notes

- **Acceptance mapping:** "Defaults preserve current layout/behavior" → `.always` stays the default (loadNotchVisibility returns `.always` on absent/unknown); `.whenActive` is opt-in. "No text overlap/resize jitter" → we only orderOut/orderFrontRegardless, never resize. "NSPanel non-activating/click-through intact" → no styleMask changes. "Tests cover config persistence" → Task 1 round-trip + unknown-fallback.
- **Cut (flag in PR):** follow-keyboard-focus (multi-display, speculative, NSPanel-move risk); panel width/max-height live-preview (jitter risk, marginal value — the panel already auto-sizes). Alignment offset + most of the context menu already shipped.
- **Boundary-flicker guard:** the `lastHadSessionsForVisibility` tracking is the key correctness bit — re-applying on every objectWillChange (fires per event field) would thrash orderOut/orderFront. Test manually: open one session (pill appears), close it (pill hides after liveness sweep), confirm no flicker mid-session.
- **`.receive(on:)` vs pre-mutation read:** objectWillChange fires before the change; `.receive(on: RunLoop.main)` defers the sink to after the mutation lands. If a 0→1 transition is still missed, the fallback is `DispatchQueue.main.async` inside the sink. Implementer notes which proved necessary.
- **Check-for-Updates feedback:** intentionally no "up to date" popup — matches the existing auto-poll model (which also only surfaces on new-version-found). Documented in checkNow()'s comment so it's a conscious choice, not an omission.
