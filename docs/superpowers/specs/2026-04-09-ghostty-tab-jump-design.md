# Ghostty Tab & Split-Pane Click-to-Jump — Design

**Date**: 2026-04-09
**Status**: Revised post-verification — implementation in progress
**Scope**: Bridge OSC2 title injection + TerminalLocator Ghostty-specific jump path

## Revision history

- **2026-04-09 v1**: initial design assuming Ghostty exposes per-pane
  `AXUIElement` children with distinct titles (Layer A = AX tree walk)
- **2026-04-09 v2**: post-verification rewrite. AX dump confirmed
  Ghostty uses a **single top-level AXWindow** containing an
  `AXTabGroup` with one `AXTabButton` per tab; panes exist
  (`AXGroup > AXScrollArea > AXTextArea`) but have **no titles**.
  Layer A rewritten to enumerate AXTabButtons directly. Added
  Layer A' (brute-force tab + pane cycling via CGEvent) to cover
  the split-pane + non-focused case. Layer B (Window menu AXPress)
  removed as redundant with Layer A.

## Problem

Clicking a session card in the notch popup currently fails to land precisely inside Ghostty:

- **iTerm2 / Apple Terminal** — works precisely via AppleScript + tty
  matching (`TerminalLocator.focusITerm2` / `focusAppleTerminal`)
- **Ghostty / Warp / Kitty / Alacritty** — `focusByAccessibility` only
  scores window titles against `cwd` and calls `AXRaise`, which at best
  brings the tab group forward but does not switch to the correct tab
  inside the group, and cannot reach panes inside a split

For a Ghostty user with multi-tab, multi-split workflows this is
effectively broken: clicking a session card activates Ghostty but leaves
the user on the previously focused tab/pane.

The feature must be implemented without depending on Vibe Island (the
commercial app ZackEyes is a free replacement for). Vibe Island solves
this, but its mechanism is closed-source; this spec describes an
independent implementation inspired by what we can observe from the
outside.

## Goals

- Click a session card → land in the exact Ghostty tab **and** pane
  where that claude session is running
- Work when the target pane is *not* the currently focused pane of its
  tab (the split-pane case)
- Zero regression on iTerm2 / Apple Terminal paths
- Zero new third-party dependencies; zero new SPM targets
- Bridge remains non-blocking under all failure modes (`exit(0)` or
  `exit(1)`, never `exit(2)`)

## Non-goals

- Precise tab/pane jump for Warp / Kitty / Alacritty — they do not use
  standard `NSWindow` tab groups as commonly; keep their behavior
  unchanged. Can revisit after Ghostty works.
- Setting `CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1` for MVP. Vibe Island
  does this; we accept occasional title churn for now.
- Long-lived `AXObserver` to track pane focus changes over time. Vibe
  Island does this; ZackEyes needs only per-click behavior.
- Cache cleanup / GC. `~/.zackeyes/osc2-titles/` can accumulate stale
  files; handle in a later pass.
- Any change to how sessions are rendered in the notch popup. The click
  handler (`NotchViewModel.activateTerminal(for:)`) already exists and
  is already wired from both `NotchExpandedView` and the simulated
  notch.

## Mechanism inspired by Vibe Island (what we learned)

Observed from the installed Vibe Island app:

- Its Bridge writes an **OSC 2** escape to the session's tty on every
  hook event, setting the tab title to
  `{basename} · {prompt[:30]} · {sid[:16]}`.
- It caches the first user prompt at
  `~/.vibe-island/cache/osc2-titles/{sid[:16]}` so the title stays
  stable within a session lifetime.
- It persists a `sessionId → (tty, cwd, termProgram)` map in
  `~/Library/Application Support/vibe-island/session-terminals.json`.
- Its jump log shows parameters `bid=com.mitchellh.ghostty
  tty=/dev/ttys000 pid=38343`, completes in ~120ms, and references
  `AXObserver`, `AXUIElement`, `tabIndex`, `ghosttyPid` in binary
  strings — i.e., the jump goes through the Accessibility API, not
  AppleScript or `CGEventPost`.
- It sets `CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1` to prevent Claude Code
  from overwriting its titles.

