# Quit + About Menu Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a gear-icon dropdown menu to the simulated notch's full panel header with "About ZackEyes…" and "Quit ZackEyes" items. About opens an in-panel SwiftUI overlay card. Quit calls `NSApp.terminate(nil)`. The panel must stay open while the menu or About overlay is interacting (sticky behavior).

**Architecture:** State for the menu/About overlay lives in `NotchModeStore` (already an `ObservableObject` shared between the controller and SwiftUI views). The controller's existing `hasPendingPermission` sticky-collapse exception is generalized to also check `hasInteractiveOverlay = isMenuOpen || isAboutShown`. The About overlay is a SwiftUI `ZStack` overlay layered on top of the existing `SimulatedNotchFullView` content. Quit goes through the standard AppKit termination path — no cleanup hooks needed.

**Tech Stack:** Swift 6, SwiftUI, AppKit (`NSPanel`, `NSApp`), Swift Package Manager. macOS 14+.

**Spec:** [`docs/superpowers/specs/2026-04-07-quit-menu-design.md`](../specs/2026-04-07-quit-menu-design.md)

**Branch:** `style/polish`

**Testing approach:** This project has no automated tests for SwiftUI views (per the spec). Each task ends with `swift build` to verify compilation, plus a manual smoke test at the end of the plan. The existing `swift test` suite (23 tests, all in `BridgeLib`/`Shared`/`AppLib` non-UI code) must continue to pass after every change.

---

## File Structure

| File | Role | Change kind |
|------|------|-------------|
| `Sources/AppLib/SimulatedNotch/SimulatedNotchRoot.swift` | `NotchModeStore` ObservableObject + `SimulatedNotchRoot` SwiftUI root | Modify: add `isMenuOpen`, `isAboutShown`, `hasInteractiveOverlay` to `NotchModeStore`; thread `modeStore` into the `SimulatedNotchFullView` constructor call |
| `Sources/AppLib/SimulatedNotch/SimulatedNotchFullView.swift` | Full panel SwiftUI content (header + session list) | Modify: accept `modeStore` parameter; refactor `usageBar` to accept a trailing view; add gear `Menu` to the 5h row; add About overlay layered on top of the existing `VStack` content |
| `Sources/AppLib/SimulatedNotch/SimulatedNotchController.swift` | NSPanel lifecycle + sticky logic + auto-collapse handlers | Modify: extend `hasPendingPermission` sticky checks to also include `modeStore.hasInteractiveOverlay`; add public `dismissAboutOverlay()` method |
| `Sources/ZackEyes/AppDelegate.swift` | App entry point + bridge event router | Modify: in the `PermissionRequest` case, call `simulatedNotch?.dismissAboutOverlay()` before `forceUiExpand()` |

No new files. No deletions. No changes to: `MenuBarFallback`, `Bridge`, `SocketServer`, `HookInstaller`, `SessionStore`, `SimulatedNotchPanel`, `SimulatedNotchView`, tests.

---

## Task 1: Extend `NotchModeStore` with menu/About state

**Files:**
- Modify: `Sources/AppLib/SimulatedNotch/SimulatedNotchRoot.swift:13-16`

- [ ] **Step 1: Add the new `@Published` properties and the derived getter**

Open `Sources/AppLib/SimulatedNotch/SimulatedNotchRoot.swift` and replace the `NotchModeStore` class definition with:

```swift
/// Holds the current mode in an ObservableObject so the SwiftUI view tree
/// can observe it without the controller swapping `rootView` (which would
/// destroy SwiftUI's animation context and cause a jump).
@MainActor
public final class NotchModeStore: ObservableObject {
    @Published public var mode: NotchMode = .compact

    /// True while the gear-menu dropdown is currently visible. Set by the
    /// SwiftUI Menu's `isPresented` binding.
    @Published public var isMenuOpen: Bool = false

    /// True while the About overlay is shown over the session list.
    @Published public var isAboutShown: Bool = false

    /// Convenience: any interactive overlay that should keep the panel
    /// open. Used by `SimulatedNotchController` to suppress the
    /// auto-collapse on mouse-out and outside-click handlers.
    public var hasInteractiveOverlay: Bool {
        isMenuOpen || isAboutShown
    }
}
```

