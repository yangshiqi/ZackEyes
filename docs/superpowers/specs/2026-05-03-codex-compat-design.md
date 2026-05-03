# Codex Compatibility Design

**Date**: 2026-05-03
**Branch**: `feat/codex-compat`
**Status**: implementing

## Goal

Add OpenAI Codex CLI as a parallel agent alongside Claude Code. Sessions from
both agents render in the notch concurrently; PermissionRequest approvals work
for both; one Bridge binary serves both. No regression for Claude-only users.

## Non-goals (deferred to follow-up PRs)

- Auto-edit `~/.codex/config.toml` (the `[features].hooks` flag is `default_enabled: true`
  in current Codex; we never read or write `config.toml`).
- Codex-side AskUserQuestion replacement (Codex has no equivalent tool).
- `apply_patch` / `mcp__*` tool-name specialization in the notch UI (v1 displays
  the raw tool name).
- Codex transcript-token estimation for the per-agent usage progress bar (header
  layout supports it; the data source lands in a follow-up).
- `runningCodexCwds()` + Codex liveness pruning. Today, codex sessions
  bypass `LivenessFilter` entirely (both at startup import and the periodic
  sweep) — there's no equivalent of `TerminalLocator.runningClaudeCwds()`
  for codex yet, so we couldn't reliably tell a live codex session from a
  ghost one. Acceptable side effect: a stopped codex session lingers as a
  detected card until the app restarts. Once `runningCodexCwds()` lands we
  can fold codex into the normal liveness paths. (Both the sweep gap and
  the import-time pass-through were flagged by `/codex review` of this
  branch, 2026-05-03.)

## Codex hook surface (research summary, 2026-05-03)

Source of truth: <https://developers.openai.com/codex/hooks> +
`openai/codex` source (`codex-rs/features/src/lib.rs`, `codex-rs/hooks/`).

| Aspect | Codex | Claude (existing) |
|---|---|---|
| Config file | `~/.codex/hooks.json` (or `[hooks]` in `config.toml`) | `~/.claude/settings.json` |
| Feature flag | `[features].hooks = true` (alias `codex_hooks`), **default `true`** | n/a |
| Events | SessionStart, PreToolUse, PostToolUse, PermissionRequest, UserPromptSubmit, Stop | + SessionEnd, Notification, StatusLine |
| Stdin common fields | session_id, cwd, hook_event_name, transcript_path, model, turn_id | session_id, cwd, hook_event_name, transcript_path |
| PreToolUse block | `{permissionDecision:"deny", permissionDecisionReason}` | `{permissionDecision:"deny"}` (same) |
| PermissionRequest response | `{hookSpecificOutput:{hookEventName,decision:{behavior:"allow"\|"deny",message}}}` | `{hookSpecificOutput:{hookEventName,decision:{behavior,message}}}` (~same nesting) |
| Exit codes | 0 = continue; 2 = block w/ stderr | identical |
| Session log path | `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` | `~/.claude/projects/*/...jsonl` |

The two PermissionRequest response shapes turn out to be the same nested
structure — Codex docs and Claude both wrap as
`hookSpecificOutput → decision → {behavior, message}`. **No translation logic
required at the Bridge stdout layer.** Existing `PermissionResponse.encoded()`
emits the right shape for both.

## Architecture (delta only)

```
Claude Code  ──┐                                     ┌──> SocketServer
               ├── ~/.zackeyes/bin/bridge ───────────┤    (single socket)
Codex CLI    ──┘     --event X --agent {claude|codex}     │
                     SAME BINARY                          ▼
                                                    SessionStore
                                                    (Session.agent: AgentKind)
                                                          │
                                                          ▼
                                                    NotchExpandedView
                                                    (AgentBadge per card)
```

**Invariants preserved**: Bridge silent failure (exit 0), single socket, no
third-party deps, hook entries identifiable by `zackeyes` substring, never
edits config.toml.

## Module changes