ZackEyes must replicate the **title injection** half independently, and
can take a simpler approach for the jump half (no long-lived observers).

## Architecture

Two new pieces. Both fit inside the existing five-target SPM layout.

### Piece 1 — OSC 2 title injection (Bridge side)

Written in the Bridge CLI so that:

- it runs on every hook event (already), refreshing the tab title at
  the natural hook cadence
- it already has `bridgePpid` (= claude PID) as the PPID of its own
  process, so it can derive tty without extra PID discovery
- it is the component already closest to the terminal (direct stdin
  from Claude Code, direct access to /dev/ttyXXX)

New files:

- `Sources/Shared/TTYUtil.swift` — `ttyPath(pid: Int32) -> String?`
  (re-homes the existing `TerminalLocator.ttyPath` so both Bridge and
  App can call it without duplication)
- `Sources/BridgeLib/TerminalTitleWriter.swift` — title formatting,
  OSC 2 byte construction, tty write, prompt cache read/write

Modified files:

- `Sources/Bridge/main.swift` — after the socket send step, call
  `TerminalTitleWriter.writeIfPossible(...)` fire-and-forget

### Piece 2 — Ghostty-specific jump (App side)

Modified files:

- `Sources/AppLib/Terminal/TerminalLocator.swift` — new private
  function `focusGhosttySession(app:session:)`, called from the
  Ghostty case in `activateTerminal(containingPid:cwd:)`
- `Sources/AppLib/Notch/NotchViewModel.swift` — `activateTerminal(for:)`
  must pass the full `SessionInfo` through to `TerminalLocator`. A new
  overload `activateTerminal(containingPid:cwd:session:)` is added; the
  existing `activateTerminal(containingPid:cwd:)` stays in place so
  other callers (e.g. notification tap in `AppDelegate`) don't
  regress. The notch click path moves to the new overload.

No changes to `SessionStore`, `SocketServer`, `HookInstaller`,
`NotchPanel`, or any UI view.

## Data flow

### Title injection

```
Claude Code triggers hook
  ↓
Bridge launches (child of claude)
  ↓
Bridge reads stdin JSON → { session_id, cwd, hook_event_name, user_prompt?, ... }
  ↓
Bridge computes bridgePpid = getppid()   // = claude PID
  ↓
Bridge sends event to /tmp/zackeyes.sock (existing path)
  ↓
Bridge calls TerminalTitleWriter.writeIfPossible(sid, cwd, userPrompt, bridgePpid):
  ├ tty = TTYUtil.ttyPath(pid: bridgePpid)               // e.g. /dev/ttys004
  │  → nil? silently skip
  ├ if userPrompt and no cache file exists:
  │   write truncated prompt to ~/.zackeyes/osc2-titles/{sid[:16]}
  ├ cachedPrompt = read ~/.zackeyes/osc2-titles/{sid[:16]}
  ├ title = formatTitle(cwd, sid, cachedPrompt)
  ├ osc  = "\u{001B}]2;\(title)\u{0007}"
  └ FileHandle(forWritingAtPath: tty)?.write(osc.utf8)   // fire-and-forget
  ↓
Bridge exits (0 or 1, never 2)
```

### Click → jump

```
User clicks session card in notch popup
  ↓
NotchExpandedView.sessionCard Button action:
  viewModel.activateTerminal(for: session)               // existing
  ↓
NotchViewModel.activateTerminal(for:) (Task.detached):
  pid = session.claudePid ?? findClaudePid(...)          // existing
  TerminalLocator.activateTerminal(containingPid: pid, cwd: cwd, session: session)
                                                         // new overload; old one still exists
  ↓
TerminalLocator.activateTerminal:
  app = findTerminalApp(pid)
  app.activate()
  switch bundleId:
    iTerm2:       focusITerm2(tty)               ← unchanged
    AppleTerminal: focusAppleTerminal(tty)       ← unchanged
    ghostty:      if focusGhosttySession(app, session) { return true }   ← new
                   if focusByAccessibility(app, cwd) { return true }      ← existing fallback
                   return false                                            ← at minimum, app activated
    warp/kitty/alacritty:
                   focusByAccessibility(app, cwd)        ← unchanged
  ↓
focusGhosttySession(app, session):
  guard AXIsProcessTrusted()
  marker = String(session.id.prefix(8))                  // raw 8 hex chars of UUID
  appRef = AXUIElementCreateApplication(app.pid)

  // Layer A — AXTabButton title match (fast path)
  if focusGhosttyTabByMarker(appRef, marker: marker):
    return true

  // Layer A' — brute-force tab + pane cycling (bounded)
  if focusGhosttyByCycling(appRef, marker: marker):
    return true

  return false
```

