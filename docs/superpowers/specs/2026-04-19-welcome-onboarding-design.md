# Welcome Onboarding — Design

**Status**: Proposed
**Date**: 2026-04-19
**Scope**: First-launch (per-version) welcome animation in the notch panel.

## Goal

Tell the user: "this app lives in your notch — hover there." Once, on first launch
after any new install or upgrade, the expanded panel opens with a short
welcome message, plays the app's notification sound, and auto-collapses back
to compact after 3 seconds. Both real-notch (MacBook Pro with hardware notch)
and simulated-notch (notchless Mac) surfaces get the same animation.

## Non-goals

- Multi-page onboarding tutorial (hooks, sessions, permissions). Out of scope;
  README and existing UI surfaces already explain the flow.
- A standalone NSPanel / window for onboarding. Reuses the existing notch panel.
- Click-to-dismiss or "skip" button. 3 seconds is short enough to be ambient.
- Interaction with the menu-bar fallback popover (it is a fallback surface;
  welcome animation is only meaningful on the two ambient notch surfaces).

## Trigger rule

The welcome animation fires when the app's bundle version differs from the
last version we recorded after showing the welcome.

- Storage key: `UserDefaults.standard` → `welcomeShownForVersion` (string)
- Compare against: `Bundle.main.infoDictionary?["CFBundleShortVersionString"]`
- Mismatch (or nil stored value) → fire. Match → skip.
- Bundle version unreadable → treat as "already shown" and skip. We never
  want a degraded startup path to spam the user.

This means every upgrade doubles as a subtle release notification. This is
intentional — a once-per-version 3-second chime is a better upgrade signal
than the existing GitHub Releases system notification alone.

## Decisions (from brainstorming)

| Decision | Value | Reason |
|---|---|---|
| Scope | Per bundle version | Welcome = also a lightweight "what's new" moment |
| Content style | Buddy avatar + title + subtitle | Matches brand (buddy = product mascot) |
| Sound | `NotificationManager.playThemeSound()` | Single sound path; respects user's theme + "none" mute |
| Duration | 3.0s auto-collapse, no early dismiss | Ambient, no interaction surface to maintain |
| Surfaces | Real notch + simulated notch; skip menu-bar popover | Menu-bar popover is not ambient — user would never see it |

## Architecture

### Component summary

```
AppDelegate.applicationDidFinishLaunching
    └─ (after all UI is wired up)
       maybeShowWelcome()
         ├─ WelcomeTrigger.shouldShowWelcome()        // UserDefaults compare
         ├─ viewModel.welcomeVisible = true           // SwiftUI flag
         ├─ forceUiExpand()                           // real or simulated notch
         ├─ NotificationManager.shared.playChime()
         ├─ Task { sleep 3s; welcomeVisible = false }
         └─ WelcomeTrigger.markShown()                // UserDefaults write
```

### New files

| File | Responsibility |
|---|---|
| `Sources/AppLib/Onboarding/WelcomeTrigger.swift` | Pure version-compare logic. Injectable `UserDefaults` and version string for testability. Two entry points: `shouldShowWelcome(defaults:version:) -> Bool` and `markShown(defaults:version:)`. |
| `Sources/AppLib/Onboarding/WelcomeOverlay.swift` | SwiftUI view rendered inside `NotchExpandedView` / `SimulatedNotchFullView` when `viewModel.welcomeVisible == true`. Shows PixelAvatar (bump animation) + title + subtitle. |

### Modified files

