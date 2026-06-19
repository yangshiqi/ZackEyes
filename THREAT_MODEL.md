# Threat Model: ZackEyes

## 1. System context

ZackEyes is a native macOS menu-bar / notch utility (Swift 6, macOS 14+, ~73
source files, zero third-party dependencies) that observes locally-running AI
coding agents — Claude Code and OpenAI Codex CLI — and surfaces their state in
the MacBook notch: live permission-approval prompts and `AskUserQuestion`
cards, 5h/7d usage bars, and one-click jump to the terminal tab where each
agent runs. It is distributed as an **ad-hoc-signed DMG** from the public
`yangshiqi/ZackEyes-release` GitHub repo (source lives in a separate private
repo); it is **not sandboxed, not notarized**, and ships no entitlements file.
An in-app updater polls the release repo every 6h and mounts the downloaded
DMG via Finder.

Architecturally it is three cooperating pieces communicating over a single
AF_UNIX stream socket at `/tmp/zackeyes.sock`: (1) a tiny `bridge` CLI,
registered as a hook command in `~/.claude/settings.json` and
`~/.codex/hooks.json`, which the agent invokes on every lifecycle event — it
reads the hook JSON from stdin, forwards it to the socket, and for
`PermissionRequest` / `AskUserQuestion` events **blocks waiting for the user's
allow/deny decision, which it returns on stdout for the agent to obey**; (2)
the main app (`AppLib`) holding the socket server, session store, hook
installers, a kqueue transcript tailer, the notch UI, a terminal locator that
drives other apps via the Accessibility and Apple Events APIs, the usage
tracker, and the update checker; (3) a generated `/bin/sh` launcher in
`~/.zackeyes/bin` that resolves and execs the embedded helper. The app runs
unsandboxed with the user's full privileges plus user-granted Accessibility
and Automation rights, and it reads agent transcript trees under
`~/.claude/projects` and `~/.codex/sessions`. The defining trust boundary is
the socket: whatever speaks its protocol can decide whether the coding agent
is allowed to run a given tool (including Bash and file writes).

## 2. Assets

| asset | description | sensitivity |
|---|---|---|
| Tool-authorization decision capability | The socket `PermissionRequest` path returns an allow/deny/allow-always decision the agent obeys verbatim (`SocketServer.handleConnection`, `SessionStore.resolvePermission`/`allowAlways`/`isToolAutoAllowed`). Whoever controls the reply can auto-approve arbitrary agent tool calls incl. Bash and file writes. | critical |
| Bridge IPC socket `/tmp/zackeyes.sock` | AF_UNIX SOCK_STREAM server (`SocketServer.swift`). Only guard is a `getpeereid` same-uid check plus `chmod 0600` on a world-known `/tmp` path recreated each start. | critical |
| Process integrity of the main app and `bridge` helper | `bridge` is wired into `settings.json` as a hook command and resolved at runtime by a generated launcher via `~/.zackeyes/.app-path` or `mdfind` (`HookInstaller.deployLauncherScript`). Tampering with the launcher, marker, or helper runs attacker code on every agent hook fire; the app also holds the AX/automation rights below. | critical |
| Accessibility (TCC) capability held by the app | `TerminalLocator` uses `AXUIElement` on **other** apps (terminals) to read titles and perform raise/press/focus — a system-wide capability to inspect and manipulate other apps' UI. | critical |
| Apple Events / Automation capability over terminals | `NSAppleScript` drives iTerm2 and Terminal.app; `NSAppleEventsUsageDescription` in `Info.plist`. Cross-app scripting capability. | high |
| Agent transcripts (`~/.claude/projects`, `~/.codex/sessions`) | JSONL transcripts containing user prompts, source code, assistant output, and tool inputs — frequently secrets/API keys. Parsed by `SessionScanner`/`UsageTracker` and held in `SessionStore` memory. | high |
| Live tool-call inputs and prompts on the socket | `BridgeEvent` (`EventProtocol.swift`) carries `tool_input`, `prompt`, `last_assistant_message`, `transcript_path`, `cwd`, `cost` for every event; surfaced into the notch UI. | high |
| Agent hook configuration (`~/.claude/settings.json`, `~/.codex/hooks.json`, statusLine mux) | `HookInstaller` rewrites these to register the bridge for 12 events + a statusline-mux shell script. Integrity = control over what runs on every agent lifecycle event. Timestamped backups written before each write. | high |
| Software-update channel (GitHub release → DMG → Finder) | `UpdateChecker`/`UpdateDownloader` fetch the latest release DMG and `NSWorkspace.open` it; no in-app signature/checksum verification. | high |
| `~/.zackeyes` config, caches, and pending-event spool | `config.json` (hotkey/theme), usage caches, `.app-path` marker, and `pending/*.json` which persists raw hook JSON for replay. | medium |
| Other processes' TTYs (OSC title writes) | `TerminalLocator.writeSessionTitle` / `TerminalTitleWriter` open the agent's tty and write OSC-2 escape sequences — an integrity surface for the targeted terminals. | medium |
| Global hotkey + notch UI availability | `HotKeyManager` registers a system-wide hotkey; the always-on notch overlay. Availability asset. | low |