- [ ] **Step 2: Verify the build is clean**

Run: `swift build`
Expected: `Build complete!` with no errors or warnings.

- [ ] **Step 3: Run the existing test suite to make sure nothing broke**

Run: `swift test`
Expected: `Test run with 23 tests in 3 suites passed`.

- [ ] **Step 4: Commit**

```bash
git add Sources/AppLib/SimulatedNotch/SimulatedNotchRoot.swift
git commit -m "$(cat <<'EOF'
feat(simulated-notch): add isMenuOpen / isAboutShown state to NotchModeStore

Two new @Published flags + a derived hasInteractiveOverlay getter that
SimulatedNotchController will use to suppress auto-collapse while the
gear menu or About overlay is interacting. No behavior change yet —
nothing reads or writes these flags. Wiring comes in subsequent commits.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Thread `modeStore` into `SimulatedNotchFullView`

**Files:**
- Modify: `Sources/AppLib/SimulatedNotch/SimulatedNotchFullView.swift:7-11`
- Modify: `Sources/AppLib/SimulatedNotch/SimulatedNotchRoot.swift:65-72`

`SimulatedNotchFullView` doesn't currently know about `NotchModeStore`. We need to pass it in so the gear menu's `isPresented` and the About overlay's `isAboutShown` bindings can read/write it.

- [ ] **Step 1: Add the `modeStore` parameter to `SimulatedNotchFullView`**

In `Sources/AppLib/SimulatedNotch/SimulatedNotchFullView.swift`, replace the property declarations at the top of the struct with:

```swift
struct SimulatedNotchFullView: View {
    @ObservedObject var viewModel: NotchViewModel
    @ObservedObject var usageTracker: UsageTracker
    @ObservedObject var modeStore: NotchModeStore
    var cornerRadius: CGFloat = 22
```

- [ ] **Step 2: Update the call site in `SimulatedNotchRoot` to pass `modeStore`**

In `Sources/AppLib/SimulatedNotch/SimulatedNotchRoot.swift`, find the `SimulatedNotchFullView(...)` call inside the `.overlay(alignment: .top)` block and add the `modeStore` parameter:

```swift
.overlay(alignment: .top) {
    SimulatedNotchFullView(
        viewModel: viewModel,
        usageTracker: usageTracker,
        modeStore: modeStore,
        cornerRadius: 22
    )
    .frame(width: fullWidth, height: fullHeight)
    .opacity(isFull ? 1 : 0)
    .scaleEffect(isFull ? 1 : 0.85, anchor: .top)
    .allowsHitTesting(isFull)
}
```

- [ ] **Step 3: Verify the build**

Run: `swift build`
Expected: `Build complete!` with no errors.

- [ ] **Step 4: Run tests**

Run: `swift test`
Expected: `Test run with 23 tests in 3 suites passed`.

- [ ] **Step 5: Commit**

```bash
git add Sources/AppLib/SimulatedNotch/SimulatedNotchFullView.swift Sources/AppLib/SimulatedNotch/SimulatedNotchRoot.swift
git commit -m "$(cat <<'EOF'
refactor(simulated-notch): thread NotchModeStore into SimulatedNotchFullView

Plumbing for the upcoming gear menu and About overlay — both need to
read/write isMenuOpen and isAboutShown on the shared modeStore. No
visible behavior change.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Add the gear menu to the 5h row

**Files:**
- Modify: `Sources/AppLib/SimulatedNotch/SimulatedNotchFullView.swift`

The 5h row's existing `usageBar(label:usedPct:resetsAt:)` produces an HStack ending with `"resets in 1h 28m"`. We need to add a gear icon after that text — but only on the 5h row, not the 7d row. Refactor `usageBar` to take an optional trailing view.

- [ ] **Step 1: Refactor `usageBar` to accept a trailing view**

In `Sources/AppLib/SimulatedNotch/SimulatedNotchFullView.swift`, replace the entire `usageBar` function (around line 50) with:

```swift
    @ViewBuilder
    private func usageBar<Trailing: View>(
        label: String,
        usedPct: Double?,
        resetsAt: Date?,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() }
    ) -> some View {
        let used = usedPct ?? 0
        let remaining = max(0, 100 - used)
        let color = barColor(for: used)
        let hasData = usedPct != nil

        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(label)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.7))
                    .frame(width: 22, alignment: .leading)

                if hasData {
                    Text(String(format: "%.0f%% remaining", remaining))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(color)
                } else {
                    Text("no data")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.4))
                }

                Spacer(minLength: 0)

                if let reset = relativeReset(resetsAt) {
                    Text("resets in \(reset)")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.45))
                }

                trailing()
            }

            // Progress bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.white.opacity(0.10))
                        .frame(height: 6)
                    if hasData {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(color)
                            .frame(width: geo.size.width * CGFloat(used / 100), height: 6)
                    }
                }
            }
            .frame(height: 6)
        }
    }
```

- [ ] **Step 2: Update `usageHeader` to pass the gear `Menu` as the 5h row's trailing view**

In the same file, replace the `usageHeader` body with:

```swift
    private var usageHeader: some View {
        let snap = usageTracker.snapshot
        return VStack(spacing: 8) {
            usageBar(
                label: "5h",
                usedPct: snap.fiveHourUsedPct,
                resetsAt: snap.fiveHourResetsAt,
                trailing: { gearMenu }
            )
            usageBar(
                label: "7d",
                usedPct: snap.sevenDayUsedPct,
                resetsAt: snap.sevenDayResetsAt
            )
        }
    }

    /// Settings dropdown menu — anchored to the gear icon at the right
    /// of the 5h row in the header. Two items: About and Quit.
    private var gearMenu: some View {
        Menu {
            Button("About ZackEyes…") {
                modeStore.isAboutShown = true
            }
            Divider()
            Button("Quit ZackEyes") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.55))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
```

- [ ] **Step 3: Add the AppKit import for `NSApp`**

At the top of `Sources/AppLib/SimulatedNotch/SimulatedNotchFullView.swift`, add `import AppKit` if it isn't already imported. Replace the existing imports section:

```swift
import SwiftUI
import AppKit
```

- [ ] **Step 4: Verify the build**

Run: `swift build`
Expected: `Build complete!` with no errors.

If you get a "Menu' is only available in macOS 11.0 or newer" error, the deployment target is fine — we're at 14.0. If you get a "menuIndicator unknown member" error, the API name may differ; the alternative is to remove `.menuIndicator(.hidden)`.

- [ ] **Step 5: Run tests**

Run: `swift test`
Expected: `Test run with 23 tests in 3 suites passed`.

- [ ] **Step 6: Smoke-test the gear visually (manual)**

Run:
```bash
make app
killall ZackEyes 2>/dev/null
rm -f /tmp/zackeyes.sock
open .build/ZackEyes.app
```

Then hover the simulated notch to expand the full panel. Expected:
- A small gear icon appears at the right end of the 5h row, immediately after "resets in …"
- Clicking the gear pops up a dropdown with "About ZackEyes…" + separator + "Quit ZackEyes"
- "Quit ZackEyes" terminates the app
- "About ZackEyes…" does nothing visible yet (just sets `isAboutShown = true`, no overlay yet)

If the gear is invisible, the icon color may need bumping (try `0.7` opacity). If the menu doesn't open, see the "Risks" section of the spec — fall back to NSPopUpButton via NSViewRepresentable.

- [ ] **Step 7: Commit**

```bash
git add Sources/AppLib/SimulatedNotch/SimulatedNotchFullView.swift
git commit -m "$(cat <<'EOF'
feat(simulated-notch): gear menu in the 5h row of the full panel header

Adds a small gearshape icon at the right end of the 5h usage row.
Click → SwiftUI Menu dropdown with two items:

  - About ZackEyes…  (sets modeStore.isAboutShown — overlay coming next)
  - Quit ZackEyes    (NSApp.terminate(nil) + Cmd+Q shortcut)

usageBar gains an optional @ViewBuilder trailing parameter so we only
attach the gear to the 5h row, not the 7d one.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Build the About overlay card view

**Files:**
- Modify: `Sources/AppLib/SimulatedNotch/SimulatedNotchFullView.swift`

The About overlay is a backdrop + centered card. We'll add it as a SwiftUI overlay on the existing `VStack`. This task adds the visual; Task 5 wires it to the menu.

- [ ] **Step 1: Add the About overlay views**

In `Sources/AppLib/SimulatedNotch/SimulatedNotchFullView.swift`, add this as a private computed property near `gearMenu`:

```swift
    /// About card overlay — semi-transparent backdrop + centered card
    /// with app icon, name, version, and OK button. Shown when
    /// `modeStore.isAboutShown == true`.
    @ViewBuilder
    private var aboutOverlay: some View {
        if modeStore.isAboutShown {
            ZStack {
                // Backdrop — tap to dismiss.
                Color.black.opacity(0.6)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        modeStore.isAboutShown = false
                    }

                // Card — opaque, centered, fixed 280×200.
                VStack(spacing: 14) {
                    aboutIcon
                        .frame(width: 64, height: 64)

                    Text("ZackEyes")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.white)

                    Text("Version \(appVersion)")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.6))

