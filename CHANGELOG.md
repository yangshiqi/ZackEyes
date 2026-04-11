# Changelog

All notable changes to ZackEyes. Format follows [Keep a Changelog](https://keepachangelog.com).

## [0.1.0] — 2026-04-11

### Added

#### Simulated Dynamic Island (Macs without a notch)
- Floating notch-shaped panel at the top center of the screen, drawn with a custom `NotchShape` (flat top, rounded bottom corners)
- Three-state morphing controller: `compact` (170×26 pill) → `hoverWide` (300×26) → `full` (480×auto-fit)
- **Hover to expand** directly into the full panel — no click required, mouse-leave collapses with 350ms grace
- **Click to toggle** also works for keyboard / accessibility users
- Full panel **morphs in place** as a single continuous black shape — never a separate NSPopover with an arrow
- Auto-fit height: heuristic computed from active session count and content (prompt / reply / tool action / tasks / permissions / errors), capped at screen visible height
- Refits height as sessions change (debounced 120ms)
- Outside-click monitor dismisses the panel back to compact

#### Real subscriber rate limits
- Bridge installs itself as Claude Code's `statusLine` handler to receive `rate_limits` data via stdin
- Skips installation if another tool (e.g. Vibe Island) already owns `statusLine` — never breaks existing setups
- `UsageTracker` parses `five_hour.used_percentage`, `seven_day.used_percentage`, and `resets_at` timestamps
- Shows real plan usage with reset countdowns (`resets in 3h 36m`, `resets in 2d`)
- Color thresholds: green (used <50%) → orange (50-85%) → red (>85%)
- Falls back to estimated transcript token aggregation when no `rate_limits` data is available

#### Buddy personalities + animations
- Each session gets a deterministic pixel-art avatar drawn from a 9-template / 8-color palette
- Templates: guitar, skull, lightning, microphone, drums, vinyl, star, crossbones, cassette
- Each session also gets a deterministic name from a pool of **66 rock / metal / punk legends** (Queen, Stones, Zeppelin, Sabbath, Metallica, Maiden, Ramones, Pistols, Clash, Nirvana, Pearl Jam, Oasis, RATM, RHCP, …) plus a one-line tagline
- **Working state**: aggressive headbang animation (rotation + bounce, 0.22s loop)
- **Idle state**: drooping tilt + slow breathing + cascading "Zzz" floating up (3 staggered Z characters)
- **Waiting state**: panicked left-right shake (0.13s loop)

#### Multi-session tracking
- `SessionStore` now tracks every Claude Code session by `session_id` independently
- `SessionScanner` discovers already-running sessions on startup by scanning `~/.claude/projects/*.jsonl`
- `aggregateState` computes the most-urgent state across all sessions (waiting > working > idle) for the menu bar icon and notch
- `primarySession` selection prioritizes sessions with pending permission requests, then most-recently-active

#### Session detail rendering
- `You:` line shows the latest user prompt (up to 100 chars, 2 lines)
- `Claude:` line shows the assistant's reply captured from Stop event's `last_assistant_message`
- Tool action row with running spinner / completion checkmark and command/file preview
- Project name + Claude badge + elapsed time chip in the header

#### Tasks panel
- Reads the Claude Code transcript JSONL and replays `TaskCreate` / `TaskUpdate` to reconstruct the current task list
- Correlates `TaskCreate` `tool_use_id` with its `tool_result` (`"Task #N created successfully: ..."`) to extract real task IDs
- Resets the task list at each new user prompt — only shows the current turn's tasks
- Sorts in_progress → open → recent done with smart truncation
- In-progress tasks have an animated pulse dot

#### API error detection
- 12 patterns recognized in assistant output: `429`, `rate_limit`, `quota`, `usage limit`, `401`, `403`, `credit balance`, `billing`, `500`, `502`, `503`, `504`, `overloaded`, `api error`, `request rejected`, `connection error`
- Red banner inside the session card with the error label and original message
- Time-sensitive macOS notification with sound
- Auto-clears when the user sends a new prompt

#### Permission approval flow
- `PermissionRequest` hook → bridge sends event over socket → app shows popover with tool name + command preview + Allow/Deny buttons → response routed back through the same connection → bridge stdout returns the decision JSON to Claude Code
- 15 second bridge timeout, 20 second app-side wait
- Outside-click + global hotkey + tap on bridge disconnect all dismiss correctly
- Bridge stays open until either the user decides or it disconnects (POLLHUP detection clears `pendingPermission`)

#### AskUserQuestion support
- Detects when `tool_name == "AskUserQuestion"` in a `PermissionRequest`
- Renders a custom UI: header text + numbered option cards (label + description + chevron)
- Click an option → sends `hookSpecificOutput.decision.updatedInput.answers: [label]`

#### Terminal jump
- Click a session card → ZackEyes activates the exact terminal tab where that Claude is running
- **iTerm2** and **Terminal.app**: AppleScript matching by tty
- **Ghostty / Warp / Kitty / Alacritty / VS Code / Cursor**: Accessibility API window-title matching by cwd
- For sessions discovered by the scanner (no `claudePid` known), uses `lsof -t <transcript>` and `ps + lsof cwd` to find the claude process on demand
- All subprocess calls run in a background `Task.detached` with 2-3 second timeouts so they never block the UI

#### Notifications
- Time-sensitive macOS notification when a session finishes a turn (only if the session actually used tools)
- Critical notification with sound when an API error / rate limit is detected
- Tap a notification → jumps to the originating terminal tab

#### Custom hotkey
- Global toggle hotkey configurable from the gear menu ("Change Hotkey…")
- Key recorder overlay captures key combo via `NSEvent` local monitor, validates at least one modifier
- Persisted to `~/.zackeyes/config.json`, loaded at startup, hot-swapped at runtime via `HotKeyManager.reregister()`
- Default remains `Cmd + Shift + Z`

#### Update checker
- Polls `GET /repos/yangshiqi/ZackEyes/releases/latest` on startup + every 6 hours
- Semantic version comparison (major.minor.patch)
- Red 6pt badge on gear icon when update available
- "Update Available (vX.Y.Z)" menu item → opens GitHub Releases page
- One-time system notification per version (deduped via UserDefaults)
- Optional GitHub token in `~/.zackeyes/config.json` for private repos

#### Other UX
- **Cmd + Shift + Z** global hotkey via Carbon `RegisterEventHotKey` (now customizable)
- Menu bar icon: `sparkles` SF Symbol with state-based tint (gray idle, teal working, orange waiting)
- Popover (when not using simulated notch) auto-dismisses on any click outside via global + local NSEvent monitors
- Ad-hoc code signing in Makefile so Accessibility / Apple Events grants persist across rebuilds
- `NSSupportsAutomaticTermination = false` and `disableAutomaticTermination()` to keep the long-running socket server alive

### Fixed
- `Stop` event now keeps the session active and only `SessionEnd` collapses the panel
- Session duration timer freezes when state is idle/stopped
- Nested ObservableObject not propagating — `NotchViewModel` now forwards `sessionStore.objectWillChange` so SwiftUI re-renders
- Tasks list reset at every new user prompt
- Click handler runs on background task with subprocess timeouts to prevent UI hang
- Removed misleading "Restart session for live tracking" hint — scanned sessions auto-upgrade on the next live event
- `ConfigStore.save()` preserves all config keys (previously overwrote `githubToken` on hotkey save)

### Architecture / Build
- Swift Package Manager with 5 targets (`Shared`, `BridgeLib`, `AppLib` libraries; `Bridge`, `ZackEyes` executables) + 3 test targets
- 73 unit tests (50 XCTest + 23 Swift Testing)
- `make dmg` builds universal binary (arm64 + x86_64) DMG for distribution
- Makefile assembles the `.app` bundle and applies ad-hoc code signature
- Zero third-party dependencies
