# Welcome Onboarding Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Per-version first-launch welcome animation: expanded notch panel opens, shows PixelAvatar + title/subtitle, plays theme chime, auto-collapses after 3 seconds. Fires once per bundle version; both real-notch and simulated-notch surfaces share the same overlay.

**Architecture:** A `@Published var welcomeVisible` on the shared `NotchViewModel` drives a SwiftUI overlay rendered inside the existing expanded views on both surfaces. A tiny pure-function `WelcomeTrigger` handles the `UserDefaults` version check. `AppDelegate.maybeShowWelcome()` coordinates: flag on → `forceUiExpand()` → play chime → 3s sleep → flag off → mark version. No new NSPanel, no new controller.

**Tech Stack:** Swift 6, SwiftUI, AppKit, `UserDefaults`, existing `NotificationManager.playThemeSound()` (to be exposed via `playChime()`), existing `NotchViewModel` / `AppDelegate.forceUiExpand()`. Tests use swift-testing (`import Testing`) matching `SessionStoreTests`.

**Spec reference:** `docs/superpowers/specs/2026-04-19-welcome-onboarding-design.md`

**File map:**

| Action | Path | Responsibility |
|---|---|---|
| Create | `Sources/AppLib/Onboarding/WelcomeTrigger.swift` | Pure version-compare + mark-shown logic. Takes `UserDefaults` + version string as parameters |
| Create | `Sources/AppLib/Onboarding/WelcomeOverlay.swift` | SwiftUI view: PixelAvatar (bump animation) + title + subtitle |
| Create | `Tests/AppLibTests/WelcomeTriggerTests.swift` | 5 tests covering the version-compare matrix |
| Modify | `Sources/AppLib/Notch/NotchViewModel.swift` | Add `@Published var welcomeVisible: Bool = false` |
| Modify | `Sources/AppLib/Notifications/NotificationManager.swift` | Add `public func playChime()` wrapper around private `playThemeSound()` |
| Modify | `Sources/AppLib/Notch/NotchExpandedView.swift` | Top-level conditional overlay on `welcomeVisible` |
| Modify | `Sources/AppLib/SimulatedNotch/SimulatedNotchFullView.swift` | Top-level conditional overlay on `welcomeVisible` |
| Modify | `Sources/ZackEyes/AppDelegate.swift` | Add `maybeShowWelcome()` + call at end of `applicationDidFinishLaunching` |

---

### Task 1: WelcomeTrigger — pure logic + tests

**Files:**
- Create: `Sources/AppLib/Onboarding/WelcomeTrigger.swift`
- Create: `Tests/AppLibTests/WelcomeTriggerTests.swift`

- [ ] **Step 1: Create the `Onboarding` directory**

Run:
```bash
mkdir -p Sources/AppLib/Onboarding
```

- [ ] **Step 2: Write the failing test file**

Write `Tests/AppLibTests/WelcomeTriggerTests.swift`:

```swift
import Testing
import Foundation
@testable import AppLib

struct WelcomeTriggerTests {
    // Each test uses a uniquely-named suite so tests don't share state and
    // don't touch the user's real defaults.
    private func defaults(_ suite: String) -> UserDefaults {
        let d = UserDefaults(suiteName: "WelcomeTriggerTests.\(suite)")!
        d.removePersistentDomain(forName: "WelcomeTriggerTests.\(suite)")
        return d
    }

    @Test func firesWhenNoVersionStored() {
        let d = defaults(#function)
        #expect(WelcomeTrigger.shouldShowWelcome(defaults: d, currentVersion: "1.0.0") == true)
    }

    @Test func firesWhenStoredVersionDiffers() {
        let d = defaults(#function)
        d.set("0.9.0", forKey: "welcomeShownForVersion")
        #expect(WelcomeTrigger.shouldShowWelcome(defaults: d, currentVersion: "1.0.0") == true)
    }

    @Test func skipsWhenStoredVersionMatches() {
        let d = defaults(#function)
        d.set("1.0.0", forKey: "welcomeShownForVersion")
        #expect(WelcomeTrigger.shouldShowWelcome(defaults: d, currentVersion: "1.0.0") == false)
    }

    @Test func skipsWhenCurrentVersionNil() {
        let d = defaults(#function)
        #expect(WelcomeTrigger.shouldShowWelcome(defaults: d, currentVersion: nil) == false)
    }

    @Test func markShownPersistsVersion() {
        let d = defaults(#function)
        WelcomeTrigger.markShown(defaults: d, currentVersion: "1.2.3")
        #expect(d.string(forKey: "welcomeShownForVersion") == "1.2.3")
        #expect(WelcomeTrigger.shouldShowWelcome(defaults: d, currentVersion: "1.2.3") == false)
    }

    @Test func markShownWithNilVersionIsNoop() {
        let d = defaults(#function)
        d.set("0.9.0", forKey: "welcomeShownForVersion")
        WelcomeTrigger.markShown(defaults: d, currentVersion: nil)
        #expect(d.string(forKey: "welcomeShownForVersion") == "0.9.0")
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `swift test --filter WelcomeTriggerTests`

Expected: Compilation error — `cannot find 'WelcomeTrigger' in scope`.

- [ ] **Step 4: Implement `WelcomeTrigger`**

Write `Sources/AppLib/Onboarding/WelcomeTrigger.swift`:

```swift
import Foundation

