# Spec: Quit + About menu in the simulated notch

**Date:** 2026-04-07
**Status:** Approved for implementation
**Branch:** `style/polish`

## Background

ZackEyes is `LSUIElement = true` (no Dock icon), so the user has **no
standard way to quit the app**. Today the only options are
`killall ZackEyes` or Activity Monitor. We need an obvious, discoverable
exit affordance built into the existing UI.

## Goal

Add a small **gear menu** to the simulated notch's full panel header. The
menu has exactly two items:

1. **About ZackEyes…** — opens an in-panel SwiftUI About view
2. **Quit ZackEyes** — terminates the app via `NSApp.terminate(nil)`

That's it. No update checker, no preferences, no Restart Hooks button.
Strict MVP per CLAUDE.md's "避免过度设计" guideline.

## Visual design

### Gear placement

In `SimulatedNotchFullView.usageHeader`, the existing layout is:

```
5h  74% remaining               resets in 1h 28m
████████████░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
7d  19% remaining               resets in 1d
███░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
```

The gear icon goes on the **trailing edge of the 5h row**, immediately
after `resets in 1h 28m`:

```
5h  74% remaining               resets in 1h 28m  ⚙
```

- SF Symbol `gearshape`
- 12pt
- `.foregroundColor(.white.opacity(0.55))` — matches the rest of the
  header text weight
- 6pt leading padding from the "resets in" text
- No background, no border — flat icon button

The 7d row stays unchanged. No new height in the header.

### Menu contents

```
┌────────────────────────┐
│  About ZackEyes…       │
│  ──────────────        │
│  Quit ZackEyes    ⌘Q   │
└────────────────────────┘
```

- macOS-native SwiftUI `Menu` dropdown
- Anchored to the gear icon
- "Quit ZackEyes" gets a `.keyboardShortcut("q", modifiers: .command)` so
  Cmd+Q works while the menu is open

### About view (in-panel SwiftUI overlay)

When **About ZackEyes…** is clicked, an overlay appears **on top of the
session list**. The overlay has two layers:

1. **Backdrop** — `Color.black.opacity(0.6)` filling the entire panel
   bounds (covers header AND session list). Tap target for dismiss.
2. **About card** — a fixed-width 280pt × 200pt rounded rect, centered
   horizontally and vertically within the panel bounds. The card itself
   is opaque (`Color(white: 0.12)`). Card content stops the backdrop
   tap-to-dismiss from firing when clicking ON the card itself
   (`.contentShape(Rectangle())` + nothing on tap).

The card sits on top of, not in place of, the existing panel content —
when dismissed, the session list is exactly as the user left it.

```
┌────────────────── full panel ───────────────────┐
│ 5h  74% remaining            resets in 1h 28m ⚙ │
│ ████████████░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░ │
│ 7d  19% remaining            resets in 1d       │
│ ███░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░ │
│ ───────────────────────────────────────────────  │
│   ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░  │
│   ░░░░    ┌─────────────────────────┐    ░░░░░  │
│   ░░░░    │       [app icon]        │    ░░░░░  │
│   ░░░░    │                         │    ░░░░░  │
│   ░░░░    │        ZackEyes         │    ░░░░░  │
│   ░░░░    │                         │    ░░░░░  │
│   ░░░░    │       Version 0.1.0     │    ░░░░░  │
│   ░░░░    │                         │    ░░░░░  │
│   ░░░░    │       [    OK     ]     │    ░░░░░  │
│   ░░░░    └─────────────────────────┘    ░░░░░  │
│   ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░  │
└──────────────────────────────────────────────────┘
```

About card contents:
- 64pt app icon (loaded from `Bundle.main.image(forResource: "AppIcon")`
  with a fallback to SF Symbol `sparkles` if loading fails)
- "ZackEyes" — `.system(size: 18, weight: .semibold)`
- "Version 0.1.0" — `.system(size: 12)` `.foregroundColor(.white.opacity(0.6))`
  — version read from `Bundle.main.infoDictionary?["CFBundleShortVersionString"]`