                    Button("OK") {
                        modeStore.isAboutShown = false
                    }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.defaultAction)
                }
                .padding(20)
                .frame(width: 280, height: 200)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(white: 0.12))
                )
                .contentShape(Rectangle())  // swallow taps so they don't hit the backdrop
                .onTapGesture { /* no-op: prevent backdrop dismiss */ }
            }
            .transition(.opacity)
        }
    }

    /// Icon for the About card. Tries to load the bundle's AppIcon image;
    /// falls back to a SF Symbol if it isn't found.
    @ViewBuilder
    private var aboutIcon: some View {
        if let nsImage = NSImage(named: "AppIcon") {
            Image(nsImage: nsImage)
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 12))
        } else {
            Image(systemName: "sparkles")
                .font(.system(size: 36))
                .foregroundColor(.white.opacity(0.7))
        }
    }

    /// Version string from Info.plist's CFBundleShortVersionString.
    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }
```

- [ ] **Step 2: Layer the About overlay on top of the existing body**

In the same file, replace the `body` of `SimulatedNotchFullView` with:

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
    }
```

- [ ] **Step 3: Verify the build**

Run: `swift build`
Expected: `Build complete!` with no errors.

- [ ] **Step 4: Run tests**

Run: `swift test`
Expected: `Test run with 23 tests in 3 suites passed`.