## Title format

`{basename(cwd)} · {prompt[:30]} · ze:{sid[:8]}`

When no cached prompt exists yet:

`{basename(cwd)} · ze:{sid[:8]}`

Examples (real sessions from the screenshot that prompted this work):

- `ccisland · 弹出层中的 session，点击后应该要能跳转到 ghost · ze:3e0a4419`
- `nova · finops 区域，还可以增加哪些重要特性么 · ze:98d67023`
- `website · 鉴于 token 当前的热度（自己搜索去调研 2026 年以 · ze:c51cc718`

**Truncation rules**:

- `prompt` — 30 **characters** (UTF-8 counted), not 30 bytes; any
  embedded `\n`, `\r`, `\t` replaced with space; any ESC / BEL / other
  C0 control chars stripped (defensive — prevent escape injection if
  prompt contains control sequences)
- `sid[:8]` — first 8 ASCII characters of the session UUID
- no truncation on `basename` (typically ≤ 40 chars)

## Cache layout

- **Directory**: `~/.zackeyes/osc2-titles/`
- **File name**: `{sid[:16]}` (first 16 ASCII chars of UUID, matches the
  convention we observed in Vibe Island; 16 chars is enough to avoid
  collisions between session UUIDs)
- **Content**: UTF-8 plain text, the truncated first user prompt
- **Write triggers**: `UserPromptSubmit` hook, only if the file does
  not yet exist (first prompt wins; session title stays stable)
- **Read triggers**: every hook event, to compose the title
- **Permissions**: default (600 / user-only); Bridge writes under the
  user's own permissions

## Verified Ghostty AX structure (2026-04-09)

Dump of a 3-tab Ghostty instance with one tab containing a horizontal
split (`Sources/AppLib/Diagnostics/GhosttyAXDumper.swift` temporary
tool, now removed):

```
Ghostty has 1 top-level AX windows
=== window 0 ===
[AXWindow/AXStandardWindow] title="<focused pane's title>" children=8
  [AXGroup/AXHostingView] children=1
    [AXGroup] desc="Horizontal split view" children=3
      [AXGroup] desc="Left pane" children=1
        [AXScrollArea] children=2
          [AXTextArea] title="" children=0         ← no title
          [AXScrollBar] children=5
      [AXGroup] desc="Right pane" children=1
        [AXScrollArea] children=2
          [AXTextArea] title="" children=0         ← no title
          [AXScrollBar] children=5
      [AXButton] desc="Horizontal split divider"
  [AXTabGroup] desc="Tab bar, 3 tabs." children=4
    [AXRadioButton/AXTabButton] title="<tab 1 focused pane title>" children=3
    [AXRadioButton/AXTabButton] title="<tab 2 focused pane title>" children=3
    [AXRadioButton/AXTabButton] title="<tab 3 focused pane title>" children=3
    [AXButton] title="" desc="new tab" children=0
  ...
```

**Key findings**:

1. Ghostty has exactly **one** top-level `AXWindow` regardless of tab
   count. Its `kAXTitleAttribute` reflects the currently focused
   pane's title (the one visible in the window title bar).
2. The window contains an `AXTabGroup` child whose children are one
   `AXTabButton` per tab (plus one trailing `AXButton` for "new tab").
3. **Each `AXTabButton` has its own `kAXTitleAttribute`**, and that
   title reflects **the focused pane of that specific tab** (not of
   the whole app). So three tabs → three independent titles, one per
   tab's focused surface.
4. Panes within a tab appear as `AXGroup > AXScrollArea > AXTextArea`
   but none of these elements expose a `kAXTitleAttribute`. There is
   **no way to identify a non-focused pane's session via AX** — the
   pane's title (set by OSC 2) lives only in the terminal emulator's
   internal state, not in the AX tree.