/// Pure logic for the first-launch welcome animation gating. Driven by the
/// app's `CFBundleShortVersionString`: fires once per version, persisted via
/// `UserDefaults`.
///
/// Injecting `UserDefaults` and the version string (rather than reading
/// `Bundle.main` directly) keeps this type unit-testable without touching
/// the user's real defaults.
public enum WelcomeTrigger {
    /// Key used in `UserDefaults` to persist the last version that played
    /// the welcome animation. Exposed so tests can read/write directly.
    public static let storageKey = "welcomeShownForVersion"

    /// Returns true when the welcome animation should play on this launch.
    /// - An unreadable bundle version (`nil`) is treated as "already shown"
    ///   so a degraded startup path never spams the user.
    public static func shouldShowWelcome(
        defaults: UserDefaults,
        currentVersion: String?
    ) -> Bool {
        guard let currentVersion else { return false }
        let stored = defaults.string(forKey: storageKey)
        return stored != currentVersion
    }

    /// Writes the current version to `UserDefaults` so future launches skip
    /// the welcome until the bundle version changes again. Nil is a no-op.
    public static func markShown(
        defaults: UserDefaults,
        currentVersion: String?
    ) {
        guard let currentVersion else { return }
        defaults.set(currentVersion, forKey: storageKey)
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter WelcomeTriggerTests`

Expected: 6 tests pass (`firesWhenNoVersionStored`, `firesWhenStoredVersionDiffers`, `skipsWhenStoredVersionMatches`, `skipsWhenCurrentVersionNil`, `markShownPersistsVersion`, `markShownWithNilVersionIsNoop`).

- [ ] **Step 6: Commit**

```bash
git add Sources/AppLib/Onboarding/WelcomeTrigger.swift Tests/AppLibTests/WelcomeTriggerTests.swift
git commit -m "feat(welcome): WelcomeTrigger version-compare logic"
```

---

### Task 2: Expose `NotificationManager.playChime()`

**Files:**
- Modify: `Sources/AppLib/Notifications/NotificationManager.swift:29`

- [ ] **Step 1: Add the public wrapper**

The existing `private func playThemeSound() -> Bool` at line 29 already does the right thing (respects user's theme, honors `"none"` silence). Expose a void public wrapper.

Find this block (around line 29):
```swift
    /// Load and play the selected notification sound for the current theme.
    /// Returns true if a custom sound was played; false means the caller
    /// should fall back to the system notification sound.
    private func playThemeSound() -> Bool {
```

Add immediately above it:
```swift
    /// Fire-and-forget chime for UI moments like the welcome onboarding.
    /// Respects the user's theme sound choice and the "none" silence
    /// preference. Callers that need a fallback system sound when the
    /// theme is unavailable should use `playThemeSound()` directly.
    public func playChime() {
        _ = playThemeSound()
    }

```

- [ ] **Step 2: Verify build**

Run: `swift build`

Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Sources/AppLib/Notifications/NotificationManager.swift
git commit -m "feat(notifications): expose playChime() public wrapper"
```

---

### Task 3: Add `welcomeVisible` flag on `NotchViewModel`

**Files:**
- Modify: `Sources/AppLib/Notch/NotchViewModel.swift:9`

- [ ] **Step 1: Add the flag**

Find line 9 in `Sources/AppLib/Notch/NotchViewModel.swift`:
```swift
    @Published public var panelState: PanelState = .compact
```

Replace with:
```swift
    @Published public var panelState: PanelState = .compact
    /// Drives the first-launch welcome overlay rendered by `NotchExpandedView`
    /// and `SimulatedNotchFullView`. Toggled by `AppDelegate.maybeShowWelcome()`.
    @Published public var welcomeVisible: Bool = false
```

- [ ] **Step 2: Verify build**

Run: `swift build`

Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Sources/AppLib/Notch/NotchViewModel.swift
git commit -m "feat(welcome): welcomeVisible flag on NotchViewModel"
```

---

### Task 4: Create `WelcomeOverlay` SwiftUI view

**Files:**
- Create: `Sources/AppLib/Onboarding/WelcomeOverlay.swift`

- [ ] **Step 1: Write the overlay view**

Write `Sources/AppLib/Onboarding/WelcomeOverlay.swift`:

```swift
import SwiftUI

/// First-launch welcome. Rendered on top of the expanded notch content when
/// `NotchViewModel.welcomeVisible == true`. Layout: horizontal pill — left
/// PixelAvatar bumps in; right title + subtitle fades in. No interaction;
/// auto-dismissed after 3s by `AppDelegate.maybeShowWelcome()`.
struct WelcomeOverlay: View {
    @State private var avatarScale: CGFloat = 0.0
    @State private var textOpacity: Double = 0.0

    var body: some View {
        HStack(spacing: 16) {
            PixelAvatar(seed: "zackeyes-welcome", size: 56)
                .scaleEffect(avatarScale)

            VStack(alignment: .leading, spacing: 4) {
                Text("Welcome to ZackEyes")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                Text("I live in your notch. Hover here to see me.")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.75))
            }
            .opacity(textOpacity)

            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .onAppear {
            // Spring bump: 0 → 1.15 → 1.0 over 0.40s.
            withAnimation(.spring(response: 0.40, dampingFraction: 0.55)) {
                avatarScale = 1.0
            }
            // Text fades in 0.10s after avatar starts so the bump lands first.
            withAnimation(.easeOut(duration: 0.30).delay(0.10)) {
                textOpacity = 1.0
            }
        }
    }
}
```

- [ ] **Step 2: Verify build**

Run: `swift build`

Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Sources/AppLib/Onboarding/WelcomeOverlay.swift
git commit -m "feat(welcome): WelcomeOverlay SwiftUI view"
```

---

### Task 5: Wire overlay into `NotchExpandedView` (real notch)

**Files:**
- Modify: `Sources/AppLib/Notch/NotchExpandedView.swift:14-38`

- [ ] **Step 1: Wrap the body in a conditional**

Find the existing `body` (lines 14–38):
```swift
    var body: some View {
        let theme = currentTheme
        VStack(alignment: .leading, spacing: 12) {
            if viewModel.sessionStore.sessions.isEmpty {
                emptyState
            } else {
                // List all sessions (most recent first)
                VStack(spacing: 10) {
                    ForEach(viewModel.sessionStore.orderedSessions, id: \.id) { session in
                        sessionCard(session, theme: theme)
                    }
                }

            }

            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .onReceive(durationTimer) { now in
            tick = now
        }
    }
```

Replace with:
```swift
    var body: some View {
        if viewModel.welcomeVisible {
            WelcomeOverlay()
        } else {
            normalBody
        }
    }

    private var normalBody: some View {
        let theme = currentTheme
        return VStack(alignment: .leading, spacing: 12) {
            if viewModel.sessionStore.sessions.isEmpty {
                emptyState
            } else {
                // List all sessions (most recent first)
                VStack(spacing: 10) {
                    ForEach(viewModel.sessionStore.orderedSessions, id: \.id) { session in
                        sessionCard(session, theme: theme)
                    }
                }

            }

            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .onReceive(durationTimer) { now in
            tick = now
        }
    }
```

Note: the `normalBody` computed property needs `return` before `VStack` because the `let theme = currentTheme` line makes it a multi-statement closure; computed properties require an explicit `return` when they contain statements other than the final expression.

- [ ] **Step 2: Verify build**

Run: `swift build`

Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Sources/AppLib/Notch/NotchExpandedView.swift
git commit -m "feat(welcome): render WelcomeOverlay in NotchExpandedView"
```

---

### Task 6: Wire overlay into `SimulatedNotchFullView` (notchless Macs)

**Files:**
- Modify: `Sources/AppLib/SimulatedNotch/SimulatedNotchFullView.swift:21-40`

- [ ] **Step 1: Wrap the body in a conditional**

Find the existing `body` (lines 21–40):
```swift
    var body: some View {
        VStack(spacing: 0) {
            usageHeader
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 10)

            Divider()
                .background(Color.white.opacity(0.08))

            ScrollView(.vertical, showsIndicators: false) {
                NotchExpandedView(viewModel: viewModel)
                    .background(Color.clear)
            }
        }
        .background(NotchShape(cornerRadius: cornerRadius).fill(Color.black))
        .clipShape(NotchShape(cornerRadius: cornerRadius))
        .overlay(aboutOverlay)
        .overlay(hotkeyRecorderOverlay)
    }
```

Replace with:
```swift
    var body: some View {
        if viewModel.welcomeVisible {
            WelcomeOverlay()
                .background(NotchShape(cornerRadius: cornerRadius).fill(Color.black))
                .clipShape(NotchShape(cornerRadius: cornerRadius))
        } else {
            normalBody
        }
    }