- [ ] **Step 5: Smoke-test (manual) — temporarily flip `isAboutShown` to verify rendering**

The menu doesn't yet flip `isAboutShown` (it does, from Task 3 — but let's confirm): rebuild, expand the notch, click the gear → click "About ZackEyes…". The About card should appear:
- Centered in the panel
- Showing the AppIcon (red star/circle)
- Title "ZackEyes"
- "Version 0.1.0" subtitle
- An OK button

Click OK → card disappears.
Click the dark backdrop area outside the card → card disappears.
Click on the card itself (not the OK button) → card stays.

If the icon looks pixelated, that's expected for the upscaled bundle icon — not a bug.

- [ ] **Step 6: Commit**

```bash
git add Sources/AppLib/SimulatedNotch/SimulatedNotchFullView.swift
git commit -m "$(cat <<'EOF'
feat(simulated-notch): About overlay card with icon, version, OK button

Layered as a SwiftUI .overlay on top of the existing full panel content.
Backdrop is semi-transparent black; card is 280x200 with the bundle
AppIcon, "ZackEyes", "Version X.Y.Z", and an OK button. Click backdrop
or OK or hit Escape to dismiss.

Wired to modeStore.isAboutShown — flipped by the About menu item from
the previous commit.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Make the panel sticky while menu/About is open

**Files:**
- Modify: `Sources/AppLib/SimulatedNotch/SimulatedNotchController.swift`
- Modify: `Sources/AppLib/SimulatedNotch/SimulatedNotchFullView.swift`

Right now the menu and About are visible but the panel will collapse if the user moves the mouse off the panel. We need to:
1. Tell the modeStore when the gear menu is open (SwiftUI Menu doesn't expose `isPresented` directly — we use the long-form `Menu(content:label:)` with an `isPresented:` binding to a `@State`, then write the state through to `modeStore.isMenuOpen` via `.onChange`)
2. Have the controller's `handleMouseMove` and outside-click monitors check `modeStore.hasInteractiveOverlay` in addition to `hasPendingPermission`.

- [ ] **Step 1: Replace `gearMenu` so it tracks the open state on the modeStore**

SwiftUI's `Menu` does NOT publish its open state via a binding, so we can't directly observe when the menu opens or closes. Workaround: use `.onTapGesture` on the menu label to optimistically mark `isMenuOpen = true` on click, plus a 4-second auto-clear timer as a safety net. The Button actions explicitly set `isMenuOpen = false` so the common case (user picks an item) clears the flag immediately.

Worst case (user clicks the gear, dismisses the menu without picking anything): `isMenuOpen` stays `true` for up to 4 seconds, during which the panel stays open. Acceptable.

In `Sources/AppLib/SimulatedNotch/SimulatedNotchFullView.swift`, **completely replace** the `gearMenu` property added in Task 3 with:

```swift
    /// Settings dropdown menu — anchored to the gear icon at the right
    /// of the 5h row in the header. Two items: About and Quit.
    ///
    /// Tracks open state on `modeStore.isMenuOpen` so the controller's
    /// sticky-collapse logic doesn't kill the panel out from under the
    /// menu. SwiftUI's `Menu` doesn't expose an isPresented binding, so
    /// we set the flag on label tap and clear it via either the Button
    /// actions (common case) or a 4-second safety timer (user dismissed
    /// without picking).
    private var gearMenu: some View {
        Menu {
            Button("About ZackEyes…") {
                modeStore.isMenuOpen = false
                modeStore.isAboutShown = true
            }
            Divider()
            Button("Quit ZackEyes") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.55))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onTapGesture {
            modeStore.isMenuOpen = true
            let store = modeStore
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                store.isMenuOpen = false
            }
        }
    }
