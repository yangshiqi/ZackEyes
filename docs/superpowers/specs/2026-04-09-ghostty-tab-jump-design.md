# Ghostty Tab & Split-Pane Click-to-Jump — Design

**Date**: 2026-04-09
**Status**: Draft — awaiting implementation plan
**Scope**: Bridge OSC2 title injection + TerminalLocator Ghostty-specific jump path

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

  // Layer A — AX tree walk
  if (window, element) = axFindElementMatching(appRef, marker: marker):
    AXRaise(window)
    if element != window: AXSetFocused(element)
    return true

  // Layer B — Window menu AXPress
  if pressWindowMenuItemMatching(appRef, marker: marker, cwd: session.cwd):
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

## Layer A — AX tree walk (primary jump path)

```swift
private static func axFindElementMatching(
    _ appRef: AXUIElement,
    marker: String
) -> (window: AXUIElement, element: AXUIElement)? {
    var windowsRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
        appRef, kAXWindowsAttribute as CFString, &windowsRef
    ) == .success,
          let windows = windowsRef as? [AXUIElement] else { return nil }

    let deadline = Date().addingTimeInterval(0.05)  // 50ms budget
    var visited = 0

    for window in windows {
        if let match = walk(
            element: window, marker: marker,
            depth: 0, maxDepth: 6,
            visited: &visited, maxVisited: 1000,
            deadline: deadline
        ) {
            return (window, match)
        }
        if Date() >= deadline || visited >= 1000 { break }
    }
    return nil
}

private static func walk(
    element: AXUIElement, marker: String,
    depth: Int, maxDepth: Int,
    visited: inout Int, maxVisited: Int,
    deadline: Date
) -> AXUIElement? {
    if depth > maxDepth || visited >= maxVisited || Date() >= deadline {
        return nil
    }
    visited += 1

    var titleRef: CFTypeRef?
    if AXUIElementCopyAttributeValue(
        element, kAXTitleAttribute as CFString, &titleRef
    ) == .success,
       let title = titleRef as? String,
       title.contains(marker) {
        return element
    }

    var childrenRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
        element, kAXChildrenAttribute as CFString, &childrenRef
    ) == .success,
          let children = childrenRef as? [AXUIElement] else {
        return nil
    }
    for child in children {
        if let m = walk(
            element: child, marker: marker,
            depth: depth + 1, maxDepth: maxDepth,
            visited: &visited, maxVisited: maxVisited,
            deadline: deadline
        ) {
            return m
        }
    }
    return nil
}
```

**Precondition assumption** (to be verified): Ghostty exposes each pane
(surface) as a child `AXUIElement` of its `AXWindow`, and each pane has
its own `kAXTitleAttribute` reflecting whatever OSC 2 wrote to that
pane's tty. This assumption is verified by the AX dump tool before
production implementation (see Implementation Plan Prelude below).

**If the assumption holds** — Layer A succeeds in the common split-pane
case; Layer A' (pane cycling) is not needed.

**If the assumption does not hold** — Layer A degrades to "find the
matching tab window", which still succeeds when the claude pane is the
focused pane of its tab; split-pane case requires Layer A' (pane
cycling) as an additional layer.

## Layer B — Window menu AXPress (secondary)

```swift
private static func pressWindowMenuItemMatching(
    _ appRef: AXUIElement,
    marker: String,
    cwd: String?
) -> Bool {
    var barRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
        appRef, kAXMenuBarAttribute as CFString, &barRef
    ) == .success,
          let menuBar = barRef, CFGetTypeID(menuBar) == AXUIElementGetTypeID()
    else { return false }
    let menuBarEl = menuBar as! AXUIElement

    // Find the "Window" top-level menu (localized: English "Window", Chinese "窗口")
    var topItemsRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
        menuBarEl, kAXChildrenAttribute as CFString, &topItemsRef
    ) == .success,
          let topItems = topItemsRef as? [AXUIElement] else { return false }

    let windowMenuTitles: Set<String> = ["Window", "窗口", "ウインドウ", "창"]
    var windowBarItem: AXUIElement?
    for item in topItems {
        var t: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            item, kAXTitleAttribute as CFString, &t
        ) == .success,
           let title = t as? String, windowMenuTitles.contains(title) {
            windowBarItem = item
            break
        }
    }
    guard let barItem = windowBarItem else { return false }

    // Descend into the actual menu
    var menuRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
        barItem, kAXChildrenAttribute as CFString, &menuRef
    ) == .success,
          let menuArr = menuRef as? [AXUIElement],
          let menu = menuArr.first else { return false }

    var itemsRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
        menu, kAXChildrenAttribute as CFString, &itemsRef
    ) == .success,
          let items = itemsRef as? [AXUIElement] else { return false }

    // Known fixed items to skip (English only for MVP; extend if needed)
    let skipTitles: Set<String> = [
        "Minimize", "Zoom", "Move Tab to New Window",
        "Merge All Windows", "Show Previous Tab", "Show Next Tab",
        "Move Tab Left", "Move Tab Right", "Bring All to Front",
        "Close Tab", "Close Window",
    ]

    // Pick the best match; prefer marker over basename
    let basename = (cwd as NSString?)?.lastPathComponent ?? ""
    var best: (el: AXUIElement, score: Int)?
    for item in items {
        var t: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            item, kAXTitleAttribute as CFString, &t
        ) == .success,
              let title = t as? String, !title.isEmpty,
              !skipTitles.contains(title) else { continue }

        var score = 0
        if title.contains(marker) { score = 5 }
        else if !basename.isEmpty, title.contains(basename) { score = 2 }
        else { continue }

        if score > (best?.score ?? 0) {
            best = (item, score)
        }
    }

    guard let target = best?.el, (best?.score ?? 0) >= 3 else { return false }
    return AXUIElementPerformAction(target, kAXPressAction as CFString) == .success
}
```

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
5. **AX tree walk is bounded.** Depth ≤ 6, nodes ≤ 1000, wall clock
   ≤ 50ms. Deadline enforced in the recursion.
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
| AX tree walk depth | 6 | Defensive ceiling; real Ghostty subtree depth to be measured by the verification tool |
| AX tree walk nodes | 1000 | Defensive ceiling against pathological trees |
| AX tree walk wall time | 50ms | VI completes full jump in 116-172ms; 50ms for walk is generous |
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