| File | Change |
|---|---|
| `Sources/AppLib/Notch/NotchViewModel.swift` | Add `@Published var welcomeVisible: Bool = false` |
| `Sources/AppLib/Notch/NotchExpandedView.swift` | Top-level `if viewModel.welcomeVisible { WelcomeOverlay() } else { /* existing */ }` |
| `Sources/AppLib/SimulatedNotch/SimulatedNotchFullView.swift` | Same conditional overlay as above |
| `Sources/ZackEyes/AppDelegate.swift` | `maybeShowWelcome()` private func invoked at the tail of `applicationDidFinishLaunching` |
| `Sources/AppLib/Notifications/NotificationManager.swift` | Expose a `public func playChime()` wrapper around the existing private `playThemeSound()`; `playChime()` discards the Bool return (welcome doesn't care about fallback) |

### Why `NotchViewModel` owns the flag

Both surfaces already receive the same `NotchViewModel` instance. A single
`@Published` propagates to SwiftUI on both surfaces without any coordination.
No new controller, no Combine bridging, no new ObservableObject.

### Why the overlay is SwiftUI (not a separate NSPanel)

- Reuses existing 420×280 real-notch host frame and ~520×fullHeight simulated
  notch frame; no new positioning math.
- Respects all existing notch invariants (`nonactivatingPanel`, `canBecomeMain
  = false`, mouse-through compact rules).
- Respects screen-change handling; if the user moves between displays during
  the 3s welcome, the existing panel reseat logic applies.

## Data flow

```
App launches
  ↓
applicationDidFinishLaunching
  ↓ [UI setup: socket, sessions, notch controllers, hotkey, hooks, update check]
  ↓
maybeShowWelcome()
  ↓
WelcomeTrigger.shouldShowWelcome(defaults: .standard, version: "x.y.z")
  ├─ stored == "x.y.z" → return false → no-op
  ├─ stored == nil or != "x.y.z" → return true
  │   ↓
  │   viewModel.welcomeVisible = true
  │       ↓ (SwiftUI observes)
  │   NotchExpandedView / SimulatedNotchFullView render WelcomeOverlay
  │   ↓
  │   forceUiExpand() → WC.forceExpand() or SimulatedNotch.forceExpand()
  │   ↓
  │   NotificationManager.shared.playChime()  // "none" = silent
  │   ↓
  │   Task.detached { try? await Task.sleep(3s); await MainActor.run {
  │                    viewModel.welcomeVisible = false
  │                    WelcomeTrigger.markShown(defaults, version) } }
  │   ↓ (after 3s)
  │   overlay removed → normal expanded content visible
  │   ↓ (after hover-out grace)
  │   controller auto-collapses to compact
  ↓
App continues normal operation
```

## Visual design

The overlay occupies the same bounds as the expanded content. Layout:

```
┌──────────────────────────────────────────────────┐
│                                                  │
│   ┌────────┐                                     │
│   │ PIXEL  │   Welcome to ZackEyes               │
│   │ AVATAR │                                     │
│   │        │   I live in your notch.             │
│   │ (bump) │   Hover here to see me.             │
│   └────────┘                                     │
│                                                  │
└──────────────────────────────────────────────────┘
```

Animation:
- PixelAvatar scale spring `0.0 → 1.15 → 1.0`, duration 0.40s, on appear.
- Title + subtitle opacity fade `0 → 1` over 0.30s, with 0.10s delay relative
  to avatar start so the bump lands first.
- No looping animation. After 0.5s the view is static until dismissal.

Simulated-notch variant uses the same overlay but centered in the larger
520×fullHeight frame. The PixelAvatar size and font sizes are identical — the
extra space just becomes more padding.

## Edge cases

| Case | Behavior |
|---|---|
| `CFBundleShortVersionString` missing or unreadable | Skip welcome. No write to UserDefaults. |
| A PermissionRequest arrives during the 3s welcome | `forceExpand()` is idempotent; `stickyOpen` flag from `SessionStore.pendingPermission` keeps the panel open after welcome ends. Welcome overlay disappears at t=3s, revealing the real permission UI underneath. No mutex logic needed. |
| User quits the app at t=1s | `welcomeShownForVersion` was never written, so the welcome will replay on the next launch. Acceptable — the user didn't actually see it. |
| User has no notch hardware AND simulated notch fails to create | `forceUiExpand()` falls back to `menuBarFallback?.showPopover()`, which bypasses the overlay. The welcome flag is still set and will fire again on next launch. This is an extreme edge case (simulated notch has no known failure mode) and not worth special handling. |
| User upgrades 3 versions in a row without launching | Only the final version shows welcome once. Stored version updates to the latest. Correct. |
| App launches with `welcomeVisible == true` stuck from a crashed prior run | Not possible — `welcomeVisible` is not persisted; it defaults to `false` on every launch. |

## Testing

Unit test the pure logic only. SwiftUI overlay + timing behavior are not tested.

### `Tests/AppLibTests/WelcomeTriggerTests.swift` (new)

- Returns `true` when stored value is nil.
- Returns `true` when stored value differs from current version.
- Returns `false` when stored value matches current version.
- Returns `false` when current version is nil (unreadable bundle).
- After `markShown(version:)`, `shouldShowWelcome(same version)` returns false.
- Injects `UserDefaults(suiteName: "WelcomeTriggerTests")` so tests don't touch
  the user's real defaults.

No snapshot tests, no UI tests, no integration test for AppDelegate invocation.
This is a 3-second one-shot; over-testing would cost more than it saves.

## Security & safety review

| Invariant (CLAUDE.md) | Impact |
|---|---|
| #1 `settings.json` not corrupted | No change — welcome never touches settings.json |
| #2 Bridge never pollutes Claude Code terminal | No change — welcome is app-side only |
| #3 NotchPanel never steals focus | No change — reuses existing nonactivating panel |
| #4 Socket connections not reused | No change — welcome never opens a socket |
| #5 Hook configs identifiable | No change — welcome never modifies hooks |
| #6 Zero third-party deps | No change — SwiftUI + UserDefaults + existing NSSound path |

## Out of scope

- Persisting a richer onboarding state ("user saw the tutorial AND accepted
  hook auto-install"). Not useful yet — we have no "skip tutorial" UI.
- Animation on PixelAvatar appearance other than a single bump. Looped idle
  animations belong to `BuddyAvatar`, which is already used in session cards
  and does not need to duplicate into the welcome view.
- Internationalization. Strings are English-only, consistent with the rest of
  the app.

## Implementation order

1. Write `WelcomeTrigger` + its tests. Verify in isolation.
2. Add `welcomeVisible` flag on `NotchViewModel`.
3. Create `WelcomeOverlay` SwiftUI view.
4. Wire it into `NotchExpandedView` and `SimulatedNotchFullView`.
5. Wire `maybeShowWelcome()` into `AppDelegate`.
6. Run the app: verify first launch fires welcome + sound + auto-collapse;
   verify second launch is silent; verify version bump re-fires.

## References

- `Sources/AppLib/Notch/NotchWindowController.swift:86` — `forceExpand()`
- `Sources/AppLib/SimulatedNotch/SimulatedNotchController.swift:209` — `forceExpand()`
- `Sources/ZackEyes/AppDelegate.swift:400` — `forceUiExpand()`
- `Sources/AppLib/Notifications/NotificationManager.swift:29` — private `playThemeSound()` (will add public `playChime()` wrapper)
- `Sources/AppLib/Notifications/NotificationManager.swift:121` — existing UserDefaults pattern (`lastNotifiedVersion`)