```

- [ ] **Step 2: Extend the controller's sticky checks**

In `Sources/AppLib/SimulatedNotch/SimulatedNotchController.swift`, find the `hasPendingPermission` computed property (added in a previous commit). Below it, add:

```swift
    /// True when ANY interactive UI is on the panel and the panel must
    /// not auto-collapse: a pending permission, the gear menu being open,
    /// or the About overlay being shown.
    private var stickyOpen: Bool {
        hasPendingPermission || modeStore.hasInteractiveOverlay
    }
```

Then find `handleMouseMove` and replace the existing sticky check (the `if hasPendingPermission { ... return }` block) with one that uses `stickyOpen`:

```swift
        } else {
            // Mouse left the area. STICKY EXCEPTION: don't collapse while
            // any interactive overlay is on the panel — pending permission,
            // open gear menu, or About card.
            if stickyOpen {
                collapseWorkItem?.cancel()
                return
            }
            // Otherwise schedule a collapse back to compact.
```

In the same file, find `startOutsideClickMonitoring` and update both the `globalClickMonitor` and `localClickMonitor` callbacks. Replace the `if self.hasPendingPermission { return }` lines with `if self.stickyOpen { return }`:

```swift
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                // Sticky: don't dismiss while a permission/menu/about overlay is interacting.
                if self.stickyOpen { return }
                self.setMode(.compact)
            }
        }

        localClickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            guard let self = self else { return event }
            if let panelWin = self.panel, event.window === panelWin {
                return event
            }
            Task { @MainActor in
                if self.stickyOpen { return }
                self.setMode(.compact)
            }
            return event
        }