| File | Change |
|---|---|
| `Sources/Shared/EventProtocol.swift` | Add `AgentKind` enum + `BridgeEvent.agent` (`_bridge_agent` JSON key). Default `.claude` on decode of legacy events. |
| `Sources/Bridge/main.swift` | Parse optional `--agent`. Inject `_bridge_agent`. Args parser tolerates length 3 (`--event X`) or length 5 (`--event X --agent Y`). |
| `Sources/AppLib/Hooks/HookFileWriter.swift` | **new** — backup + atomic write helper. |
| `Sources/AppLib/Hooks/HookInstaller.swift` | Renamed conceptually to **Claude** installer; existing class kept as `HookInstaller` (back-compat naming) but its `installHooks` writes `--agent claude` into command. |
| `Sources/AppLib/Hooks/CodexHookInstaller.swift` | **new** — writes `~/.codex/hooks.json`, six events, `--agent codex` in command. Same backup / parse-fail / preserve-user-content behavior as Claude installer. |
| `Sources/AppLib/AppDelegate.swift` | Boot `CodexHookInstaller` alongside Claude installer. |
| `Sources/AppLib/Session/SessionStore.swift` | `SessionInfo.agent: AgentKind = .claude`. `handleEvent` reads `event.agent` and stamps the session. `importDetectedSessions` propagates `agent` from `DetectedSession`. Codex sessions never get StatusLine fields. |
| `Sources/AppLib/Session/SessionScanner.swift` | Walks both `~/.claude/projects/<encoded-cwd>/<id>.jsonl` and `~/.codex/sessions/YYYY/MM/DD/rollout-<ts>-<uuid>.jsonl`. Codex session id parsed from filename UUID; cwd from the head `session_meta` line; last user prompt from tail `event_msg{type:user_message}` events. Returns merged `[DetectedSession]` sorted by mtime. |
| `Sources/AppLib/Session/LivenessFilter.swift` | `filterLiveDetected` partitions detected list by agent: claude path runs the existing claude-cwd filter; codex sessions pass through unchanged (no `runningCodexCwds()` yet). |
| `Sources/AppLib/Notch/AgentBadge.swift` | **new** — 14x14 SwiftUI view, claude (purple sparkles) / codex (green dot). |
| `Sources/AppLib/Notch/NotchExpandedView.swift` | Insert `AgentBadge(agent:)` to the right of session displayName. |

## Bridge backwards-compat

- Old hook entries lack `--agent`. Bridge defaults to `claude` when absent so
  upgrading users don't break between app launch and the next HookInstaller
  reinstall sweep. (HookInstaller runs on every app launch and rewrites Claude
  entries to include `--agent claude` explicitly.)

## Hook entry format

Claude (`~/.claude/settings.json`):
```json
{
  "hooks": {
    "PreToolUse": [
      {"hooks":[{"type":"command","command":"$HOME/.zackeyes/bin/bridge --event PreToolUse --agent claude"}]}
    ]
  }
}
```

Codex (`~/.codex/hooks.json`):
```json
{
  "hooks": {
    "PreToolUse": [
      {"hooks":[{"type":"command","command":"$HOME/.zackeyes/bin/bridge --event PreToolUse --agent codex"}]}
    ]
  }
}
```

Codex events installed: `PreToolUse`, `PostToolUse`, `PermissionRequest`,
`SessionStart`, `Stop`, `UserPromptSubmit`. (No `SessionEnd`, `Notification`,
or `StatusLine` — Codex doesn't define them.)

## Test plan

- `SharedTests/EventProtocolTests.swift`: BridgeEvent encode/decode round-trip
  with `agent: .codex`; legacy event without `_bridge_agent` decodes as
  `.claude`.
- `BridgeLibTests`: argument parsing — missing `--agent` defaults claude;
  explicit codex; malformed args still exit 0 (existing).
- `AppLibTests/CodexHookInstallerTests.swift`: install creates 6 events;
  uninstall removes only our entries; preserves existing user hooks; backup
  written; JSON parse failure no-op.
- Existing `HookInstallerTests` continue to pass; commands now include
  `--agent claude` (assertion update).

## Migration

Existing Claude users on update:
1. App launches; HookInstaller sees old entries (without `--agent`), removes
   them via `isZackEyesEntry` matcher (still triggers on `zackeyes` substring),
   writes new entries with explicit `--agent claude`. Backup written.
2. CodexHookInstaller writes `~/.codex/hooks.json` if `~/.codex/` exists; skips
   silently otherwise (mirrors Claude's "skip if `~/.claude/` doesn't exist"
   pattern).