- `TerminalLocator.walk` — can be tested with a pure-Swift fake AX tree
  (parametric over "get attribute" closure), validating: depth limit,
  visit count limit, deadline honored, match found, match not found.
  No real AX calls.

### Manual integration tests (checked during implementation)

1. **Multi-tab baseline**: open 3 Ghostty tabs in 3 different projects,
   start claude in each; click each session card in the notch popup;
   verify precise tab switch.
2. **Split-pane case** (the case that motivated this spec): tab 1 has
   a split — pane A is a plain shell, pane B has claude; click pane
   B's session card; verify that tab 1 becomes active **and** pane B
   receives focus.
3. **Cold start**: quit ZackEyes mid-session, restart; click a session
   card; after the first hook fires (which rewrites the title) the
   click should precisely jump.
4. **iTerm2 regression**: open an iTerm2 tab with claude; click its
   session card; verify existing AppleScript path still works.
5. **No-cwd edge case**: a session whose `cwd` is `nil` (unusual but
   possible); click; verify we don't crash, falls through to
   `app.activate()`.

### Observability (NSLog)

New log lines, to be grep-able:

- `ZackEyes: TitleWriter tty=%@ sid=%@ bytes=%d ok=%d`
- `ZackEyes: TitleCache op=%@ sid=%@ path=%@ ok=%d`
- `ZackEyes: focusGhostty layer=A sid=%@ hit=%d elapsed=%dms`
- `ZackEyes: focusGhostty layer=B sid=%@ hit=%d`
- `ZackEyes: focusGhostty final=%@` (one of `A`, `B`, `legacy`, `activate-only`)

## Risks

1. **Ghostty may not expose panes as AX children with distinct titles.**
   Layer A then degrades to tab-level matching; split panes with
   non-focused claude become unreachable without Layer A' (pane
   cycling). *Mitigation*: AX dump verification before implementation;
   add Layer A' if needed.
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

## Implementation plan prelude

Before any production code is written, run this verification:

1. Write `Tools/verify-ghostty-ax.swift` — a single-file Swift script
   (not in `Package.swift`), invoked as `swift Tools/verify-ghostty-ax.swift`
2. The script:
   - Waits 3 seconds (giving the user time to raise Ghostty with a tab
     containing a split)
   - Looks up the Ghostty PID via `NSRunningApplication`
   - Creates an `AXUIElementCreateApplication` reference
   - Recursively walks `kAXWindowsAttribute` → each window's subtree,
     printing `[role] [subrole] title="..." ident="..." childCount=N`
   - Writes the full dump to `/tmp/ghostty-ax-dump.txt`
3. Examine the dump:
   - If each pane appears as a distinct child element with its own
     non-empty title → Layer A is viable as specified
   - Otherwise → add Layer A' (pane cycling via
     `next_split` keyboard shortcut, bounded loop, read current focused
     title each iteration)
4. Proceed with production code based on the finding

The production `focusGhosttySession` should not ship until the AX tree
assumption is confirmed one way or the other.

## File map (change summary)

| File | Change |
|---|---|
| `Sources/Shared/TTYUtil.swift` | **New** — `ttyPath(pid:)` |
| `Sources/BridgeLib/TerminalTitleWriter.swift` | **New** — `formatTitle`, `oscEscape`, `writeIfPossible`, `TitleCache` |
| `Sources/Bridge/main.swift` | **Modified** — call `TerminalTitleWriter.writeIfPossible(...)` after socket send |
| `Sources/AppLib/Terminal/TerminalLocator.swift` | **Modified** — new `focusGhosttySession`, new `axFindElementMatching`, new `pressWindowMenuItemMatching`, `ttyPath` inline call removed in favor of `TTYUtil` |
| `Sources/AppLib/Notch/NotchViewModel.swift` | **Modified** — `activateTerminal(for:)` passes `SessionInfo` through to a new `TerminalLocator.activateTerminal(containingPid:cwd:session:)` overload |
| `Tests/BridgeLibTests/TerminalTitleWriterTests.swift` | **New** — format + OSC + cache unit tests |
| `Tests/AppLibTests/TerminalLocatorTests.swift` | **Modified or new** — `walk` tree-traversal unit tests |
| `Tools/verify-ghostty-ax.swift` | **New** (not in `Package.swift`) — verification tool |

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