## 3. Entry points & trust boundaries

| entry_point | description | trust_boundary | reachable_assets |
|---|---|---|---|
| EP1: Bridge unix socket (`/tmp/zackeyes.sock`) | AF_UNIX accept loop; newline-delimited JSON (64KiB cap) → `BridgeEvent`; `PermissionRequest` blocks and the peer's JSON reply becomes the allow/deny decision. Guard: `getpeereid` same-uid + `chmod 0600`. | another local process (any same-uid process) → app socket → agent tool-authorization decision | Tool-authorization decision capability, Bridge IPC socket, Live tool-call inputs and prompts |
| EP2: BridgeEvent / AnyCodable decode | Recursive type-erased JSON decode of socket/spool bytes; drives `requiresBlockingResponse` and is rendered as permission detail. | untrusted socket/spool JSON → app event model → permission UI + decision | Tool-authorization decision capability, Live tool-call inputs and prompts |
| EP3: Pending-event spool (`~/.zackeyes/pending/*.json`) | `bridge` spools lifecycle events when the app is down; on startup the app re-decodes every file as `BridgeEvent` through the **same** handler as the live socket. | file-at-rest JSON (`~/.zackeyes/pending`) → app event handler | Tool-authorization decision capability, ~/.zackeyes config/caches/spool |
| EP4: bridge stdin + argv | `FileHandle.standardInput` → `JSONSerialization`; `CommandLine.arguments` `--event`/`--agent`; forwarded to socket. Never-nonzero-exit invariant. | Claude/Codex hook (stdin JSON + argv) → bridge → app socket | Bridge IPC socket, Live tool-call inputs and prompts |
| EP5: Agent transcript readers (scanner + codex kqueue tailer) | Walk `~/.claude/projects` + `~/.codex/sessions` and tail active codex rollout jsonl; parse last assistant/user text + task events into the notch UI and notifications. | agent transcript files (LLM/tool output, attacker-influenceable) → app session UI + notifications | Agent transcripts, Other processes' TTYs, Global hotkey + notch UI availability |
| EP6: On-disk cache/config readers (`~/.zackeyes`) | `Data(contentsOf:)`/`String(contentsOfFile:)` + `JSONDecoder` on cached prompts, usage, pricing, config. | on-disk caches/config (same-uid writable) → app UI/state | ~/.zackeyes config/caches/spool, Global hotkey + notch UI availability |
| EP7: Process scan + terminal AX / Apple Events control | Spawns `/bin/ps` and `/usr/sbin/lsof` via argv arrays (no shell); `AXUIElementCreateApplication` on terminals reads `kAXTitle` and performs raise/press/focus; `NSAppleScript` drives iTerm2/Terminal. | local process table + other apps' AX tree → app actuates their windows; app holds Accessibility + Automation privilege | Accessibility capability, Apple Events / Automation capability, Other processes' TTYs |
| EP8: Generated hook launcher + `.app-path` marker + helper binary | Writes a `/bin/sh` launcher to `~/.zackeyes/bin` that resolves the app via `~/.zackeyes/.app-path` or `mdfind` and execs `Contents/Helpers/bridge` on every hook fire; rewrites agent hook configs. | same-uid-writable on-disk script/marker/binary → exec at every agent hook fire | Process integrity of app + bridge helper, Agent hook configuration |
| EP9: GitHub auto-update feed + DMG open | URLSession GET `api.github.com/.../ZackEyes-release/releases/latest` over HTTPS; first `.dmg` asset downloaded and `NSWorkspace.open`'d. No in-app signature/checksum/Gatekeeper check (ad-hoc signed, quarantine stripped). | remote GitHub release repo + DMG bytes → code execution on the user's machine | Software-update channel, Process integrity of app + bridge helper, Accessibility capability |
| EP10: Release publish pipeline (developer `gh` token) | `make release` builds + ad-hoc-signs the DMG and uploads to public `ZackEyes-release` via local `gh` CLI, self-merging its own PR with 0 reviews. The token is the entire publish authority. | developer workstation credential → public distribution repo all users pull from | Software-update channel, Process integrity of app + bridge helper |
| EP11: Untrusted-text sinks (notifications + OSC2 terminal titles) | Untrusted prompt/transcript text rendered into macOS notification bodies and OSC-2 terminal tab-title escape sequences written to other process ttys; also `AnyCodable` `tool_input` rendered in the notch. | untrusted agent/user text → notification UI / other process tty / notch UI | Other processes' TTYs, Live tool-call inputs and prompts |