```

- [ ] **Step 3: Verify the build**

Run: `swift build`
Expected: `Build complete!` with no errors.

- [ ] **Step 4: Run tests**

Run: `swift test`
Expected: `Test run with 23 tests in 3 suites passed`.

- [ ] **Step 5: Smoke-test sticky behavior (manual)**

Restart the app:
```bash
make app
killall ZackEyes 2>/dev/null
rm -f /tmp/zackeyes.sock
open .build/ZackEyes.app
```

1. Hover the notch → full panel expands
2. Click the gear → menu opens
3. Move the mouse off the panel onto the desktop — **panel should NOT collapse**
4. Move the mouse back, click "About ZackEyes…" — About appears
5. Move the mouse off the panel — **panel should NOT collapse**
6. Click the OK button or backdrop → About dismisses
7. Move the mouse off the panel — **panel collapses normally** (within 0.35s)

If step 3 still collapses, the `.onTapGesture` on the gear isn't firing. Debug by adding `print("[gear] tap")` inside the gesture, then check the build's stderr.

If step 5 collapses, `isAboutShown` isn't being read correctly by `hasInteractiveOverlay`. Verify the modeStore reference in `SimulatedNotchFullView` is the same instance as the one in the controller (it should be — they share via `SimulatedNotchRoot`).

- [ ] **Step 6: Commit**

```bash
git add Sources/AppLib/SimulatedNotch/SimulatedNotchController.swift Sources/AppLib/SimulatedNotch/SimulatedNotchFullView.swift
git commit -m "$(cat <<'EOF'
feat(simulated-notch): sticky panel while gear menu / About overlay open

Generalizes the existing hasPendingPermission auto-collapse exception
into a stickyOpen check that also covers modeStore.hasInteractiveOverlay
(menu open OR about shown). Otherwise the panel would collapse out from
under the user as soon as they moved the mouse onto a Menu item or off
the About card.

The gear's open state is tracked via .onTapGesture on the menu label
plus a 4-second timeout fallback (SwiftUI's Menu doesn't expose an
isPresented binding). Menu items explicitly clear the flag when fired.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Permission requests dismiss the About card

**Files:**
- Modify: `Sources/AppLib/SimulatedNotch/SimulatedNotchController.swift`
- Modify: `Sources/ZackEyes/AppDelegate.swift`

Per the spec: if the About overlay is showing and a `PermissionRequest` arrives, the permission takes precedence — About dismisses and the question shows.

- [ ] **Step 1: Add `dismissAboutOverlay()` to `SimulatedNotchController`**

In `Sources/AppLib/SimulatedNotch/SimulatedNotchController.swift`, add this public method right after the `forceExpand()` method:

```swift
    /// Tear down the About overlay if it's currently shown. Used by the
    /// PermissionRequest path so a question can claim the panel even
    /// when the user is reading the About card.
    public func dismissAboutOverlay() {
        modeStore.isAboutShown = false
    }
```

- [ ] **Step 2: Wire the PermissionRequest handler in AppDelegate**

In `Sources/ZackEyes/AppDelegate.swift`, find the `case "PermissionRequest":` block (around line 131). Right before the existing `forceUiExpand()` call, add `simulatedNotch?.dismissAboutOverlay()`:

```swift
            NSLog("ZackEyes: PermissionRequest for tool=%@", event.toolName ?? "?")
            sessionStore.handlePermissionRequest(sessionId: sid, permission: pending)
            simulatedNotch?.dismissAboutOverlay()
            forceUiExpand()
```