## Layer A — AXTabButton title match (primary, fast path)

Enumerate each top-level AX window, find its `AXTabGroup` child, scan
each `AXTabButton` for a title containing the sid marker, and
`AXPress` the match.

```swift
/// Primary Ghostty fast path. Returns true on success.
static func focusGhosttyTabByMarker(
    appRef: AXUIElement,
    marker: String
) -> Bool {
    var windowsRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
        appRef, kAXWindowsAttribute as CFString, &windowsRef
    ) == .success,
          let windows = windowsRef as? [AXUIElement] else { return false }

    for window in windows {
        guard let tabGroup = firstChild(of: window, whereRole: "AXTabGroup") else {
            continue
        }
        guard let buttons = children(of: tabGroup) else { continue }

        for button in buttons {
            guard let subrole = stringAttr(button, kAXSubroleAttribute as String),
                  subrole == "AXTabButton",
                  let title = stringAttr(button, kAXTitleAttribute as String),
                  title.contains(marker) else { continue }

            if AXUIElementPerformAction(button, kAXPressAction as CFString) == .success {
                return true
            }
        }
    }
    return false
}
```

Helpers `firstChild(of:whereRole:)`, `children(of:)`, `stringAttr(_:_:)`
are thin wrappers around `AXUIElementCopyAttributeValue`.

**Covers**: any tab whose focused pane's title contains the sid marker.
This includes non-split tabs (trivially) and split tabs where the
claude pane happens to be focused.

**Does not cover**: split tabs where the claude pane is **not**
currently focused. In that case the AXTabButton title reflects the
other pane (e.g. a plain shell) and the marker is nowhere to be found
at the AX layer. Handled by Layer A'.

## Layer A' — Brute-force tab + pane cycling (split-pane fallback)