    private var normalBody: some View {
        VStack(spacing: 0) {
            usageHeader
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 10)

            Divider()
                .background(Color.white.opacity(0.08))

            ScrollView(.vertical, showsIndicators: false) {
                NotchExpandedView(viewModel: viewModel)
                    .background(Color.clear)
            }
        }
        .background(NotchShape(cornerRadius: cornerRadius).fill(Color.black))
        .clipShape(NotchShape(cornerRadius: cornerRadius))
        .overlay(aboutOverlay)
        .overlay(hotkeyRecorderOverlay)
    }
```

- [ ] **Step 2: Verify build**

Run: `swift build`

Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Sources/AppLib/SimulatedNotch/SimulatedNotchFullView.swift
git commit -m "feat(welcome): render WelcomeOverlay in SimulatedNotchFullView"
```

---

### Task 7: Wire trigger in `AppDelegate`

**Files:**
- Modify: `Sources/ZackEyes/AppDelegate.swift:19-209` (append to `applicationDidFinishLaunching` and add private method)

- [ ] **Step 1: Add trigger call at the end of `applicationDidFinishLaunching`**

Find the closing brace of `applicationDidFinishLaunching` (around line 209):
```swift
        // 7. Periodic liveness sweep — every 60s, drop sessions whose cwd
        //    no longer matches any running `claude` process. Catches hard
        //    terminal closes, crashes, and any session whose claude exited
        //    without firing SessionEnd. Cross-references against `ps` so
        //    a transient sh wrapper around the bridge can't false-positive.
        livenessSweepTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.runLivenessSweep() }
        }
    }
```