## 4. Threats

| id | threat | actor | surface | asset | impact | likelihood | status | controls | evidence |
|---|---|---|---|---|---|---|---|---|---|
| T1 | A local process forges or injects agent events over the bridge socket or pending-event spool to auto-approve arbitrary agent tool calls (incl. Bash, file writes) or spoof session state | local_user | EP1, EP2, EP3 | Tool-authorization decision capability, Bridge IPC socket | critical | likely | partially_mitigated | `getpeereid` same-uid check + `chmod 0600` (closes cross-uid; same-uid trusted by design, so any same-uid process — e.g. a compromised dependency in a project the user runs an agent in — still qualifies) | aba2176 (F-001/F-002) |
| T2 | A malicious or tampered software update is auto-installed because the downloaded DMG is opened with no in-app signature or checksum verification, yielding code execution on every user's machine | supply_chain | EP9, EP10 | Software-update channel, Process integrity of app + bridge helper, Accessibility capability | critical | possible | unmitigated | HTTPS/TLS to GitHub only (protects transport, not artifact integrity); ad-hoc signing, no notarization; single developer `gh` token is the entire publish authority with solo self-merge | |
| T3 | Code execution / persistence by tampering with the generated launcher script, the `~/.zackeyes/.app-path` marker, or the helper binary in same-uid-writable paths so attacker code runs on every agent hook fire | local_user | EP8 | Process integrity of app + bridge helper, Agent hook configuration | high | possible | unmitigated | none specific (relies on default filesystem permissions; launcher resolves the app via writable `~/.zackeyes/.app-path` or `mdfind`) | |
| T4 | Hijack of the app's user-granted Accessibility and Apple Events privileges to inspect and manipulate other applications' UI and script terminals, once app integrity is compromised | local_user | EP7 | Accessibility capability, Apple Events / Automation capability | high | possible | partially_mitigated | TCC permission prompts; Accessibility request deferred to first terminal-jump (reduces grant surface); no extra control once granted | |
| T5 | Terminal-escape, notification, and UI injection/spoofing via untrusted agent prompt and transcript text rendered into OSC2 terminal titles, macOS notifications, and the notch | remote_unauth | EP5, EP11 | Other processes' TTYs, Live tool-call inputs and prompts | medium | likely | partially_mitigated | `sanitizePrompt()` strips control chars / XML in the known notification + OSC2 sinks | cf61a5d, 4754dba |
| T6 | Disclosure of sensitive agent transcript content (prompts, source code, secrets/API keys) held in app memory or persisted as raw hook JSON in the pending-event spool, to a same-uid local actor | local_user | EP5, EP6 | Agent transcripts, ~/.zackeyes config/caches/spool | medium | possible | partially_mitigated | diagnostics export is fixed-schema and redacted (`Redactor`: home→`~`, username→`<user>`), never uploaded; but in-memory `SessionStore` and the on-disk pending spool are unprotected beyond default file perms | |
| T7 | Denial of service / UI lock via oversized transcript files, unbounded cache reads, or a stuck blocking `PermissionRequest` with no wall-clock timeout | local_user | EP1, EP4, EP5, EP6 | Global hotkey + notch UI availability | low | likely | partially_mitigated | 256MB per-file ceiling on the recursive transcript scan | aba2176 (F-008) |

