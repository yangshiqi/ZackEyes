# Changelog

All notable changes to ZackEyes. Format follows [Keep a Changelog](https://keepachangelog.com).

## [0.3.1] — 2026-05-03

### Fixed
- **Stale Codex cards no longer pile up in the notch.** v0.3.0 imported any Codex rollout written in the last 8 hours, including ones whose TUI had long since closed. Two compounding fixes:
  - `SessionScanner.scan` now takes per-agent recency windows (`claudeRecencyMinutes` defaults to 480 / 8h, `codexRecencyMinutes` defaults to 30 min). Codex creates a fresh rollout per `codex` invocation, so a tight window keeps closed-TUI rollouts off the notch.
  - `runLivenessSweep` adds a time-based prune for Codex sessions: any Codex session whose `lastActiveAt` is older than 15 min and has no pending permission gets evicted. `CodexJsonlTailer` keeps watching the rollout, so the next `task_complete` re-creates the session via `SessionStore.recordCodexTaskComplete`.

## [0.3.0] — 2026-05-03

### Added — OpenAI Codex CLI as a parallel agent

- **Both agents in one notch.** Sessions, permission approvals, errors, and 5h/7d quota all surface in the same Dynamic Island UI alongside Claude Code. The expanded panel splits the quota bars left/right when both agents have data. The compact pill shows whichever agent the user picks (gear menu → "Compact display").
- **Bridge `--agent` flag.** Hook entries now include `--agent claude|codex`. Existing Claude installations keep working — the flag defaults to `claude` for legacy entries (no re-install required between an app upgrade and the next HookInstaller sweep).
- **`CodexHookInstaller`** writes `~/.codex/hooks.json` with six events (SessionStart / PreToolUse / PostToolUse / PermissionRequest / Stop / UserPromptSubmit). Same defensive contract as the Claude installer: backup first, parse failure no-op, preserve user content. We never read or write `~/.codex/config.toml` because `[features].hooks` is `default_enabled: true` in current Codex (verified against `openai/codex` source).
- **`SessionScanner` Codex adapter** — walks `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` so already-running Codex sessions surface immediately at app launch (no need to start a new thread).
- **`CodexJsonlTailer`** — kqueue-based real-time fallback for Codex TUIs that started before `~/.codex/hooks.json` was written. Tails active rollouts and fires a notification on every `event_msg.task_complete` event without requiring a Codex restart.
- **`UsageTracker` reads Codex rate limits** from `event_msg.token_count.rate_limits` (primary→5h, secondary→7d). The `SimulatedNotchFullView` header splits left/right with a fixed gear column so 5h and 7d tracks line up regardless of which row carries the menu.
- **`AgentBadge`** — purple `[Claude]` / green `[Codex]` chip on every session card. Notifications also tag the agent in the title (`[Codex] proj — done`, `⚠️ [Claude] proj — Rate limited`).
- **Compact display setting.** Gear menu → "Compact display" lets you pick which agent's quota the always-visible pill shows.

### Changed

- `BridgeEvent.agent` and `SessionInfo.agent` thread the agent kind through the socket, store, and notch UI.
- `LivenessFilter.filterLiveDetected` partitions detected sessions by agent: Claude sessions run through the existing cwd-matched filter; Codex sessions pass through unchanged (no `runningCodexCwds()` analog yet — deferred).
- `runLivenessSweep` filters its candidates to Claude only, so Codex sessions can't be evicted as ghosts.
- Stop notification gate: notify on `Stop` if the session did work *this turn* OR had a user prompt waiting on a reply. The previous `toolCallCount > 0` gate suppressed notifications on chat-only turns where the agent answers without invoking any tools (common with Codex).

### Performance

- `SessionScanner.scanCodex` and `UsageTracker.scanLatestCodexRateLimits` walk only the `YYYY/MM/DD` subdirectories that intersect the recency window (≤ 2 dirs for a 30-min or 24h window) instead of the entire archive (caught by `/codex review`).
- Both scanners use `URL.resourceValues(forKeys:)` for pre-fetched modification dates instead of a second `attributesOfItem(atPath:)` stat per file.
- `SessionScanner.scan()` is now invoked from a background `Task.detached` in `AppDelegate` instead of synchronously on the main thread.

### Internal

- 7 new test files / 22 new tests covering the codex paths (CodexHookInstaller, SessionScanner codex parsing, LivenessFilter codex pass-through, UsageTracker codex rate_limits, CodexJsonlTailer parser).
- Spec: `docs/superpowers/specs/2026-05-03-codex-compat-design.md`.

## [0.2.9] — 2026-04-26

### Added

- In-app DMG download for new versions. Releases now publish the DMG to a public companion repo (`yangshiqi/ZackEyes-release`); clicking "Update Available" downloads the installer and opens it in Finder. No GitHub token required.
- `UpdateDownloader` component to fetch DMG files from the public release repo and mount them via Finder; both menu surfaces (status-bar right-click and simulated-notch gear menu) and system notification tap route through this downloader.

### Changed

- `make release` now builds a DMG before committing the version bump and uploads it to the public release repo in addition to tagging the source repo.
- `UpdateChecker` now polls the public `yangshiqi/ZackEyes-release` repo instead of requiring a GitHub token for private source repo access.

### Removed

- `ConfigStore.loadGitHubToken()` and the `githubToken` field — no longer needed now that update checks hit a public repo.

## [0.2.8] — 2026-04-25

### Added
- **AskUserQuestion click-to-answer** — when Claude Code calls the `AskUserQuestion` tool, the notch now renders the options as clickable buttons. Tapping submits the answer through the PreToolUse hook's `updatedInput.answers` channel; CC consumes it directly and never renders its terminal AskUQ UI. Single-select submits on tap; multi-select uses checkboxes plus a Submit button (disabled while nothing is selected, joins selected labels with `", "`).
- 60-second internal soft timeout in the bridge: if no answer arrives in time, the bridge silently exits and CC falls back to its native terminal AskUQ UI — so stepping away from the keyboard never blocks an agent.

### Changed
- `BridgeSocketClient.sendAndWaitForResponse` now uses `poll()` instead of `read()` + `SO_RCVTIMEO`. App crashing or quitting during a permission/AskUQ prompt now falls back to the terminal in milliseconds instead of stalling for the full timeout.
- `BridgeEvent.requiresBlockingResponse` centralizes which hook events keep the bridge connection open. Today: `PermissionRequest` and `PreToolUse + AskUserQuestion`. Adding more in the future is a single-branch change.
- New `BridgeResponse` enum (`.permission` / `.preToolUse`) unifies the two structurally different hook response shapes at responder call sites without conflating their JSON encoding.
- Stale `PermissionRequest` events for `AskUserQuestion` (which can fire when the tool isn't in a user's allow list) are now auto-allowed instead of rendering a competing read-only preview behind the new clickable UI.

### Removed
- The "请在终端回答 / Answer in terminal" footer button under AskUQ options. The terminal remains the authoritative fallback path (after the 60-second soft timeout) but is no longer offered as a primary affordance.

## [0.2.7] — 2026-04-21

### Added
- **Show Dynamic Island toggle** — a checkmark item in the menu-bar right-click menu, the real-notch gear, and the simulated-notch gear. When off, the compact pill is fully ordered off-screen (not just transparent), and hover over the notch / screen top will not auto-expand it.
- When hidden, the panel still returns for: the global hotkey (default `⌘⇧/`), left-click on the menu-bar icon, `PermissionRequest`, session errors, and the welcome onboarding — each calls `orderFrontRegardless()` before expanding, then orders out again on collapse.
- Visibility persisted in `~/.zackeyes/config.json`; controllers receive initial visibility via init to avoid a startup flash.

### Changed
- Menu-bar icon: SF Symbol `sparkles` → `star.fill`, aligning with the app logo's five-point star. State tinting (`.idle` untinted / `.working` teal / `.waiting` orange) unchanged.

### Fixed
- `ConfigStore.saveNotchVisibility` now aborts when `config.json` exists but cannot be decoded, instead of seeding defaults and wiping `githubToken` / `theme` / `notificationSound`. Matches the spirit of the user-config preservation invariant.

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