Replace with:
```swift
        // 7. Periodic liveness sweep — every 60s, drop sessions whose cwd
        //    no longer matches any running `claude` process. Catches hard
        //    terminal closes, crashes, and any session whose claude exited
        //    without firing SessionEnd. Cross-references against `ps` so
        //    a transient sh wrapper around the bridge can't false-positive.
        livenessSweepTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.runLivenessSweep() }
        }

        // 8. First-launch welcome — per-version one-shot. Runs last so the
        //    notch controllers are already created and reachable via
        //    forceUiExpand().
        maybeShowWelcome()
    }
```

- [ ] **Step 2: Add the `maybeShowWelcome()` method**

Find the private `forceUiExpand()` method (around line 400). Add this method immediately above it:

```swift
    /// First-launch onboarding: expand the notch panel, render the welcome
    /// overlay, play the theme chime, auto-collapse after 3 seconds. Fires
    /// once per bundle version; no-op on subsequent launches.
    private func maybeShowWelcome() {
        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        guard WelcomeTrigger.shouldShowWelcome(
            defaults: .standard,
            currentVersion: currentVersion
        ) else { return }

        viewModel.welcomeVisible = true
        forceUiExpand()
        NotificationManager.shared.playChime()

        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self else { return }
            self.viewModel.welcomeVisible = false
            WelcomeTrigger.markShown(defaults: .standard, currentVersion: currentVersion)
        }
    }

```

- [ ] **Step 3: Verify build**

Run: `swift build`

Expected: Build succeeds.

- [ ] **Step 4: Run the full test suite**

Run: `swift test`

Expected: all tests pass (existing + new `WelcomeTriggerTests`).

