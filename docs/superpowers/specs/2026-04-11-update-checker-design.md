# Update Checker Design

## Goal

Detect new GitHub releases and notify users via a gear menu badge + system notification, linking to the GitHub Releases page for download.

## Scope

Read-only version check against GitHub Releases API. No auto-download, no auto-update.

## Version Check Mechanism

### UpdateChecker (`Sources/AppLib/Update/UpdateChecker.swift`)

`@MainActor ObservableObject` with:

- `@Published var availableVersion: String?` — nil when up to date
- `@Published var releaseURL: URL?` — GitHub release page URL
- `func start()` — kicks off initial check + schedules 6-hour timer
- `func stop()` — invalidates timer

### API Call

- Endpoint: `GET https://api.github.com/repos/yangshiqi/ZackEyes/releases/latest`
- No authentication (public repo, anonymous rate limit 60/hr, we use ~4/day)
- Response fields used: `tag_name` (e.g. `"v0.2.0"`), `html_url`
- Strip leading `v` from `tag_name` before comparison

### Version Comparison

Semantic version comparison (major.minor.patch):
- Split both strings by `.`, compare each component as integers left to right
- `0.2.0 > 0.1.0` → update available
- `0.1.0 >= 0.1.0` → no update
- Parse failure → treat as no update (silent)

### Timing

- Check once immediately on `start()`
- Repeat every 6 hours via `Timer.scheduledTimer`
- Network failure, JSON parse failure, version parse failure → all silent, no retry until next scheduled check

### Duplicate Notification Prevention

- `UserDefaults.standard` key `"lastNotifiedVersion"` stores the version string of the last notified release
- Only send system notification if `availableVersion != lastNotifiedVersion`
- Updated after notification is sent

## UI: Gear Menu

### Red Badge on Gear Icon

When `availableVersion != nil`, overlay a 6pt red circle at the top-right of the gear icon in `SimulatedNotchFullView.gearMenu`:

```
[gear icon]  →  [gear icon]●
```

Small `Circle().fill(.red).frame(width: 6, height: 6)` positioned via `.overlay(alignment: .topTrailing)`.

### Menu Item

When `availableVersion != nil`, add as the FIRST item in the gear menu:

```
Update Available (v0.2.0)
─────────────────────────
About
Change Hotkey...
─────────────────────────
Quit ZackEyes
```

Clicking the item calls `NSWorkspace.shared.open(releaseURL)`.

`GearMenuTarget` gets an `updateClicked(_:)` handler and stores the `releaseURL`.

## UI: System Notification

### Notification Content

- Title: "ZackEyes Update Available"
- Body: "Version 0.2.0 is available. Click to download."
- Category: time-sensitive (same as existing notifications)

### Click Action

Clicking the notification opens `releaseURL` via `NSWorkspace.shared.open()`.

### Implementation

Add `notifyUpdateAvailable(version:releaseURL:)` to `NotificationManager`. The click handler in AppDelegate routes update notification taps to `NSWorkspace.shared.open()`.

Use a distinct `categoryIdentifier` (e.g. `"update"`) so it can be distinguished from session/error notifications in the click handler.

## Data Flow

```
Startup:
  AppDelegate
    → UpdateChecker().start()
    → immediate check + 6h timer

Check cycle:
  UpdateChecker
    → URLSession GET /releases/latest
    → parse tag_name, html_url
    → semantic compare: remote > local?
      → yes: set availableVersion + releaseURL
             if not already notified for this version:
               → NotificationManager.notifyUpdateAvailable()
               → UserDefaults["lastNotifiedVersion"] = version
      → no / error: silent, wait for next timer tick

Gear menu (SimulatedNotchFullView):
  observes UpdateChecker.availableVersion
    → non-nil: red dot on gear + "Update Available" menu item
    → tap: NSWorkspace.shared.open(releaseURL)

System notification:
  tap → AppDelegate routes to NSWorkspace.shared.open(releaseURL)
```

## Files Changed

| File | Change |
|------|--------|
| **New** `Sources/AppLib/Update/UpdateChecker.swift` | GitHub API call, version compare, timer, `@Published` state |
| **New** `Tests/AppLibTests/UpdateCheckerTests.swift` | Version comparison tests, JSON parsing tests |
| **Mod** `Sources/AppLib/SimulatedNotch/SimulatedNotchFullView.swift` | Gear icon red badge + "Update Available" menu item |
| **Mod** `Sources/AppLib/SimulatedNotch/GearMenuTarget.swift` | `updateClicked()` handler + `releaseURL` storage |
| **Mod** `Sources/AppLib/Notifications/NotificationManager.swift` | `notifyUpdateAvailable(version:releaseURL:)` method |
| **Mod** `Sources/ZackEyes/AppDelegate.swift` | Create UpdateChecker, route update notification taps |

## Edge Cases

- **No internet** → URLSession fails silently, next timer tick retries
- **GitHub API rate limited** → 403 response, treated as failure, silent
- **Release has no tag_name** → parse failure, silent
- **Pre-release / draft** → GitHub `/releases/latest` endpoint excludes drafts and pre-releases by default
- **Version string malformed** → comparison returns "no update", silent
- **App version equals remote** → no update shown
- **User dismisses notification** → gear menu badge persists until they update (or a newer version supersedes it)