- [ ] **Step 3: Verify the build**

Run: `swift build`
Expected: `Build complete!` with no errors.

- [ ] **Step 4: Run tests**

Run: `swift test`
Expected: `Test run with 23 tests in 3 suites passed`.

- [ ] **Step 5: Smoke-test the collision (manual)**

Restart the app, then in another terminal:
```bash
make test-permission
```

Before clicking an option in the test prompt, click the gear → "About ZackEyes…" so the About card is visible. Then re-run `make test-permission` from a third terminal — the About card should disappear and the question should appear in its place.

(Alternatively: open the About card first, THEN run `make test-permission` — it should auto-dismiss the About card and show the question.)

- [ ] **Step 6: Commit**

```bash
git add Sources/AppLib/SimulatedNotch/SimulatedNotchController.swift Sources/ZackEyes/AppDelegate.swift
git commit -m "$(cat <<'EOF'
feat(simulated-notch): permission requests dismiss the About overlay

If the user has the About card open when a PermissionRequest arrives,
auto-dismiss About so the question can claim the panel. Permission
requests are time-sensitive (Claude is blocked waiting on the user);
the About card is not.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: End-to-end smoke test

**Files:** none (manual verification)

This task is the final acceptance gate. It runs the full user-visible flow.

- [ ] **Step 1: Clean rebuild**

```bash
killall ZackEyes 2>/dev/null
rm -f /tmp/zackeyes.sock
make clean
make app
open .build/ZackEyes.app
```

- [ ] **Step 2: Walk the full happy path**

1. Hover the simulated notch → full panel expands smoothly
2. Verify the gear icon is visible at the right end of the 5h row
3. Click the gear → SwiftUI Menu drops down with two items + separator
4. Move the mouse off the panel — panel stays open (sticky)
5. Move back, click "About ZackEyes…" → menu closes, About card appears
6. Verify the About card shows: AppIcon, "ZackEyes", "Version 0.1.0", "OK" button
7. Move the mouse off the panel — panel stays open (About sticky)
8. Click on the card itself (not the OK button) — card stays
9. Click OK → card dismisses
10. Move the mouse off the panel — panel collapses normally
11. Re-expand the panel, click the gear, click "Quit ZackEyes"
12. Verify the app terminates (`pgrep -x ZackEyes` returns nothing)

- [ ] **Step 3: Test the keyboard shortcut**

1. Re-launch: `open .build/ZackEyes.app`
2. Hover the notch → full panel
3. Click the gear (don't click an item)
4. Press Cmd+Q → app should quit

- [ ] **Step 4: Test the permission collision**

1. Re-launch
2. Open the About card via gear → About
3. In another terminal: `make test-permission`
4. Verify the About card disappears and the question/options appear
5. Click an option → bridge exit code should be 0 (`echo $?` after the test)

- [ ] **Step 5: Run the full test suite one final time**

```bash
swift test
```
Expected: all 23 tests pass.

- [ ] **Step 6: Branch is ready for merge**

```bash
git log style/polish ^master --oneline
```

Should show 6 commits (Tasks 1-6). Manually inspect each commit message, then we're done.

---

## Summary

| Task | Files touched | Commits |
|------|---------------|---------|
| 1 | SimulatedNotchRoot.swift | 1 |
| 2 | SimulatedNotchRoot.swift, SimulatedNotchFullView.swift | 1 |
| 3 | SimulatedNotchFullView.swift | 1 |
| 4 | SimulatedNotchFullView.swift | 1 |
| 5 | SimulatedNotchController.swift, SimulatedNotchFullView.swift | 1 |
| 6 | SimulatedNotchController.swift, AppDelegate.swift | 1 |
| 7 | (manual smoke) | 0 |

Total: **6 commits**, **4 files** modified, **0 new files**, **0 file deletions**.
