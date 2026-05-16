# ZackEyes

A native macOS Dynamic Island for AI coding agents. Watches every active **Claude Code** and **OpenAI Codex** session, surfaces permission requests, shows live usage limits, and lets you jump straight to the right terminal tab — all from a small floating panel at the top of the screen.

> Inspired by the Vibe Island product but built independently and free.

![status](https://img.shields.io/badge/status-MVP-green)
![platform](https://img.shields.io/badge/platform-macOS%2014%2B-blue)
![swift](https://img.shields.io/badge/swift-6-orange)
![deps](https://img.shields.io/badge/dependencies-zero-lightgrey)

## What it does

- **Real Dynamic Island** on Macs that have one, **simulated notch** at the top of the screen on Macs that don't.
- **Two agents, one notch.** Tracks every Claude Code and Codex CLI session in the same UI by installing into both `~/.claude/settings.json` and `~/.codex/hooks.json` — no manual setup, no per-project config. Every session card carries a `[Claude]` / `[Codex]` badge so you always know which agent you're acting on.
- **Permission approval in the notch.** When either agent wants to run a command, it pops out under the notch with the tool, command preview, and Allow/Deny buttons.
- **AskUserQuestion answers in the notch** (Claude). Numbered option cards instead of typing answers in the terminal.
- **Live usage limits** for both agents. 5h and 7d quota with progress bars and reset countdowns — Claude data comes from Claude Code's `statusLine` channel; Codex data comes from `event_msg.token_count.rate_limits` events in the rollout JSONL. The expanded panel splits the bars left/right when both agents are active; gear menu → "Compact display" picks which agent the always-visible pill shows.
- **Jump to the right terminal tab**: click a session and ZackEyes activates the exact iTerm2 / Terminal.app / Ghostty / Warp / Kitty / Alacritty / VS Code / Cursor tab where that agent is running.
- **Real-time fallback for already-running Codex.** Codex TUIs that started before ZackEyes was installed never load our hooks. The `CodexJsonlTailer` watches their rollouts and fires notifications on `task_complete` events without requiring a Codex restart.
- **Tagged notifications.** Time-sensitive macOS alerts when a session finishes a turn, hits a rate limit, or crashes — every title prefixed with `[Claude]` or `[Codex]` so you know who needs attention without opening the notch.
- **Personality**: every session gets a deterministic pixel-art rock musician (66+ legends from Queen to RATM). Buddies bounce when working, sleep when idle, panic-shake when waiting on you.
- **Multi-session**: tracks every concurrent agent window independently with its own state, tasks, and prompt history.
- **Tasks**: mirrors the Task tool's plan list with progress and status (Claude transcripts).
- **Customizable global hotkey**: defaults to `Cmd + Shift + Z`, changeable from the gear menu.
- **Update checker**: polls a public release repo every 6h, gear icon red badge + system notification when a new version is available; one-click in-app DMG download.
- **Zero third-party dependencies**: pure Foundation + AppKit + SwiftUI.

## Requirements

- macOS 14 (Sonoma) or newer
- Claude Code (`claude` CLI) and/or Codex CLI (`codex`) installed — ZackEyes installs hooks for whichever it finds, skips silently for ones it doesn't
- Xcode Command Line Tools (for building from source)

## Installing from source

```bash
git clone https://github.com/yangshiqi/ZackEyes.git
cd ZackEyes
make app
open .build/ZackEyes.app
```

On first launch ZackEyes will:

1. Read your `~/.claude/settings.json` (skip if Claude Code isn't installed) and your `~/.codex/hooks.json` (skip if Codex CLI isn't installed)
2. Append its hook entries to whichever exist (without touching anything else, full backup taken). Hook commands carry an `--agent claude|codex` flag so the bridge knows which agent fired which event.
3. For Claude only: install itself as Claude Code's `statusLine` handler if no other tool already owns it. If you want visible custom status text, create an executable `~/.zackeyes/bin/statusline-user`; ZackEyes will feed it the same stdin while still updating usage in the background. (Codex doesn't have a statusLine concept; quota data is read directly from Codex's rollout JSONL.)
4. Drop a launcher script at `~/.zackeyes/bin/bridge`

> **Codex caveat.** Codex caches its hook list when a thread starts, so a Codex TUI launched before ZackEyes won't fire hooks for that thread. ZackEyes still picks it up via `CodexJsonlTailer` (real-time JSONL watcher), so notifications and session cards work without a restart. Open a new Codex thread to get the full hook-driven path (PermissionRequest approval in the notch, etc.).

You'll be asked once for **Accessibility** permission (so it can focus the right terminal tab) and **Notifications** permission. Both are optional — the app degrades gracefully without them.

## Usage

| Action | Result |
|---|---|
| Hover over the notch | Panel expands, showing 5h / 7d limits + all sessions |
| Click a session card | The exact terminal tab running that Claude Code session jumps to the front |
| Click **Allow Once** / **Deny** on a permission request | Sends the decision back to Claude Code through the same hook |
| Click a numbered option on a `Claude's Question` card | Sends the answer back |
| `Cmd + Shift + Z` | Toggles the panel from anywhere |
| Click outside the panel | Collapses back to the compact pill |

## Architecture

Three components communicating over a Unix domain socket:

```
Claude Code                     Bridge CLI                    ZackEyes.app
(hooks in settings.json)  -->  (~/.zackeyes/bin/bridge)  <->  (SwiftUI + AppKit)
                                Swift binary                   /tmp/zackeyes.sock
```

| Layer | Module | Responsibility |
|---|---|---|
| Shared | `Sources/Shared` | Codable JSON types (`BridgeEvent`, `PermissionResponse`, `AgentKind`, `AnyCodable`) used by both bridge and app |
| Bridge CLI | `Sources/BridgeLib` + `Sources/Bridge` | Lightweight binary invoked by Claude Code AND Codex CLI hooks. Reads stdin, parses `--event` + `--agent`, forwards to socket, optionally waits for a permission decision, exits cleanly. Never blocks the calling agent. |
| App Library | `Sources/AppLib` | All app logic — socket server, session store, claude/codex hook installers, codex jsonl tailer, notch UIs, terminal locator, usage tracker, notifications, hotkey |
| App Entry | `Sources/ZackEyes` | Thin `NSApplication` entry point + `AppDelegate` wiring |

See `ARCHITECTURE.md` for the full component breakdown, data flows, and safety model.

### Safety guarantees

These invariants are enforced by both code review and tests:

1. **User config zero damage** — every write to `~/.claude/settings.json` and `~/.codex/hooks.json` is preceded by a timestamped backup, only `hooks` / `statusLine` keys are touched (Claude side; Codex side scaffolds the file fresh if absent), and a parse failure aborts the write. We **never** read or write `~/.codex/config.toml` (Codex enables hooks by default).
2. **Bridge never blocks the calling agent** — every controlled failure path exits with code 0 and writes nothing to stdout. Codex / Claude treat the empty stdout as "no hook preference" and fall back to their native flow.
3. **NotchPanel never steals focus** — `nonactivatingPanel`, `canBecomeMain` returns `false`, `ignoresMouseEvents` is true outside the interaction zone.
4. **Socket connections are not reused** — every hook call creates a fresh connection that closes when done.
5. **Hook entries are identifiable** — every command we install contains the literal string `zackeyes`, so uninstall is precise.
6. **Zero third-party dependencies** — Foundation, AppKit, SwiftUI only.

## Build commands

```bash
swift build                  # debug build
swift test                   # 102 swift-testing + 16 XCTest
make app                     # debug build + assemble .app bundle
make app-release             # release build + bundle
make run                     # build + open
make clean                   # clean SPM cache + bundle

# Manually fire a hook event for testing
echo '{"hook_event_name":"SessionStart","session_id":"test","cwd":"/tmp"}' | \
  $(swift build --show-bin-path)/bridge --event SessionStart --agent claude

# Same, simulating Codex
echo '{"hook_event_name":"Stop","session_id":"test","cwd":"/tmp","last_assistant_message":"done"}' | \
  $(swift build --show-bin-path)/bridge --event Stop --agent codex
```

## Project layout

```
Sources/
├── Shared/                       # Codable types shared by app and bridge
├── BridgeLib/                    # Bridge logic (testable)
├── Bridge/                       # CLI entry point
├── AppLib/                       # All app logic (testable)
│   ├── Config/                   # HotKeyConfig, ConfigStore
│   ├── Socket/
│   ├── Session/
│   ├── Hooks/
│   ├── Notch/                    # Real notch panel + HotkeyRecorderView
│   ├── SimulatedNotch/           # Simulated Dynamic Island
│   ├── MenuBar/
│   ├── HotKey/
│   ├── Notifications/
│   ├── Terminal/
│   ├── Update/                   # UpdateChecker (GitHub version detection)
│   └── Usage/
└── ZackEyes/                     # NSApplication entry point + AppDelegate

Tests/
├── SharedTests/
├── BridgeLibTests/
└── AppLibTests/
```

## Documentation

- [`ARCHITECTURE.md`](ARCHITECTURE.md) — component boundaries, data flow, safety model
- [`CHANGELOG.md`](CHANGELOG.md) — release history
- [`docs/superpowers/specs/`](docs/superpowers/specs/) — design specs
- [`CLAUDE.md`](CLAUDE.md) — agent harness instructions for working on this project
- [`AGENTS.md`](AGENTS.md) — development workflow

## License

MIT. Use it, fork it, ship a competing product. Just don't break Claude Code.