- [ ] **Step 5: Commit**

```bash
git add Sources/ZackEyes/AppDelegate.swift
git commit -m "feat(welcome): wire maybeShowWelcome() in AppDelegate"
```

---

### Task 8: Manual verification

**Files:**
- None (runtime verification of the assembled feature).

- [ ] **Step 1: Clear the version marker so the welcome fires on next launch**

Run:
```bash
defaults delete com.zackeyes.ZackEyes welcomeShownForVersion 2>/dev/null || true
```

(If the bundle identifier differs, adjust accordingly — check `Resources/Info.plist` for `CFBundleIdentifier`.)

- [ ] **Step 2: Build and launch the app**

Run:
```bash
make run
```

Expected:
1. The notch panel expands automatically within ~1 second of launch.
2. The overlay shows the PixelAvatar bumping in from scale 0 → 1.15 → 1.0.
3. Title "Welcome to ZackEyes" and subtitle "I live in your notch. Hover here to see me." fade in shortly after.
4. The theme chime plays once (assuming the user has not set the sound to "none").
5. After ~3 seconds, the overlay disappears; the normal expanded content becomes visible. The notch then auto-collapses to compact once the mouse leaves.

- [ ] **Step 3: Quit and relaunch — verify welcome does NOT replay**

Quit the app (`⌘Q` via menu-bar icon), then launch again with `make run`.

Expected: No overlay. No chime. The notch behaves normally (compact on startup; expand on hover only).

- [ ] **Step 4: Simulate a version upgrade — verify welcome replays**

Run:
```bash
defaults write com.zackeyes.ZackEyes welcomeShownForVersion "0.0.0"
```

Relaunch with `make run`.

Expected: Overlay replays exactly as in Step 2.

- [ ] **Step 5: No commit for manual verification**

This task has no file changes to commit. If the manual test surfaces a bug, fix it in place with a new commit.

---

## Self-Review

Spec coverage check (against `docs/superpowers/specs/2026-04-19-welcome-onboarding-design.md`):

- [x] Trigger rule (per-bundle-version, `welcomeShownForVersion`, nil version = skip) → Task 1 + Task 7
- [x] Per-version decision stored via `UserDefaults.standard` → Task 1 (key), Task 7 (call sites)
- [x] Content: PixelAvatar + title + subtitle with bump + fade → Task 4
- [x] Sound: `NotificationManager.playThemeSound()` with "none" respected → Task 2 (public wrapper), Task 7 (invocation)
- [x] Duration: 3s auto-collapse, no early dismiss → Task 7 (Task.sleep 3s, no interaction surface)
- [x] Surfaces: real notch + simulated notch, menu-bar skipped → Task 5 + Task 6 (menu-bar popover doesn't render either overlay and isn't part of `forceUiExpand()`'s overlay targets)
- [x] `NotchViewModel.welcomeVisible` flag → Task 3
- [x] `AppDelegate.maybeShowWelcome()` coordination → Task 7
- [x] Edge: CFBundleShortVersionString missing → treated as "already shown" → Task 1 test `skipsWhenCurrentVersionNil` + Task 7 code path
- [x] Edge: PermissionRequest during welcome → no mutex; stickyOpen keeps panel open → Task 7 (no mutex logic; relies on existing SessionStore)
- [x] Edge: User quits at t=1s → welcome replays next launch → Task 7 `markShown()` is inside the post-sleep block
- [x] Testing: unit-test WelcomeTrigger only → Task 1 covers 6 cases
- [x] No new NSPanel → Tasks 4–6 all use existing panel hosts

Placeholder scan: no TBDs, no "similar to Task N" references, every code step has the code inline, every command has expected output.

Type consistency:
- `WelcomeTrigger.shouldShowWelcome(defaults:currentVersion:)` — used consistently in test (Task 1), AppDelegate (Task 7).
- `WelcomeTrigger.markShown(defaults:currentVersion:)` — used consistently.
- `WelcomeTrigger.storageKey` — `"welcomeShownForVersion"` matches Task 8 `defaults write` command.
- `NotificationManager.shared.playChime()` — added in Task 2, called in Task 7.
- `viewModel.welcomeVisible` — added in Task 3, read in Tasks 5, 6, 7.
- `WelcomeOverlay()` — created in Task 4, rendered in Tasks 5 and 6.

No gaps found.