Only invoked when Layer A misses. Iterates over each AXTabButton,
pressing each in turn to make that tab active; after each press, cycles
through the tab's panes via synthetic `Cmd+Option+Right` keystrokes
(Ghostty's default `goto_split:next` keybinding) until the window
title contains the marker or the budget is exhausted.

```swift
/// Slow-path fallback. Bounded: at most N_tabs × N_panes iterations.
static func focusGhosttyByCycling(
    appRef: AXUIElement,
    marker: String,
    maxPanesPerTab: Int = 4
) -> Bool {
    var windowsRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
        appRef, kAXWindowsAttribute as CFString, &windowsRef
    ) == .success,
          let windows = windowsRef as? [AXUIElement],
          let window = windows.first else { return false }

    guard let tabGroup = firstChild(of: window, whereRole: "AXTabGroup"),
          let buttons = children(of: tabGroup) else { return false }

    let tabButtons = buttons.filter { el in
        stringAttr(el, kAXSubroleAttribute as String) == "AXTabButton"
    }

    let deadline = Date().addingTimeInterval(0.6)  // 600 ms hard budget

    for button in tabButtons {
        if Date() >= deadline { return false }
        _ = AXUIElementPerformAction(button, kAXPressAction as CFString)
        Thread.sleep(forTimeInterval: 0.02)  // let Ghostty repaint

        // Check the title after tab switch
        if let title = stringAttr(window, kAXTitleAttribute as String),
           title.contains(marker) {
            return true
        }

        // Cycle panes within this tab
        for _ in 0..<maxPanesPerTab {
            if Date() >= deadline { return false }
            postCmdOptionRight()
            Thread.sleep(forTimeInterval: 0.02)

            if let title = stringAttr(window, kAXTitleAttribute as String),
               title.contains(marker) {
                return true
            }
        }
    }
    return false
}

/// Post a Cmd+Option+Right key sequence via CGEvent.
/// Ghostty default keybinding for `goto_split:next`.
private static func postCmdOptionRight() {
    let src = CGEventSource(stateID: .hidSystemState)
    let flags: CGEventFlags = [.maskCommand, .maskAlternate]
    if let down = CGEvent(
        keyboardEventSource: src, virtualKey: 0x7C /* rightArrow */, keyDown: true
    ) {
        down.flags = flags
        down.post(tap: .cghidEventTap)
    }
    if let up = CGEvent(
        keyboardEventSource: src, virtualKey: 0x7C, keyDown: false
    ) {
        up.flags = flags
        up.post(tap: .cghidEventTap)
    }
}
```

**Performance model**:

| Scenario | Iterations | Worst-case time |
|---|---|---|
| Layer A hits | 1 AXPress | < 20 ms |
| Layer A' hits in current tab's other pane | 1 AXPress (redundant) + 1-2 key posts | < 100 ms |
| Layer A' finds after switching to other tab | 1-2 AXPress + 1-2 key posts | < 150 ms |
| Layer A' exhausts all tabs + panes | 3 × (1 AXPress + 4 key posts) = 15 steps | < 600 ms |

**Budget**: 600 ms hard deadline in Layer A'. Exceeds → return false →
fall through to Layer C. The user sees visible tab/pane transitions
during the fallback path; acceptable for a <5% code path.

**User-controlled caveat**: Layer A' depends on Ghostty's default
`goto_split:next = cmd+alt+right` keybinding. Users who've remapped
this will get a silent no-op fallback. Documented in Risks.

## Invariants

Enforced by code review and spec:

1. **iTerm2 / Apple Terminal paths are untouched.** All existing
   AppleScript code in `TerminalLocator` stays byte-identical.
2. **Bridge never blocks Claude Code.** New code paths in Bridge exit
   `0` or `1`, never `2`. OSC 2 write failure is silent and does not
   affect socket event forwarding.
3. **Cache writes are idempotent and concurrent-safe.** `{sid[:16]}`
   filenames are per-session; two Bridges for the same session writing
   the same cache file are safe because both write the same content
   (the first user prompt, read from the event).
4. **AX permission check is silent.** `AXIsProcessTrusted()` is
   checked, `AXIsProcessTrustedWithOptions()` (the prompting variant)
   is only called from `promptAccessibilityIfNeeded()` at app startup.
   Click-time code never re-prompts.
5. **AX enumeration and cycling are bounded.** Layer A is a single
   pass over AXTabButton children (O(tab count)). Layer A' is bounded
   by tab count × `maxPanesPerTab` (default 4) and a 600ms wall-clock
   deadline. All loops honor the deadline check.
6. **No long-lived `AXObserver`.** We only call AX APIs synchronously
   inside the click handler (wrapped in `Task.detached`). No observer
   registration, no retained AX callbacks.
7. **OSC 2 content is sanitized.** Any ESC / BEL / other C0 control
   characters in the cached prompt are stripped before composing the
   title, to prevent embedded escape sequences from being re-interpreted
   by the terminal.

## Resource limits

| Resource | Limit | Reason |
|---|---|---|
| Cached prompt | 30 UTF-8 characters | Keep titles short, prevent filesystem abuse |
| Cache file write | per session, single write | Avoid write storms |
| Layer A AXTabButton enumeration | up to ~8 buttons | Trivial, O(tab count) |
| Layer A' tab cycles | max 3 (observed Ghostty tab count ceiling) | bounded explicit |
| Layer A' pane cycles per tab | max 4 | covers typical 2x2 split layouts |
| Layer A' wall-clock budget | 600 ms | hard deadline; exceeds → fall through |
| Bridge OSC2 write | < 10ms | Matches existing Bridge single-call budget |

## Testing

### Unit tests — BridgeLibTests

- `TerminalTitleWriter.formatTitle(cwd:sid:prompt:)` —
  - with prompt: full format
  - without prompt: short format
  - prompt with `\n` → replaced by space
  - prompt with ESC, BEL → stripped
  - prompt longer than 30 chars → truncated to 30 chars (by character,
    not byte — test with mixed CJK + ASCII)
- `TerminalTitleWriter.oscEscape(title:)` — byte-exact
  `ESC ] 2 ; {title} BEL`
- `TitleCache.read/write` — round-trip in a tmp directory
- `TitleCache.writeIfMissing` — second write is a no-op

### Unit tests — AppLibTests

No new unit tests for Layer A / A'. Both are thin glue over real AX
APIs and `CGEvent`, which do not mock meaningfully. Existing
`TerminalLocator` tests continue to pass (regression coverage for the
parts untouched by this work). Correctness of the new paths is
validated by the manual integration tests below.

### Manual integration tests (checked during implementation)

1. **Multi-tab baseline**: open 3 Ghostty tabs in 3 different projects,
   start claude in each; click each session card in the notch popup;
   verify precise tab switch.
2. **Split-pane case** (the case that motivated this spec): tab 1 has
   a split — pane A is a plain shell, pane B has claude; **focus the
   shell pane first** (so the marker is hidden from the tab button
   title, forcing Layer A miss → Layer A' invocation); click pane B's
   session card; verify that tab 1 becomes active, Layer A' cycles
   panes, and pane B ends up focused. Elapsed time should be well
   under 300 ms; a visible pane transition is expected.
3. **Cold start**: quit ZackEyes mid-session, restart; click a session
   card; after the first hook fires (which rewrites the title) the
   click should precisely jump.
4. **iTerm2 regression**: open an iTerm2 tab with claude; click its
   session card; verify existing AppleScript path still works.
5. **No-cwd edge case**: a session whose `cwd` is `nil` (unusual but
   possible); click; verify we don't crash, falls through to
   `app.activate()`.

### Observability (NSLog)

New log lines, to be grep-able. All format strings use `%{public}@`
so they are not redacted in unified logging.

- `ZackEyes: TitleWriter tty=%{public}@ sid=%{public}@ bytes=%d ok=%d`
- `ZackEyes: TitleCache op=%{public}@ sid=%{public}@ path=%{public}@ ok=%d`
- `ZackEyes: focusGhostty layer=A sid=%{public}@ hit=%d elapsed=%dms`
- `ZackEyes: focusGhostty layerA-cycling sid=%{public}@ hit=%d steps=%d elapsed=%dms`
- `ZackEyes: focusGhostty final=%{public}@` (one of `A`, `A-cycling`, `legacy`, `activate-only`)

## Risks

1. **Ghostty does not expose panes as AX children with distinct
   titles** — **confirmed** by the AX dump on 2026-04-09. Layer A
   covers only tabs whose focused pane already shows the marker.
   Split tabs with claude in a non-focused pane are handled by
   Layer A' (brute-force cycling). *Status*: addressed by design v2.
1a. **Layer A' depends on user keeping Ghostty's default
   `goto_split:next = cmd+alt+right` keybinding.** Users who remapped
   it will see Layer A' fail silently for the split-unfocused case
   (no harm, just fallback behavior). *Mitigation*: document in the
   feature's user-facing notes; could be made configurable in a later
   pass.
2. **Title write-to-click race.** If the user clicks before the first
   hook fires (SessionStart), no marker exists in the tab title yet,
   matching fails. *Mitigation*: SessionStart is the very first hook
   after Claude Code starts, fires before any user interaction in most
   cases; as a fallback, Layer B's basename match still triggers a
   tab switch (just not guaranteed precise).
3. **VI coexistence.** If Vibe Island is also running, both Bridges
   write OSC 2 to the same tty. Last-write-wins is acceptable because
   our matcher searches for the raw `sid[:8]` substring (8 hex chars
   of the session UUID). This appears in both our title format
   (`... · ze:3e0a4419`) and VI's title format
   (`... · 3e0a4419-cf88-43`), so whichever writer won the race, the
   matcher still finds it.
4. **Prompt injection.** A malicious prompt could contain OSC escapes
   that re-interpret the title. *Mitigation*: strip C0 control chars
   in the formatter (see Invariants 7).
5. **Shell prompt overwrites title.** Some user shell configs set
   window title on every prompt. *Mitigation*: our OSC 2 write runs on
   every hook event (PreToolUse, PostToolUse, Stop, etc.), so the
   title is re-asserted constantly; minor churn is acceptable.
6. **Accessibility permission.** Layer A requires the user to have
   granted Accessibility to ZackEyes. The existing
   `promptAccessibilityIfNeeded()` call at app startup handles the
   first-time prompt; click-time code only reads `AXIsProcessTrusted`
   and silently falls back.

## Open questions (resolved during implementation)

1. Does Ghostty expose per-pane `AXUIElement` with own `kAXTitleAttribute`?
   → answered by the AX dump verification step
2. Does `AXUIElementSetAttributeValue(element, kAXFocusedAttribute)` on
   a pane element actually move user-visible focus in Ghostty, or does
   it only update logical AX state? → tested in implementation
3. Measured latency of Layer A on a realistic Ghostty tree → measured
   during manual tests

## Implementation plan prelude — resolved

**Status (2026-04-09)**: verification complete. A temporary
`Sources/AppLib/Diagnostics/GhosttyAXDumper.swift` was added and called
from `AppDelegate.applicationDidFinishLaunching` to dump Ghostty's AX
tree to `/tmp/ghostty-ax-dump.txt` using ZackEyes's existing AX grant
(the `Tools/verify-ghostty-ax.swift` standalone approach failed due to
AX grant friction — standalone binaries and `swift` script interpreters
can't reliably inherit accessibility permissions).

The dump confirmed:
- Ghostty uses a single top-level `AXWindow`
- Tabs are exposed as `AXTabButton` children of an `AXTabGroup`, each
  with its own `kAXTitleAttribute`
- Panes exist structurally but **have no titles** — `AXGroup > AXScrollArea > AXTextArea`

The dumper code was reverted before production implementation; the
dump file is preserved at `/tmp/ghostty-ax-dump.txt` for reference if
needed. The committed `Tools/verify-ghostty-ax.swift` script remains
in the repo as a future diagnostic (useful if a user ever figures out
the AX grant for standalone swift binaries).

Proceed directly with production implementation using Layer A
(AXTabButton match) + Layer A' (brute-force cycling) as specified.

## File map (change summary)

| File | Change |
|---|---|
| `Sources/Shared/TTYUtil.swift` | **New** — `ttyPath(pid:)` + pure `parseTTYOutput` |
| `Sources/BridgeLib/TerminalTitleWriter.swift` | **New** — `formatTitle`, `oscEscape`, `writeIfPossible`, `TitleCache` |
| `Sources/Bridge/main.swift` | **Modified** — call `TerminalTitleWriter.writeIfPossible(...)` after socket send |
| `Sources/AppLib/Terminal/TerminalLocator.swift` | **Modified** — new `focusGhosttySession`, `focusGhosttyTabByMarker` (Layer A), `focusGhosttyByCycling` (Layer A'), small AX helpers; `ttyPath` inline code removed in favor of `TTYUtil` |
| `Sources/AppLib/Notch/NotchViewModel.swift` | **Modified** — `activateTerminal(for:)` passes the session id through to a new `TerminalLocator.activateTerminal(containingPid:cwd:sessionId:)` overload |
| `Tests/SharedTests/TTYUtilTests.swift` | **New** — pure parser tests |
| `Tests/BridgeLibTests/TerminalTitleWriterTests.swift` | **New** — format + OSC + cache unit tests |
| `Tools/verify-ghostty-ax.swift` | **Already committed** (chore/da72825) — standalone diagnostic; not used for Task 0 due to AX grant friction |

No `AppLib` unit tests for Layer A / A': the logic is thin glue over
real AX APIs and CGEvent, which are not meaningfully mockable. Layer
correctness is validated via manual integration tests (see Testing).

## Performance targets

| Metric | Target |
|---|---|
| Bridge OSC 2 write total time | < 10ms |
| App click → Ghostty frontmost | < 50ms (just `NSRunningApplication.activate()`) |
| Layer A full tree walk + focus | < 50ms |
| End-to-end click → visible tab switch | < 200ms (comparable to Vibe Island's 116-172ms) |

## Success criteria

- Clicking any session card in the notch popup reliably lands the user
  in the correct Ghostty tab **and** pane, including the split-pane
  case (tab 1 has pane A + pane B; click B's card; pane B becomes
  focused regardless of which pane was focused before)
- Existing iTerm2 / Apple Terminal precise-jump behavior is unchanged
- `swift test` passes; `swift build` clean; `make app` builds
- Bridge has no `exit(2)` paths introduced anywhere in the new code
- Accessibility Inspector (or our own dump tool) confirms Ghostty AX
  structure matches the assumption before production code lands