## 5. Deprioritized

| threat | reason |
|---|---|
| On-path (MITM) tampering of the update feed | Feed and asset downloads are HTTPS to api.github.com / GitHub; the realistic vector is release-repo or publish-token compromise, captured in T2 — not network interception. |
| Website XSS via outdated Astro dependencies (fcc2d21) | Outside the app trust boundary; affects only the static marketing site (`website/`), not the distributed app binary. Already patched. |
| Diagnostics / support-bundle data leak | User-triggered only, fixed schema, run through `Redactor` (home→`~`, username→`<user>`), never uploaded, emits no prompt/assistant/tool content. |
| Global hotkey hijack / contention | OS-mediated Carbon hotkey registration; racing for the combo is low value and not meaningfully attacker-controllable. |
| Repudiation of config changes | Single-user local tool; every `settings.json`/`hooks.json` write is preceded by a timestamped backup. Not a meaningful threat here. |
| `dependabot.yml` monitors nothing (empty `package-ecosystem`) | Hygiene gap with no direct exploit; surfaced as an open question rather than a threat row. |

## 6. Open questions

- **Is the same-uid trust assumption acceptable?** The socket is gated by
  `getpeereid` but explicitly trusts any process running as the same user —
  including a compromised dependency in any project the user runs an agent in.
  That is the central risk-appetite decision for T1.
- **Will distribution move to Developer-ID + notarization,** or are users
  expected to keep stripping `com.apple.quarantine`? This decides whether
  Gatekeeper can ever catch a tampered build (T2).
- **Is there any plan to verify the DMG signature/checksum in-app** before
  `NSWorkspace.open`? The published SHA-256 is currently display-only website
  copy the app never checks (T2).
- **Who can push to `yangshiqi/ZackEyes-release`,** is the publish token on a
  workstation, and is there branch protection / required review / hardware 2FA?
  (T2)
- **Should the pending-event spool be permission-restricted or not persist raw
  prompt content,** given it stores untrusted hook JSON on disk (T6)?
- **Is a wall-clock ceiling intended for the blocking `PermissionRequest`,** or
  can a hung peer hold the UI open indefinitely (T7)?
- **Is the `dependabot.yml` misconfiguration (empty `package-ecosystem`)
  intentional?** As written it monitors nothing.

## 7. Provenance

- mode: bootstrap
- date: 2026-06-18
- target: /Users/ysq/Work/lab/ZackEyes @ fee53b1
- inputs: git-log + CHANGELOG mined (no `--vulns` supplied)
- owner: unset

## 8. Recommended mitigations

| mitigation | threat_ids | closes_class | effort |
|---|---|---|---|
| Centralize all untrusted-text rendering through one boundary sanitizer (strip/escape C0 control chars and markup once at ingestion) instead of patching each sink | T5 | yes | S |
| Size-cap and wall-clock-timeout every untrusted read and the blocking socket wait | T7 | yes | S |
| Restrict `~/.zackeyes` to `0700` and stop persisting raw prompt/transcript content in the pending spool; minimize secret lifetime in `SessionStore` | T6 | partial | S |
| Verify update-artifact integrity in-app before `NSWorkspace.open` (compare published SHA-256 and/or require Developer-ID signature + notarization); harden publish authority (branch protection + required review, scoped short-lived token, hardware 2FA) | T2 | partial | M |
| Verify the code signature of the resolved `bridge` binary before the launcher execs it; store the helper path/marker where it is not writable post-install; drop the `mdfind` fallback | T3, T4 | partial | M |
| Treat the socket as a semi-trusted channel: move it from world-known `/tmp` to a `0700` user-private dir and add an install-time per-connection token the bridge must present, instead of relying on same-uid == trusted | T1 | partial | M |
