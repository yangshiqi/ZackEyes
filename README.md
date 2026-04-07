# ZackEyes

A native macOS Dynamic Island for Claude Code. Watches every active session, surfaces permission requests, shows live usage limits, and lets you jump straight to the right terminal tab — all from a small floating panel at the top of the screen.

> Inspired by the Vibe Island product but built independently and free.

![status](https://img.shields.io/badge/status-MVP-green)
![platform](https://img.shields.io/badge/platform-macOS%2014%2B-blue)
![swift](https://img.shields.io/badge/swift-6-orange)
![deps](https://img.shields.io/badge/dependencies-zero-lightgrey)

## What it does

- **Real Dynamic Island** on Macs that have one, **simulated notch** at the top of the screen on Macs that don't.
- **Tracks every Claude Code session** by hooking into Claude Code's settings.json — no manual setup, no per-project config.
- **Permission approval in the notch**: when Claude wants to run a command, it pops out under the notch with the tool, command preview, and Allow/Deny buttons.
- **AskUserQuestion answers in the notch**: numbered option cards instead of typing answers in the terminal.
- **Live usage**: 5 hour and 7 day plan limits with progress bars and reset countdowns. Pulled from Claude Code's `statusLine` channel — same data Claude Code itself uses.
- **Jump to the right terminal tab**: click a session and ZackEyes activates the exact iTerm2 / Terminal.app / Ghostty / Warp / Kitty / Alacritty / VS Code / Cursor tab where that Claude is running.
- **Notifications**: time-sensitive macOS alerts when a session finishes a turn, hits a rate limit, or crashes.
- **Personality**: every session gets a deterministic pixel-art rock musician (66+ legends from Queen to RATM). Buddies bounce when working, sleep when idle, panic-shake when waiting on you.
- **Multi-session**: tracks every concurrent Claude Code window independently with its own state, tasks, and prompt history.
- **Tasks**: mirrors the Task tool's plan list with progress and status.
- **Cmd + Shift + Z** global hotkey toggles the panel from anywhere.
- **Zero third-party dependencies**: pure Foundation + AppKit + SwiftUI. About 46MB binary.

## Requirements

- macOS 14 (Sonoma) or newer
- Claude Code installed (`claude` CLI)
- Xcode Command Line Tools (for building from source)

## Installing from source

```bash
git clone https://github.com/yangshiqi/ZackEyes.git
cd ZackEyes
make app
open .build/ZackEyes.app
```

On first launch ZackEyes will:

1. Read your `~/.claude/settings.json`
2. Append its hook entries (without touching anything else, full backup taken)
3. Install itself as Claude Code's `statusLine` handler if no other tool already owns it
4. Drop a launcher script at `~/.zackeyes/bin/bridge`

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
| Shared | `Sources/Shared` | Codable JSON types (`BridgeEvent`, `PermissionResponse`, `AnyCodable`) used by both bridge and app |
| Bridge CLI | `Sources/BridgeLib` + `Sources/Bridge` | Lightweight binary invoked by Claude Code hooks. Reads stdin, forwards to socket, optionally waits for a permission decision, exits cleanly. Never blocks Claude Code. |
| App Library | `Sources/AppLib` | All app logic — socket server, session store, hook installer, notch UIs, terminal locator, usage tracker, notifications, hotkey |
| App Entry | `Sources/ZackEyes` | Thin `NSApplication` entry point + `AppDelegate` wiring |

See `ARCHITECTURE.md` for the full component breakdown, data flows, and safety model.

### Safety guarantees

These six invariants are enforced by both code review and tests:

1. **User config zero damage** — every write to `~/.claude/settings.json` is preceded by a timestamped backup, only the `hooks` and `statusLine` keys are touched, and a parse failure aborts the write.
2. **Bridge never blocks Claude Code** — every failure path exits with code 1 (non-blocking error). Exit code 2 is never used.
3. **NotchPanel never steals focus** — `nonactivatingPanel`, `canBecomeMain` returns `false`, `ignoresMouseEvents` is true outside the interaction zone.
4. **Socket connections are not reused** — every hook call creates a fresh connection that closes when done.
5. **Hook entries are identifiable** — every command we install contains the literal string `zackeyes`, so uninstall is precise.
6. **Zero third-party dependencies** — Foundation, AppKit, SwiftUI only.

## Build commands

```bash
swift build                  # debug build
swift test                   # 23 unit tests
make app                     # debug build + assemble .app bundle
make app-release             # release build + bundle
make run                     # build + open
make clean                   # clean SPM cache + bundle

# Manually fire a hook event for testing
echo '{"hook_event_name":"SessionStart","session_id":"test","cwd":"/tmp"}' | \
  $(swift build --show-bin-path)/bridge --event SessionStart
```

## Project layout

```
Sources/
├── Shared/                       # Codable types shared by app and bridge
├── BridgeLib/                    # Bridge logic (testable)
├── Bridge/                       # CLI entry point
├── AppLib/                       # All app logic (testable)
│   ├── Socket/
│   ├── Session/
│   ├── Hooks/
│   ├── Notch/                    # Real notch panel
│   ├── SimulatedNotch/           # Simulated Dynamic Island
│   ├── MenuBar/
│   ├── HotKey/
│   ├── Notifications/
│   ├── Terminal/
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
