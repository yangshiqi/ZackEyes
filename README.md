# ZackEyes

A native macOS Dynamic Island for AI coding agents. Watches every active **Claude Code** and **OpenAI Codex** session, surfaces permission requests, shows live usage limits, and lets you jump straight to the right terminal tab — all from a small floating panel at the top of the screen.

[![License](https://img.shields.io/github/license/yangshiqi/zackeyes?color=blue)](./LICENSE)
[![Last Commit](https://img.shields.io/github/last-commit/yangshiqi/zackeyes)](https://github.com/yangshiqi/ZackEyes/commits)
[![Stars](https://img.shields.io/github/stars/yangshiqi/zackeyes?style=social)](https://github.com/yangshiqi/ZackEyes/stargazers)

![status](https://img.shields.io/badge/status-MVP-green)
![platform](https://img.shields.io/badge/platform-macOS%2014%2B-blue)
![swift](https://img.shields.io/badge/swift-6-orange)
![deps](https://img.shields.io/badge/dependencies-zero-lightgrey)

## What it does

- **Real Dynamic Island** on Macs that have one, **simulated notch** at the top of the screen on Macs that don't.
- **Two agents, one notch.** Tracks every Claude Code and Codex CLI session in the same UI by installing into both `~/.claude/settings.json` and `~/.codex/hooks.json` — no manual setup, no per-project config. Every session card carries a `[Claude]` / `[Codex]` badge so you always know which agent you're acting on.
- **Permission approval in the notch.** When either agent wants to run a command, it pops out under the notch with the tool, command preview, and Allow/Deny buttons.
- **AskUserQuestion answers in the notch** (Claude). Numbered option cards instead of typing answers in the terminal.
- **Live usage limits** for both agents. 5h and 7d quota with progress bars and reset countdowns — Claude data comes from Claude Code's `statusLine` channel; Codex data comes from `event_msg.token_count.rate_limits` events in the rollout JSONL. Readings at least 15 minutes old gain a `~` prefix; hover over a reading for its last update age (v0.10.0). The expanded panel splits the bars left/right when both agents are active; Settings → General → "Preferred quota source" chooses which agent the always-visible pill favors when both are available.
- **Jump to the right terminal tab**: click a session and ZackEyes activates the exact iTerm2 / Terminal.app / Ghostty / Warp / Kitty / Alacritty / VS Code / Cursor tab where that agent is running. When nothing matches, the card says why (`no window`, `grant access`) instead of failing silently.
- **Ports, branch, and dirty state on the card.** Each session shows the lowest `LISTEN` port opened anywhere in its process subtree (`:3000 +2` when there are more) alongside its git branch and uncommitted count (`⑂ main ●3`). Ports come from pure kernel syscalls — no `lsof`, no subprocess, ~3ms for every session at once.
- **Subagents in flight** (Claude): the card shows what a dispatched subagent is actually doing (`Locate the theme color sourc…`), not just that one is running.
- **Context compaction stops looking like a hang.** `Compacting context…` while it runs, `Context compacted ×N` for a minute after it finishes — for both auto and manual `/compact`.
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

## Model compatibility (v0.9.7)

v0.9.7 includes these model and protocol improvements:

- **Codex GPT-6.1 Sol / GPT-6 Astra** — observed reasoning effort, request-aware service-tier and long-request cost estimates, concurrent tools, interruption/subagent lifecycle and compaction events. [PR #252](https://github.com/yangshiqi/ZackEyes/pull/252), [Epic #243](https://github.com/yangshiqi/ZackEyes/issues/243).
- **Claude Fable 5/5.1, Opus 5/5.5 and Sonnet 5/5.5** — observed effort/model changes, updated prices, actual fast-response and cache TTL billing, separate tool/API failures and parent-safe completion notifications. [PR #258](https://github.com/yangshiqi/ZackEyes/pull/258), [Epic #254](https://github.com/yangshiqi/ZackEyes/issues/254).

Effort appears only when the CLI reports it; startup model recovery does not infer effort. Daily costs are API list-price estimates, not subscription invoices. Codex estimates depend on available request metadata/history; Claude card cost uses the CLI-reported total. Unknown model prices remain unpriced. See the [Codex spec](docs/superpowers/specs/2026-10-08-gpt6-codex-support.md) and [Claude spec](docs/superpowers/specs/2026-10-08-claude-model-protocol-support.md) for protocol boundaries and verification.

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
swift test                   # full Swift Testing + XCTest suite
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

### v0.10.0 — released features (#265)

v0.10.0 includes all five items: opt-in supported Claude question answers with timeout/terminal fallback (#260, PR #266), SSH remote observation (#261, PR #270), demo mode (#262, PR #267), local usage history (#263, PR #269) and stale quota hints (#264, PR #268). These features, daily Usage archives and the final UI corrections are included in the v0.10.0 release. See [release preparation](docs/releases/v0.10.0-preparation.md) and [English release notes](docs/releases/v0.10.0-notes.md). See the [roadmap](https://zackeyes.vercel.app/roadmap) for the current release and future plans.

### SSH remote observation (v0.10.0)

Add up to eight named SSH aliases or `user@hostname` destinations in **Settings → Remote Hosts**. ZackEyes keeps one foreground SSH stream per enabled host, reconnects after a drop, and shows connection status and host identity alongside observed Claude/Codex sessions. Remote questions and approvals must be handled in the remote terminal; the cards have no local approval or terminal-jump actions.

Build on the remote Linux or macOS machine using Swift 6, then install the headless executable:

```bash
swift build -c release --product zackeyes-stream
mkdir -p ~/.local/bin
install -m 755 .build/release/zackeyes-stream ~/.local/bin/zackeyes
```

Before adding a host, verify key authentication and its host key yourself. A custom port, identity or jump host can be defined in your existing SSH alias. Then test the stream:

```bash
ssh your-host '~/.local/bin/zackeyes --stream'
```

The stream emits metadata-only JSON snapshots every five seconds: project/path, model, tool name, observed state and last activity. It sends no prompts, replies, tool arguments, permissions or credentials. Recent transcripts (Claude 8h / Codex 30m) are observations, not proof that a remote process is running. There is no remote daemon, application listening port or hook installation; closing SSH ends the stream. Missing or unsupported remote binaries, untrusted keys and authentication failures appear as host errors.

The Mac uses the system SSH client with public-key authentication, strict host-key checking and no password prompts or automatic trust updates. Hosts are stored only in `~/.zackeyes/remote-hosts.json`; ZackEyes does not change SSH or agent configuration. Remote sessions do not enter the local usage ledger, journal or quota readings. When Active remains reachable for connecting/error hosts even without local sessions; Hidden suppresses remote-driven expansion. This feature is included in v0.10.0.

### Local usage history (v0.10.0)

Open **Settings → Usage** for 7/30/90-day token and estimated agent-hour charts, per-agent totals, cache hit rate, project/model/tool rankings and an hourly activity heatmap. Charts cover complete local days **through yesterday**; today is unsettled. While the app is running, background settlement starts at or after 03:00; startup catches up after sleep or time offline. Initial automatic coverage is the last three completed days, with recent-day corrections thereafter.

Settings reads daily archives, so refreshing or switching periods does not scan transcripts. **Update now** corrects completed days. **Import saved history** migrates the previous ledger without changing it; **Import older transcripts** adds earlier available history. Large first imports can take time; **Pause** and **Resume** keep committed progress, including across restarts. Counts survive source removal. The incremental database and archives stay under `~/.zackeyes/usage/`, with private permissions; only counts, bounded project/model/tool names, hashed identities and timing metadata are stored. No prompts, replies or tool arguments are stored or uploaded. Existing live Today/quota indicators are independent.

Tokens exclude cache reads; cache hit rate compares reused input against all input. Hours merge recorded task/tool intervals and subtract known question waits. Missing boundaries use activity gaps capped at five minutes; long idle gaps and unclosed activity are not stretched to the scan time. Unobserved approval waits may still be included, so hours are estimates, not billing or time tracking. Parallel sessions add agent-hours. Hover either daily chart to see its full date, weekday and per-agent values. Dates and heatmap hours follow your current local timezone. Unavailable/deleted source history cannot be backfilled; the page reports incomplete scans or storage errors.

History directories/files must be private (`0700`/`0600`); broad permissions, symlinks and unsupported history formats are rejected without replacing the file. Damaged JSONL rows are reported and skipped so later valid observations remain readable. This feature is included in v0.10.0.

### Demo mode (v0.10.0)

Choose **Demo mode** in the menu-bar or notch gear menu to explore a sample Claude/Codex fleet. Working, needs-you and idle sessions cycle every six seconds; sample approvals and questions are interactive. DEMO labels distinguish the sample sessions, while account quota readings retain their normal data source. Real questions, approvals or errors return the panel to the live session view automatically.

Click **Exit demo** or toggle the menu item to return to your current real sessions. The mode lasts only for the current app run. For a new local app process:

```bash
make app
.build/ZackEyes.app/Contents/MacOS/ZackEyes --demo
```

If ZackEyes is already running, use its menu toggle. Demo mode is included in v0.10.0.

## Project layout

```
Sources/
├── RemoteCore/                   # Portable metadata protocol and observer
├── RemoteStream/                 # Headless zackeyes-stream executable
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
│   ├── Remote/                   # SSH host configuration, transport, manager and UI
│   ├── Process/                  # ProcessTreeInspector (ports), GitStatusReader
│   ├── Terminal/
│   ├── Update/                   # UpdateChecker (GitHub version detection)
│   └── Usage/
└── ZackEyes/                     # NSApplication entry point + AppDelegate

Tests/
├── RemoteCoreTests/
├── SharedTests/
├── BridgeLibTests/
└── AppLibTests/

website/                              # Product site at zackeyes.vercel.app (Astro 7, static)
```

## Website

The product landing page at [zackeyes.vercel.app](https://zackeyes.vercel.app) lives in [`website/`](./website). It's an Astro 7 static site that consumes release metadata from [`website/src/lib/release.mjs`](./website/src/lib/release.mjs), kept in sync by `make release` via [`Scripts/bump-website-release.sh`](./Scripts/bump-website-release.sh). See [`website/README.md`](./website/README.md) for local dev and deploy notes.

## Documentation

- [`ARCHITECTURE.md`](ARCHITECTURE.md) — component boundaries, data flow, safety model
- [Release notes](https://zackeyes.vercel.app/changelog) — current changelog (source: `website/src/pages/changelog.astro`); [`CHANGELOG.md`](CHANGELOG.md) is frozen at v0.3.x
- [`docs/superpowers/specs/`](docs/superpowers/specs/) — design specs
- [`CLAUDE.md`](CLAUDE.md) — agent harness instructions for working on this project
- [`AGENTS.md`](AGENTS.md) — development workflow

## Alternatives

A few similar tools, so you can pick the right one:

- [Vibe Island](https://vibeisland.app) — the paid original ($19.99 one-time): 30 agents, 20+ terminals, SSH remote monitoring. It offers broader agent coverage; ZackEyes includes read-only SSH observation. [Full comparison](https://zackeyes.vercel.app/vs-vibe-island)
- [open-vibe-island](https://github.com/Octane0411/open-vibe-island) — free and open source (GPL v3): 10+ agents, broad terminal coverage. Pick it if you need Cursor / Gemini CLI / OpenCode and don't mind copyleft. [Full comparison](https://zackeyes.vercel.app/vs-open-vibe-island)
- [Hallmonitor](https://github.com/hiteshbandhu/hallmonitor) — free and MIT like ZackEyes, with SSH multi-machine monitoring and a terminal dashboard. Both include remote monitoring; ZackEyes also includes opt-in supported Claude question answers, local Usage archives and USD cost tracking. [Full comparison](https://zackeyes.vercel.app/vs-hallmonitor)

ZackEyes is the pick when your workflow is Claude Code + Codex CLI and you want per-session USD cost tracking, themes with matching sounds, and a permissive MIT licence — free forever.

## License

MIT. Use it, fork it, ship a competing product. Just don't break Claude Code.

### Daily work journal (planned for v0.11.0)

The #214 local pipeline exists for development and testing, but setup, publishing and scheduling are unfinished. The public “Generate Today’s Journal” menu action has been removed. Journal generation is not included in v0.10.0.