- OK button — standard SwiftUI button with `.buttonStyle(.bordered)`,
  click → dismisses

Backdrop is `.background(Color.black.opacity(0.6))` covering the entire
panel area (including the header) with the About card on top. Clicking
the backdrop OR the OK button OR pressing Escape closes the About view.

## Behavior

### Quit flow

1. User clicks gear → SwiftUI Menu opens
2. User clicks **Quit ZackEyes** (or types Cmd+Q while menu is open)
3. Action handler calls `NSApp.terminate(nil)`
4. AppKit walks the standard termination sequence:
   - `applicationShouldTerminate` (no override → returns
     `NSTerminateNow`)
   - All windows close
   - `applicationWillTerminate` (no override → no cleanup)
   - Process exits
5. The injected hook entries in `~/.claude/settings.json` STAY in place
   — they're still pointing at the (now-stopped) `bridge` binary, which
   is fine because `bridge` is non-blocking on socket errors

### About flow

1. User clicks gear → SwiftUI Menu opens
2. User clicks **About ZackEyes…**
3. `NotchModeStore.isAboutShown` flips to `true`
4. SwiftUI re-renders `SimulatedNotchRoot` and the `SimulatedNotchFullView`
   shows the About overlay on top of the session list
5. User clicks OK / clicks backdrop / presses Escape →
   `isAboutShown = false` → overlay disappears

## Sticky panel: don't auto-collapse while menu / About is interacting

The simulated notch's `handleMouseMove` and outside-click monitor will
collapse the panel as soon as the mouse leaves the panel area. This is
a problem because:

- When the SwiftUI Menu is open, the menu items are rendered in a system
  popup that may extend outside the panel. Mouse moving onto the menu
  → outside `panel.frame` → collapse scheduled.
- When the About overlay is shown, the user is reading static content
  and may move their mouse off the panel without intending to dismiss.

Solution: extend the existing `hasPendingPermission` sticky logic to a
broader "is the panel currently in an interactive overlay state" check.
Add a new `@Published var hasInteractiveOverlay: Bool` to
`NotchModeStore`, set to `true` when:

- The gear menu is open (SwiftUI Menu's `isPresented` binding flips it)
- The About overlay is shown (`isAboutShown == true`)

`SimulatedNotchController.handleMouseMove` and the
`startOutsideClickMonitoring` monitors check
`modeStore.hasInteractiveOverlay` in addition to `hasPendingPermission`,
and skip the collapse path when either is true.

When the menu closes AND the About is dismissed → `hasInteractiveOverlay`
flips back to `false`, and the next mouse-out triggers a normal collapse.

## Components & data flow

```
                         ┌──────────────────────┐
                         │ NotchModeStore       │
                         │  mode                │
                         │  isAboutShown  (NEW) │
                         │  isMenuOpen    (NEW) │
                         │  hasInteractive…(NEW)│  ← derived
                         └──────────┬───────────┘
                                    │ @Published
                  ┌─────────────────┴─────────────────┐
                  │                                   │
        ┌─────────▼─────────┐               ┌─────────▼──────────────┐
        │ SimulatedNotchRoot│               │ SimulatedNotchController│
        │  (SwiftUI body)   │               │  handleMouseMove        │
        │                   │               │  outsideClickMonitor    │
        │  - gear Menu      │               │   ↑ both check          │
        │  - About overlay  │               │   hasInteractiveOverlay │
        └───────────────────┘               └─────────────────────────┘
```

`hasInteractiveOverlay` is a computed property on `NotchModeStore`:

```swift
public var hasInteractiveOverlay: Bool { isMenuOpen || isAboutShown }
```

It doesn't need to be `@Published` directly — `isMenuOpen` and
`isAboutShown` are, and any view (or controller) reading
`hasInteractiveOverlay` will see updates via the parent's
`objectWillChange`.

## File changes

| File | Change |
|------|--------|
| `Sources/AppLib/SimulatedNotch/SimulatedNotchRoot.swift` | Add `isMenuOpen`, `isAboutShown`, `hasInteractiveOverlay` to `NotchModeStore` |
| `Sources/AppLib/SimulatedNotch/SimulatedNotchFullView.swift` | Add gear `Menu` to `usageHeader` (5h row trailing); add About SwiftUI overlay layered on top of the existing `VStack` content; new private `aboutOverlay` view; needs `@ObservedObject` reference to the `NotchModeStore` |
| `Sources/AppLib/SimulatedNotch/SimulatedNotchController.swift` | `handleMouseMove` sticky check: `hasPendingPermission \|\| modeStore.hasInteractiveOverlay`; same in both click monitors. Add `dismissAboutOverlay()` public method that sets `modeStore.isAboutShown = false`. |
| `Sources/ZackEyes/AppDelegate.swift` | In the `PermissionRequest` handler, call `simulatedNotch?.dismissAboutOverlay()` before `forceUiExpand()`, so an open About card gets out of the way of the question. |

`SimulatedNotchFullView` doesn't currently take a `NotchModeStore` — it
receives `viewModel` and `usageTracker` only. We'll need to thread
`modeStore` through `SimulatedNotchRoot` → `SimulatedNotchFullView`.

No changes to: `MenuBarFallback`, `Bridge`, `SocketServer`,
`HookInstaller`, `SessionStore`, tests.

## Testing

Manual smoke test (no automated tests for SwiftUI views in this project):

1. `make app && open .build/ZackEyes.app`
2. Hover the notch to expand the full panel
3. Verify gear icon is visible at the right of the 5h row
4. Click gear → dropdown menu appears with "About ZackEyes…" and "Quit ZackEyes"
5. Move mouse onto the menu (which extends outside the panel) — panel
   should NOT collapse
6. Click "About ZackEyes…" → menu closes, About card appears with
   correct version, mouse-out doesn't dismiss it
7. Click OK / click backdrop / press Esc → About card dismisses
8. Click gear again → click "Quit ZackEyes" → app terminates cleanly
9. Reopen ZackEyes → it starts normally, hooks still work

Edge cases to verify:
- Cmd+Q while gear menu is open → quits
- Click gear, then click outside menu without picking anything → menu
  closes, panel still open (sticky), then mouse-out → panel collapses
  normally
- About overlay shown + permission request comes in → permission
  rendering takes precedence (or we leave About alone? — see open
  question)

## Permission request collision handling

If the About overlay is showing and a `PermissionRequest` arrives, the
permission request takes precedence. The PermissionRequest handler in
`AppDelegate.handleEvent` will set `modeStore.isAboutShown = false` (via
the controller, since AppDelegate doesn't directly own the modeStore)
right before calling `forceUiExpand()`, so the About overlay disappears
and the user sees the question instead. Reasoning: permissions are
time-sensitive (Claude is blocked waiting on the user), the About card
isn't.

To make this work, expose `simulatedNotch.dismissAboutOverlay()` and
call it from the PermissionRequest path. Cheap to add.

## Risks

1. **SwiftUI `Menu` inside an NSPanel**: macOS 14+ should handle this
   correctly, but the panel's `nonactivatingPanel` style + `screenSaver`
   level + `CGShieldingWindowLevel` might confuse the menu's popup
   positioning or cause it to appear behind something. **Must verify
   live during implementation.** Fallback: if SwiftUI Menu doesn't work,
   fall back to NSPopUpButton via NSViewRepresentable.

2. **About overlay layout in a 220×32 panel during animation**: the
   About view is sized for the 520×~480 full panel. If the user clicks
   "About" when the panel is mid-animation collapsing back to compact,
   the overlay might get clipped to a tiny region. Mitigation: gate the
   gear button on `mode == .full` (it's already only visible in the
   full panel content, but double-check the flag).

## Out of scope (YAGNI)

- Update checker
- Preferences pane / settings UI
- "Restart hooks" / "Reinstall hooks" menu items
- About card with GitHub link, license text, credits
- Custom dock icon for the About card (uses bundle icon as-is)
- Animation transitions for the About card appearing (just opacity fade)
- Localization (English-only for now, matches the rest of the app)
