# Ghostty Tab & Split-Pane Click-to-Jump Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Clicking a Ghostty session in the ZackEyes notch popup lands the user in the exact Ghostty tab **and** pane where that claude session is running, including the split-pane case.

**Architecture:** Bridge writes an OSC 2 escape to the session's tty on every hook event, embedding the session id in the tab title. The App-side click handler bounded-walks Ghostty's AX tree for an element whose title contains that id, then raises the ancestor window and sets focus on the specific pane. Layered fallbacks (Window menu AXPress, existing AX raise, plain activate) handle degraded cases.

**Tech Stack:** Swift 6, SPM (5 existing targets), Foundation, AppKit, ApplicationServices (AX API), XCTest.

**Spec:** `docs/superpowers/specs/2026-04-09-ghostty-tab-jump-design.md`

---

## Architecture constraints (must-hold invariants)

From `CLAUDE.md` and the spec:

1. Bridge never uses `exit(2)` — only `0` or `1`.
2. Zero new SPM targets, zero new third-party dependencies.
3. iTerm2 / Apple Terminal AppleScript paths are **untouched** (`focusITerm2`, `focusAppleTerminal` stay byte-identical).
4. AX permission is checked via `AXIsProcessTrusted()` only at click time — no re-prompting. `promptAccessibilityIfNeeded()` at app startup handles the one-time prompt.
5. Every new failure path in Bridge is silent + non-blocking.
6. Hook config / settings.json is not touched by this feature.

Before each commit, run:

```bash
swift build 2>&1 | tail -5
```

Build must succeed. Do not commit broken code.

---

## File structure (lock in the decomposition)

| File | Role | Status |
|---|---|---|
| `Tools/verify-ghostty-ax.swift` | One-off AX dump script; not in `Package.swift` | **New** (Task 0, optionally removed or kept as a dev tool) |
| `Sources/Shared/TTYUtil.swift` | Pure + IO helper: PID → `/dev/ttys…` | **New** (Task 1) |
| `Sources/BridgeLib/TerminalTitleWriter.swift` | Title formatter, OSC 2 escape, prompt cache, tty writer | **New** (Tasks 2–4) |
| `Sources/Bridge/main.swift` | Call `TerminalTitleWriter.writeIfPossible(...)` after the socket send | **Modify** (Task 4) |
| `Sources/AppLib/Terminal/TerminalLocator.swift` | New private `focusGhosttySession` + `axTreeFindElement` + `walk` + `pressWindowMenuItemMatching`; new `activateTerminal(containingPid:cwd:session:)` overload; delete inline `ttyPath` (use `TTYUtil`) | **Modify** (Tasks 5–8) |
| `Sources/AppLib/Notch/NotchViewModel.swift` | `activateTerminal(for:)` calls the new overload | **Modify** (Task 8) |
| `Tests/SharedTests/TTYUtilTests.swift` | Pure parser tests for TTY output parsing | **New** (Task 1) |
| `Tests/BridgeLibTests/TerminalTitleWriterTests.swift` | sanitize / truncate / format / osc-escape / cache tests | **New** (Tasks 2–3) |
| `Tests/AppLibTests/TerminalLocatorWalkTests.swift` | Pure-Swift fake-tree tests for the `walk` function | **New** (Task 5) |

No other files are touched.

---

## Task 0: Verify Ghostty AX tree assumption — **DONE (2026-04-09)**

**Status**: completed before production implementation. This task
section is preserved for historical context.

**Result**: Ghostty uses a **single top-level `AXWindow`** per
Ghostty app instance (not one per tab). Tabs are exposed as
`AXTabButton` children of an `AXTabGroup`, each with its own
`kAXTitleAttribute` reflecting the focused pane of that tab. Panes
exist structurally (`AXGroup > AXScrollArea > AXTextArea`) but have
**no titles** — there is no way to find a non-focused pane via AX.

**Implication for the rest of the plan**: the original bounded AX
tree walker is unnecessary. Tasks 5–7 are rewritten to:
- Task 5: small AX attribute-reading helpers
- Task 6: Layer A — `focusGhosttyTabByMarker` (AXTabButton title
  match → AXPress) + new `activateTerminal` overload wiring
- Task 7: Layer A' — `focusGhosttyByCycling` (brute-force tab and
  pane cycling bounded by a 600 ms wall-clock deadline)

**Dump file** preserved at `/tmp/ghostty-ax-dump.txt` during the
verification; no longer needed. The standalone
`Tools/verify-ghostty-ax.swift` script remains in the repo
(committed as `da72825`) as a future diagnostic, though the actual
Task 0 dump was obtained via a short-lived
`Sources/AppLib/Diagnostics/GhosttyAXDumper.swift` embedded in the
app (reverted after use).

---

### Task 0 historical content (original script-based approach)

**Files:**
- Create: `Tools/verify-ghostty-ax.swift` (not added to `Package.swift`)
- Write-only artifact: `/tmp/ghostty-ax-dump.txt`

- [x] **Step 1: Create the verification script**

Create `Tools/verify-ghostty-ax.swift` with this exact content:

```swift
#!/usr/bin/env swift
// One-off: dump Ghostty's AX tree to /tmp/ghostty-ax-dump.txt.
//
// Usage:
//   1. Open Ghostty with at least 2 tabs, one containing a split pane.
//   2. Make sure every surface has a non-default title (run `printf '\e]2;test\a'` in each pane).
//   3. Run: swift Tools/verify-ghostty-ax.swift
//   4. Inspect: cat /tmp/ghostty-ax-dump.txt

import AppKit
import ApplicationServices
import Foundation

let ghosttyBundleID = "com.mitchellh.ghostty"

print("Waiting 3 seconds — switch to Ghostty now...")
Thread.sleep(forTimeInterval: 3)

guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: ghosttyBundleID).first else {
    print("ERROR: Ghostty not running")
    exit(1)
}
print("Found Ghostty pid=\(app.processIdentifier)")

guard AXIsProcessTrusted() else {
    print("ERROR: Accessibility permission not granted. Grant it to /usr/bin/swift or to Terminal and rerun.")
    exit(1)
}

let appRef = AXUIElementCreateApplication(app.processIdentifier)

func copy(_ el: AXUIElement, _ attr: String) -> CFTypeRef? {
    var out: CFTypeRef?
    _ = AXUIElementCopyAttributeValue(el, attr as CFString, &out)
    return out
}

func dump(_ el: AXUIElement, depth: Int, writer: (String) -> Void) {
    let indent = String(repeating: "  ", count: depth)
    let role = (copy(el, kAXRoleAttribute as String) as? String) ?? "?"
    let subrole = (copy(el, kAXSubroleAttribute as String) as? String) ?? ""
    let title = (copy(el, kAXTitleAttribute as String) as? String) ?? ""
    let desc = (copy(el, kAXDescriptionAttribute as String) as? String) ?? ""
    let ident = (copy(el, kAXIdentifierAttribute as String) as? String) ?? ""
    let children = (copy(el, kAXChildrenAttribute as String) as? [AXUIElement]) ?? []

    writer("\(indent)[\(role)\(subrole.isEmpty ? "" : "/\(subrole)")] "
         + "title=\"\(title)\" desc=\"\(desc.prefix(60))\" ident=\"\(ident)\" children=\(children.count)")

    if depth < 6 {
        for c in children { dump(c, depth: depth + 1, writer: writer) }
    }
}

var lines: [String] = []
let writer: (String) -> Void = { lines.append($0) }

let windows = (copy(appRef, kAXWindowsAttribute as String) as? [AXUIElement]) ?? []
writer("Ghostty has \(windows.count) top-level AX windows")
for (i, w) in windows.enumerated() {
    writer("=== window \(i) ===")
    dump(w, depth: 0, writer: writer)
}

let out = lines.joined(separator: "\n") + "\n"
try? out.write(toFile: "/tmp/ghostty-ax-dump.txt", atomically: true, encoding: .utf8)
print("Done. See /tmp/ghostty-ax-dump.txt (\(lines.count) lines)")
```

- [ ] **Step 2: Prepare Ghostty**

Manually: open Ghostty, create 2+ tabs with distinct projects, and in one tab create a vertical split. In each surface run `printf '\e]2;uniqmark-<num>\a'` to give each a distinct title so the dump is legible.

- [ ] **Step 3: Run the dump tool**

```bash
cd /Users/ysq/Work/lab/ccisland
swift Tools/verify-ghostty-ax.swift
```

Expected: prints `Found Ghostty pid=NNNN`, waits, prints `Done. See /tmp/ghostty-ax-dump.txt (N lines)`.

- [ ] **Step 4: Inspect the dump and decide**

```bash
cat /tmp/ghostty-ax-dump.txt
```

Check:
- **Does each window have child elements with distinct `title="..."`?**
  - **Yes** → Layer A is viable as specified. Proceed with the plan unchanged.
  - **No** → Add a note to the top of this plan: "Layer A' (pane cycling) required; insert before Task 7." Then continue; Layer A' is out of scope of this plan document (raise and stop).

- [ ] **Step 5: Commit the verification script**

```bash
git add Tools/verify-ghostty-ax.swift
git commit -m "chore(tools): add Ghostty AX tree dump script

One-off diagnostic used to confirm that Ghostty exposes per-pane
AXUIElements with distinct titles, which is the precondition for
Layer A of the tab-jump design.
"
```

---

## Task 1: Extract `ttyPath` to Shared.TTYUtil

Move the PID → tty-path helper out of `TerminalLocator` into a new `Shared.TTYUtil` so BridgeLib can call it without dragging AppKit dependencies.

**Files:**
- Create: `Sources/Shared/TTYUtil.swift`
- Create: `Tests/SharedTests/TTYUtilTests.swift`
- Modify: `Sources/AppLib/Terminal/TerminalLocator.swift` (delete inline `ttyPath`, call `TTYUtil.ttyPath` instead)

- [ ] **Step 1: Write the failing tests**

Create `Tests/SharedTests/TTYUtilTests.swift`:

```swift
import XCTest
@testable import Shared

final class TTYUtilTests: XCTestCase {
    func test_parseTTYOutput_plainName_prependsDev() {
        XCTAssertEqual(TTYUtil.parseTTYOutput("ttys003"), "/dev/ttys003")
    }

    func test_parseTTYOutput_withTrailingNewline_isTrimmed() {
        XCTAssertEqual(TTYUtil.parseTTYOutput("ttys003\n"), "/dev/ttys003")
    }

    func test_parseTTYOutput_alreadyAbsolute_isKept() {
        XCTAssertEqual(TTYUtil.parseTTYOutput("/dev/ttys012"), "/dev/ttys012")
    }

    func test_parseTTYOutput_questionMark_returnsNil() {
        XCTAssertNil(TTYUtil.parseTTYOutput("?"))
    }

    func test_parseTTYOutput_empty_returnsNil() {
        XCTAssertNil(TTYUtil.parseTTYOutput(""))
    }

    func test_parseTTYOutput_whitespaceOnly_returnsNil() {
        XCTAssertNil(TTYUtil.parseTTYOutput("   \n  "))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
swift test --filter SharedTests.TTYUtilTests 2>&1 | tail -20
```

Expected: compilation error — `TTYUtil` not defined.

- [ ] **Step 3: Create TTYUtil**

Create `Sources/Shared/TTYUtil.swift`:

```swift
import Foundation

/// Resolve the tty path for a process by shelling out to `ps -p PID -o tty=`.
/// Split into a pure parser (`parseTTYOutput`) and the IO wrapper (`ttyPath`)
/// so the parsing rules can be unit-tested without running a subprocess.
public enum TTYUtil {

    /// Pure: transform the raw `ps -o tty=` output into a `/dev/ttys…` path.
    /// Returns nil for empty, whitespace-only, or `?` (no controlling tty).
    public static func parseTTYOutput(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "?" else { return nil }
        if trimmed.hasPrefix("/dev/") { return trimmed }
        return "/dev/\(trimmed)"
    }

    /// Lookup the controlling tty of `pid` via `/bin/ps`. Returns nil on any error.
    public static func ttyPath(pid: Int32) -> String? {
        let task = Process()
        task.launchPath = "/bin/ps"
        task.arguments = ["-p", "\(pid)", "-o", "tty="]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let raw = String(data: data, encoding: .utf8) else { return nil }
        return parseTTYOutput(raw)
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
swift test --filter SharedTests.TTYUtilTests 2>&1 | tail -20
```

Expected: all 6 tests pass.

- [ ] **Step 5: Remove duplicate `ttyPath` from TerminalLocator and call TTYUtil**

Edit `Sources/AppLib/Terminal/TerminalLocator.swift`:

1. At the top, ensure `import Shared` is present (it probably isn't since AppLib already depends on Shared).
2. Delete the existing `static func ttyPath(of pid: Int32) -> String?` method (lines ~183–204).
3. Replace every call to `ttyPath(of: pid)` with `TTYUtil.ttyPath(pid: pid)`.

After edit, confirm no stale callers:

```bash
grep -n "ttyPath" Sources/AppLib/Terminal/TerminalLocator.swift
```

Expected: only the `TTYUtil.ttyPath(pid:` usages remain.

- [ ] **Step 6: Build and run full test suite**

```bash
swift build 2>&1 | tail -5 && swift test 2>&1 | tail -20
```

Expected: build clean, all existing tests still pass plus the 6 new TTYUtilTests.

- [ ] **Step 7: Commit**

```bash
git add Sources/Shared/TTYUtil.swift Tests/SharedTests/TTYUtilTests.swift Sources/AppLib/Terminal/TerminalLocator.swift
git commit -m "refactor(terminal): move ttyPath to Shared.TTYUtil

Both Bridge and App need PID->tty resolution. Extracting the helper
into Shared (with a pure parser for testability) lets BridgeLib use
it without pulling AppKit.
"
```

---

## Task 2: TerminalTitleWriter — pure helpers (sanitize, truncate, format, oscEscape)

Build the pure functions first so they can be exhaustively unit-tested without touching IO.

**Files:**
- Create: `Sources/BridgeLib/TerminalTitleWriter.swift`
- Create: `Tests/BridgeLibTests/TerminalTitleWriterTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `Tests/BridgeLibTests/TerminalTitleWriterTests.swift`:

```swift
import XCTest
@testable import BridgeLib

final class TerminalTitleWriterTests: XCTestCase {

    // MARK: sanitizePrompt

    func test_sanitizePrompt_stripsControlChars() {
        XCTAssertEqual(
            TerminalTitleWriter.sanitizePrompt("hello\u{001B}]2;evil\u{0007}world"),
            "hello]2;evilworld"
        )
    }

    func test_sanitizePrompt_replacesNewlinesAndTabsWithSpace() {
        XCTAssertEqual(
            TerminalTitleWriter.sanitizePrompt("line1\nline2\tend\rmore"),
            "line1 line2 end more"
        )
    }

    func test_sanitizePrompt_keepsUnicodeText() {
        XCTAssertEqual(
            TerminalTitleWriter.sanitizePrompt("弹出层中的 session，跳转"),
            "弹出层中的 session，跳转"
        )
    }

    // MARK: truncateToChars

    func test_truncateToChars_shortPassesThrough() {
        XCTAssertEqual(TerminalTitleWriter.truncateToChars("abc", max: 30), "abc")
    }

    func test_truncateToChars_truncatesByCharacterCount() {
        // 40 ASCII chars, max 30 → first 30 chars kept
        let input = String(repeating: "x", count: 40)
        XCTAssertEqual(TerminalTitleWriter.truncateToChars(input, max: 30).count, 30)
    }

    func test_truncateToChars_truncatesCJKByCharacter() {
        // 15 CJK chars = 45 UTF-8 bytes. Limit 10 chars → 10 characters (30 bytes)
        let input = "弹出层中的 session 跳转到对应"  // 15 characters-ish
        let result = TerminalTitleWriter.truncateToChars(input, max: 10)
        XCTAssertEqual(result.count, 10)
    }

    // MARK: formatTitle

    func test_formatTitle_withPrompt_producesFullFormat() {
        let title = TerminalTitleWriter.formatTitle(
            cwd: "/Users/ysq/Work/lab/ccisland",
            sessionId: "3e0a4419-cf88-4389-b37e-d1482a9a7d94",
            prompt: "弹出层中的 session，点击跳转"
        )
        XCTAssertEqual(title, "ccisland · 弹出层中的 session，点击跳转 · ze:3e0a4419")
    }

    func test_formatTitle_withoutPrompt_producesShortFormat() {
        let title = TerminalTitleWriter.formatTitle(
            cwd: "/Users/ysq/Work/lab/ccisland",
            sessionId: "3e0a4419-cf88-4389-b37e-d1482a9a7d94",
            prompt: nil
        )
        XCTAssertEqual(title, "ccisland · ze:3e0a4419")
    }

    func test_formatTitle_withEmptyPrompt_usesShortFormat() {
        let title = TerminalTitleWriter.formatTitle(
            cwd: "/tmp",
            sessionId: "abcdefgh-1234-5678-9abc-def012345678",
            prompt: ""
        )
        XCTAssertEqual(title, "tmp · ze:abcdefgh")
    }

    func test_formatTitle_promptWithNewlines_replaceWithSpaces() {
        let title = TerminalTitleWriter.formatTitle(
            cwd: "/tmp/foo",
            sessionId: "11111111-2222-3333-4444-555555555555",
            prompt: "line1\nline2"
        )
        XCTAssertEqual(title, "foo · line1 line2 · ze:11111111")
    }

    func test_formatTitle_longPrompt_truncatedTo30Chars() {
        let longPrompt = String(repeating: "a", count: 50)
        let title = TerminalTitleWriter.formatTitle(
            cwd: "/tmp/foo",
            sessionId: "11111111-2222-3333-4444-555555555555",
            prompt: longPrompt
        )
        XCTAssertEqual(title, "foo · \(String(repeating: "a", count: 30)) · ze:11111111")
    }

    // MARK: oscEscape

    func test_oscEscape_wrapsWithEsc2AndBel() {
        let osc = TerminalTitleWriter.oscEscape(title: "hello")
        XCTAssertEqual(osc, "\u{001B}]2;hello\u{0007}")
    }

    func test_oscEscape_unicodeIsPreserved() {
        let osc = TerminalTitleWriter.oscEscape(title: "ccisland · ze:3e0a4419")
        XCTAssertEqual(osc, "\u{001B}]2;ccisland · ze:3e0a4419\u{0007}")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
swift test --filter BridgeLibTests.TerminalTitleWriterTests 2>&1 | tail -20
```

Expected: compilation error — `TerminalTitleWriter` not defined.

- [ ] **Step 3: Create TerminalTitleWriter with the pure helpers**

Create `Sources/BridgeLib/TerminalTitleWriter.swift`:

```swift
import Foundation
import Shared

/// Writes OSC 2 tab titles (and manages the prompt cache) for terminal
/// emulators that support title escape sequences (primarily Ghostty).
///
/// Split into pure helpers (`sanitizePrompt`, `truncateToChars`,
/// `formatTitle`, `oscEscape`) and IO (`TitleCache`, `writeIfPossible`).
/// The pure helpers are exhaustively unit-tested; the IO pieces have
/// a small integration shim.
public enum TerminalTitleWriter {

    /// Strip C0 control characters (ESC, BEL, etc.) and replace newlines/tabs
    /// with spaces. Defensive against prompt content that contains terminal
    /// escape sequences which would re-interpret our outer OSC 2 wrapper.
    public static func sanitizePrompt(_ input: String) -> String {
        var out = ""
        out.reserveCapacity(input.count)
        for scalar in input.unicodeScalars {
            let value = scalar.value
            if scalar == "\n" || scalar == "\r" || scalar == "\t" {
                out.append(" ")
            } else if value < 0x20 || value == 0x7F {
                // other C0 / DEL — drop entirely
                continue
            } else {
                out.append(Character(scalar))
            }
        }
        return out
    }

    /// Truncate by character count (Swift `Character`, i.e. grapheme cluster),
    /// not by UTF-8 byte. CJK-friendly.
    public static func truncateToChars(_ input: String, max: Int) -> String {
        guard input.count > max else { return input }
        return String(input.prefix(max))
    }

    /// Compose the tab title.
    /// Format with prompt:    `{basename} · {sanitized prompt[:30]} · ze:{sid[:8]}`
    /// Format without prompt: `{basename} · ze:{sid[:8]}`
    public static func formatTitle(
        cwd: String,
        sessionId: String,
        prompt: String?
    ) -> String {
        let basename = (cwd as NSString).lastPathComponent
        let sidShort = String(sessionId.prefix(8))
        if let raw = prompt, !raw.isEmpty {
            let clean = truncateToChars(sanitizePrompt(raw), max: 30)
            if !clean.isEmpty {
                return "\(basename) · \(clean) · ze:\(sidShort)"
            }
        }
        return "\(basename) · ze:\(sidShort)"
    }

    /// OSC 2 ("set window title") escape sequence:
    /// `ESC ] 2 ; <title> BEL`
    public static func oscEscape(title: String) -> String {
        "\u{001B}]2;\(title)\u{0007}"
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
swift test --filter BridgeLibTests.TerminalTitleWriterTests 2>&1 | tail -30
```

Expected: all 12 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/BridgeLib/TerminalTitleWriter.swift Tests/BridgeLibTests/TerminalTitleWriterTests.swift
git commit -m "feat(terminal): pure helpers for OSC2 tab title formatting

sanitizePrompt, truncateToChars, formatTitle, oscEscape — all pure,
fully unit-tested. IO (tty write + cache) lands in a follow-up commit.
"
```

---

## Task 3: TerminalTitleWriter — prompt cache (disk IO)

Add the on-disk prompt cache: `~/.zackeyes/osc2-titles/{sid[:16]}` — content is the first user prompt (UTF-8). Tests use a tmp-dir-injected version so the real `~/.zackeyes/` is never touched.

**Files:**
- Modify: `Sources/BridgeLib/TerminalTitleWriter.swift` (append `TitleCache`)
- Modify: `Tests/BridgeLibTests/TerminalTitleWriterTests.swift` (append cache tests)

- [ ] **Step 1: Write the failing cache tests**

Append to `Tests/BridgeLibTests/TerminalTitleWriterTests.swift`:

```swift
// MARK: - TitleCache

final class TitleCacheTests: XCTestCase {
    var tmpDir: URL!

    override func setUp() {
        super.setUp()
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("zackeyes-titlecache-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpDir)
        super.tearDown()
    }

    func test_read_missingFile_returnsNil() {
        let cache = TitleCache(directory: tmpDir.path)
        XCTAssertNil(cache.read(sessionId: "3e0a4419-cf88-4389-b37e-d1482a9a7d94"))
    }

    func test_writeIfMissing_thenRead_roundTrips() {
        let cache = TitleCache(directory: tmpDir.path)
        let sid = "3e0a4419-cf88-4389-b37e-d1482a9a7d94"
        cache.writeIfMissing(sessionId: sid, content: "first prompt")
        XCTAssertEqual(cache.read(sessionId: sid), "first prompt")
    }

    func test_writeIfMissing_secondCallIsNoOp() {
        let cache = TitleCache(directory: tmpDir.path)
        let sid = "3e0a4419-cf88-4389-b37e-d1482a9a7d94"
        cache.writeIfMissing(sessionId: sid, content: "first")
        cache.writeIfMissing(sessionId: sid, content: "second")
        XCTAssertEqual(cache.read(sessionId: sid), "first")
    }

    func test_filename_uses16CharSidPrefix() {
        let cache = TitleCache(directory: tmpDir.path)
        let sid = "3e0a4419-cf88-4389-b37e-d1482a9a7d94"
        cache.writeIfMissing(sessionId: sid, content: "x")
        // filename should be the first 16 chars of the UUID
        let expected = tmpDir.appendingPathComponent("3e0a4419-cf88-4").path
        // Note: "3e0a4419-cf88-4" = 15 chars? Actually prefix(16) = "3e0a4419-cf88-43"
        let expected16 = tmpDir.appendingPathComponent("3e0a4419-cf88-43").path
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: expected16),
            "expected cache file at \(expected16), ignoring \(expected)"
        )
    }

    func test_createsDirectoryIfMissing() {
        let nested = tmpDir.appendingPathComponent("subdir/deeper")
        let cache = TitleCache(directory: nested.path)
        cache.writeIfMissing(sessionId: "abcdefgh-1111-2222-3333-444444444444", content: "x")
        XCTAssertEqual(cache.read(sessionId: "abcdefgh-1111-2222-3333-444444444444"), "x")
    }
}
```

- [ ] **Step 2: Run the cache tests to verify they fail**

```bash
swift test --filter BridgeLibTests.TitleCacheTests 2>&1 | tail -20
```

Expected: compilation error — `TitleCache` not defined.

- [ ] **Step 3: Implement TitleCache**

Append to `Sources/BridgeLib/TerminalTitleWriter.swift` (below the `TerminalTitleWriter` enum):

```swift
/// Disk cache of the first user prompt per session, used by
/// `TerminalTitleWriter` to keep tab titles stable once set.
///
/// - Directory: `~/.zackeyes/osc2-titles/` by default
/// - Filename: first 16 ASCII chars of the session UUID
/// - Content: UTF-8 plain text, the (sanitized, truncated) first prompt
public struct TitleCache {
    public let directory: String

    public static let defaultDirectory: String = {
        let home = NSHomeDirectory()
        return (home as NSString).appendingPathComponent(".zackeyes/osc2-titles")
    }()

    public init(directory: String = TitleCache.defaultDirectory) {
        self.directory = directory
    }

    public func read(sessionId: String) -> String? {
        let path = filePath(for: sessionId)
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        return try? String(contentsOfFile: path, encoding: .utf8)
    }

    /// Atomic first-write-wins: write only if the file does not yet exist.
    /// Silent on all errors (the title feature is fire-and-forget).
    public func writeIfMissing(sessionId: String, content: String) {
        let path = filePath(for: sessionId)
        if FileManager.default.fileExists(atPath: path) { return }

        // Ensure parent dir exists
        try? FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true,
            attributes: nil
        )

        try? content.write(toFile: path, atomically: true, encoding: .utf8)
    }

    private func filePath(for sessionId: String) -> String {
        let safe = String(sessionId.prefix(16))
        return (directory as NSString).appendingPathComponent(safe)
    }
}
```

- [ ] **Step 4: Run the cache tests to verify they pass**

```bash
swift test --filter BridgeLibTests.TitleCacheTests 2>&1 | tail -20
```

Expected: all 5 cache tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/BridgeLib/TerminalTitleWriter.swift Tests/BridgeLibTests/TerminalTitleWriterTests.swift
git commit -m "feat(terminal): disk prompt cache for OSC2 titles

~/.zackeyes/osc2-titles/{sid[:16]} — first-write-wins so the session
title stays stable after the first UserPromptSubmit hook. Tests inject
a tmp dir; real ~/.zackeyes/ is never touched.
"
```

---

## Task 4: TerminalTitleWriter.writeIfPossible + Bridge wiring

Add the public IO entry point and wire it into `Bridge/main.swift` so every hook event refreshes the tab title.

**Files:**
- Modify: `Sources/BridgeLib/TerminalTitleWriter.swift`
- Modify: `Sources/Bridge/main.swift`

- [ ] **Step 1: Add `writeIfPossible` to the TerminalTitleWriter enum**

Inside the `TerminalTitleWriter` enum in `Sources/BridgeLib/TerminalTitleWriter.swift`, add:

```swift
    /// Fire-and-forget OSC 2 write. Silent on every failure path.
    /// Sequence of operations:
    ///   1. Resolve tty from `ppid` (Bridge's parent = claude PID). nil → return.
    ///   2. If `prompt` given and cache file missing → write cache (first wins).
    ///   3. Read cached prompt (may be nil).
    ///   4. Compose title + OSC 2.
    ///   5. Open /dev/ttys… for write, write bytes, close. Silent on error.
    public static func writeIfPossible(
        sessionId: String?,
        cwd: String?,
        prompt: String?,
        ppid: Int32,
        cache: TitleCache = TitleCache()
    ) {
        guard let sid = sessionId, !sid.isEmpty,
              let cwd = cwd, !cwd.isEmpty,
              let tty = TTYUtil.ttyPath(pid: ppid) else {
            return
        }

        // Cache the first prompt if we have one and none is stored yet
        if let p = prompt, !p.isEmpty {
            let sanitized = sanitizePrompt(p)
            let clipped = truncateToChars(sanitized, max: 30)
            if !clipped.isEmpty {
                cache.writeIfMissing(sessionId: sid, content: clipped)
            }
        }

        let cachedPrompt = cache.read(sessionId: sid)
        let title = formatTitle(cwd: cwd, sessionId: sid, prompt: cachedPrompt)
        let osc   = oscEscape(title: title)
        guard let data = osc.data(using: .utf8) else { return }

        // Open tty, write, close. Every error path is silent.
        guard let fh = FileHandle(forWritingAtPath: tty) else {
            NSLog("ZackEyes: TitleWriter open-fail tty=%@ sid=%@", tty, sid)
            return
        }
        do {
            try fh.write(contentsOf: data)
            try fh.close()
            NSLog("ZackEyes: TitleWriter tty=%@ sid=%@ bytes=%d ok=1", tty, sid, data.count)
        } catch {
            NSLog("ZackEyes: TitleWriter write-fail tty=%@ sid=%@ err=%@", tty, sid, "\(error)")
        }
    }
```

Note the `import Shared` at the top of the file is already there (added in Task 2).

- [ ] **Step 2: Build to verify TerminalTitleWriter compiles with the new method**

```bash
swift build 2>&1 | tail -5
```

Expected: clean build.

- [ ] **Step 3: Wire `writeIfPossible` into Bridge/main.swift**

Edit `Sources/Bridge/main.swift`. Directly after the existing `// MARK: - Step 3: Inject _bridge_event into JSON payload` section (after `jsonObject["_bridge_ppid"] = Int(getppid())`), and **before** `guard let enrichedData = ...`, insert:

```swift
// MARK: - Step 3.5: Refresh terminal tab title (OSC 2)
// Best-effort; any failure is silent and does not affect the socket path.
let _sid = jsonObject["session_id"] as? String
let _cwd = jsonObject["cwd"] as? String
let _prompt = jsonObject["prompt"] as? String
TerminalTitleWriter.writeIfPossible(
    sessionId: _sid,
    cwd: _cwd,
    prompt: _prompt,
    ppid: getppid()
)
```

- [ ] **Step 4: Build**

```bash
swift build 2>&1 | tail -5
```

Expected: clean build. (Bridge already imports BridgeLib.)

- [ ] **Step 5: Manual smoke test**

```bash
# Make sure the app is NOT running (Bridge should still succeed on OSC2 write even if socket is down)
pkill -f ZackEyes.app || true

# Open a Ghostty tab. Get its tty.
# In Ghostty, run:  tty
# e.g. outputs: /dev/ttys008

# Now from this test terminal, fire a SessionStart event as if we were
# claude running inside that Ghostty tab. The trick: use a shell wrapper so
# its parent pid looks like a claude PID. For a smoke test we just invoke
# bridge directly — ppid will be the shell, not claude, but we only care
# the title code path runs without crash.

echo '{"session_id":"smoke-test-00000000","cwd":"/tmp","prompt":"smoke"}' | \
  .build/debug/bridge --event SessionStart
echo "exit=$?"
```

Expected: exit 1 (socket not running) — Bridge still runs the title path before trying the socket, so check the Ghostty tab title of the test terminal changed to something like `tmp · smoke · ze:smoke-te`.

(If the title didn't change, the Bridge's ppid isn't a tty process — this is fine for the smoke, as long as exit=1 and no crash.)

- [ ] **Step 6: Full build + test**

```bash
swift build 2>&1 | tail -5 && swift test 2>&1 | tail -20
```

Expected: clean build, all tests pass.

- [ ] **Step 7: Commit**

```bash
git add Sources/BridgeLib/TerminalTitleWriter.swift Sources/Bridge/main.swift
git commit -m "feat(bridge): write OSC2 tab title on every hook event

Bridge now refreshes the tab title for the session's tty on every
hook invocation. Title format embeds the session id so the app-side
click handler can find the right tab/pane via AX. Silent failure on
all IO error paths; socket forwarding is unaffected.
"
```

---

## Task 5: TerminalLocator — AX attribute-reading helpers

Small shared helpers used by Layer A and Layer A'. These are thin
wrappers around `AXUIElementCopyAttributeValue` to make the
subsequent code readable. No unit tests — the helpers are glue over
real AX APIs and gain no value from mocking.

**Files:**
- Modify: `Sources/AppLib/Terminal/TerminalLocator.swift`

- [ ] **Step 1: Append helpers to the TerminalLocator enum**

At the end of the `TerminalLocator` enum in
`Sources/AppLib/Terminal/TerminalLocator.swift` (just before the
closing `}`), add:

```swift
    // MARK: - AX attribute helpers (used by Ghostty Layer A / A')

    /// Read a string-valued AX attribute. Returns nil if the attribute
    /// is missing or not a String.
    static func axStringAttr(_ el: AXUIElement, _ attr: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &ref) == .success
        else { return nil }
        return ref as? String
    }

    /// Read the children of an AX element. Returns an empty array if
    /// the attribute is missing or not an array.
    static func axChildren(of el: AXUIElement) -> [AXUIElement] {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            el, kAXChildrenAttribute as CFString, &ref
        ) == .success else { return [] }
        return (ref as? [AXUIElement]) ?? []
    }

    /// Find the first direct child of `el` whose `AXRole` equals `role`.
    static func axFirstChild(of el: AXUIElement, whereRole role: String) -> AXUIElement? {
        for child in axChildren(of: el) {
            if axStringAttr(child, kAXRoleAttribute as String) == role {
                return child
            }
        }
        return nil
    }
```

- [ ] **Step 2: Build**

```bash
swift build 2>&1 | tail -5
```

Expected: clean build. (New helpers are `static`, scope-internal,
unused so far — Swift won't complain because the enum itself is
public.)

- [ ] **Step 3: Run full test suite**

```bash
swift test 2>&1 | tail -20
```

Expected: all existing tests still pass.

- [ ] **Step 4: Commit**

```bash
git add Sources/AppLib/Terminal/TerminalLocator.swift
git commit -m "feat(terminal): AX attribute-reading helpers for Ghostty paths

Three small wrappers around AXUIElementCopyAttributeValue used by
the upcoming Layer A (AXTabButton match) and Layer A' (brute-force
cycling) Ghostty focus paths. No behavior change yet.
"
```

---

## Task 6: focusGhosttySession — Layer A (AXTabButton title match)

The fast path: enumerate each top-level AX window, find its
`AXTabGroup` child, scan the `AXTabButton`s for a title containing
the sid marker, and `AXPress` the match. Wire it into a new
`activateTerminal(containingPid:cwd:sessionId:)` overload.

**Files:**
- Modify: `Sources/AppLib/Terminal/TerminalLocator.swift`

- [ ] **Step 1: Append Layer A implementation to TerminalLocator**

At the end of the `TerminalLocator` enum (just after the helpers
added in Task 5), add:

```swift
    // MARK: - Ghostty Layer A: AXTabButton title match

    /// Primary Ghostty fast path. Enumerates AXTabGroup children, finds
    /// the AXTabButton whose title contains `marker`, AXPresses it.
    /// Returns true on success.
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
            guard let tabGroup = axFirstChild(of: window, whereRole: kAXTabGroupRole as String)
            else { continue }

            for button in axChildren(of: tabGroup) {
                guard axStringAttr(button, kAXSubroleAttribute as String) == "AXTabButton",
                      let title = axStringAttr(button, kAXTitleAttribute as String),
                      title.contains(marker) else { continue }

                if AXUIElementPerformAction(button, kAXPressAction as CFString) == .success {
                    return true
                }
            }
        }
        return false
    }

    /// Entry point called from `activateTerminal` for Ghostty. Calls
    /// Layer A first (fast match on AXTabButton titles); on miss, calls
    /// Layer A' (brute-force cycling — added in Task 7). Returns true on
    /// any successful focus; false → caller falls back to `focusByAccessibility`.
    static func focusGhosttySession(
        app: NSRunningApplication,
        sessionId: String
    ) -> Bool {
        guard AXIsProcessTrusted() else {
            NSLog("ZackEyes: focusGhostty skip=noPermission sid=%{public}@", sessionId)
            return false
        }
        let marker = String(sessionId.prefix(8))
        let appRef = AXUIElementCreateApplication(app.processIdentifier)
        let start = Date()

        if focusGhosttyTabByMarker(appRef: appRef, marker: marker) {
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            NSLog("ZackEyes: focusGhostty layer=A sid=%{public}@ hit=1 elapsed=%dms", sessionId, ms)
            return true
        }

        let ms = Int(Date().timeIntervalSince(start) * 1000)
        NSLog("ZackEyes: focusGhostty layer=A sid=%{public}@ hit=0 elapsed=%dms", sessionId, ms)

        // Layer A' added in Task 7. Stub for now: always returns false.
        return false
    }
```

- [ ] **Step 2: Add the new `activateTerminal` overload**

Add a **new overload** to the `TerminalLocator` enum, near the
existing `activateTerminal(containingPid:cwd:)`. Keep the old one
intact — other callers (e.g. `AppDelegate` notification tap) use it:

```swift
    /// Variant that knows the session id — enables Ghostty Layer A matching.
    /// Non-Ghostty terminals behave identically to
    /// `activateTerminal(containingPid:cwd:)`.
    @discardableResult
    public static func activateTerminal(
        containingPid pid: Int,
        cwd: String? = nil,
        sessionId: String
    ) -> Bool {
        guard let app = findTerminalApp(startingFromPid: pid) else {
            NSLog("ZackEyes: no terminal found for pid %d", pid)
            return false
        }

        let tty = TTYUtil.ttyPath(pid: Int32(pid))
        NSLog("ZackEyes: activating terminal %{public}@ (tty=%{public}@, cwd=%{public}@, sid=%{public}@) for pid %d",
              app.bundleIdentifier ?? "?", tty ?? "nil", cwd ?? "nil", sessionId, pid)

        _ = app.activate(options: [])

        switch app.bundleIdentifier {
        case "com.googlecode.iterm2":
            if let tty = tty { return focusITerm2(tty: tty) }
            return true
        case "com.apple.Terminal":
            if let tty = tty { return focusAppleTerminal(tty: tty) }
            return true
        case "com.mitchellh.ghostty":
            if focusGhosttySession(app: app, sessionId: sessionId) { return true }
            // Final fallback: existing AX window-title raise
            return focusByAccessibility(app: app, cwd: cwd)
        case "dev.warp.Warp-Stable", "dev.warp.Warp",
             "io.alacritty",
             "net.kovidgoyal.kitty":
            return focusByAccessibility(app: app, cwd: cwd)
        default:
            return true
        }
    }
```

**Do not modify** the existing `activateTerminal(containingPid:cwd:)`
method — it stays in place for non-session callers.

- [ ] **Step 3: Build**

```bash
swift build 2>&1 | tail -10
```

Expected: clean build.

- [ ] **Step 4: Run full test suite**

```bash
swift test 2>&1 | tail -20
```

Expected: all existing tests still pass. No unit tests for Layer A
(thin glue over real AX); Task 9 covers it manually.

- [ ] **Step 5: Commit**

```bash
git add Sources/AppLib/Terminal/TerminalLocator.swift
git commit -m "feat(terminal): Ghostty Layer A — AXTabButton title match

New focusGhosttySession + focusGhosttyTabByMarker. Enumerates
Ghostty's AXTabGroup children, finds the AXTabButton whose title
contains the sid marker (written via Bridge OSC2), and AXPresses
it to switch tabs. Also adds
activateTerminal(containingPid:cwd:sessionId:) overload so the
notch click path can pass the session id through. iTerm2 and
Apple Terminal paths untouched.
"
```

---

## Task 7: focusGhosttySession — Layer A' (brute-force cycling)

The slow-path fallback when Layer A misses — i.e. the claude pane
is in a split tab and isn't currently focused, so the AXTabButton
title reflects the other pane and doesn't contain the sid marker.

Iterates each AXTabButton, pressing it to switch tabs, and after
each switch cycles the tab's panes via synthetic `Cmd+Option+Right`
keystrokes (Ghostty's default `goto_split:next` keybinding),
reading the window title after each step until the marker appears
or the 600 ms deadline is hit.

**Files:**
- Modify: `Sources/AppLib/Terminal/TerminalLocator.swift`

- [ ] **Step 1: Add `focusGhosttyByCycling` to TerminalLocator**

At the end of the `TerminalLocator` enum (after the Layer A code from
Task 6), add:

```swift
    // MARK: - Ghostty Layer A': brute-force tab + pane cycling

    /// Post a Cmd+Option+Right keystroke via CGEvent. This is Ghostty's
    /// default `goto_split:next` keybinding. Users who remapped it
    /// will see Layer A' fall through silently.
    private static func postCmdOptionRight() {
        let src = CGEventSource(stateID: .hidSystemState)
        let flags: CGEventFlags = [.maskCommand, .maskAlternate]
        let keyRightArrow: CGKeyCode = 0x7C
        if let down = CGEvent(
            keyboardEventSource: src, virtualKey: keyRightArrow, keyDown: true
        ) {
            down.flags = flags
            down.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(
            keyboardEventSource: src, virtualKey: keyRightArrow, keyDown: false
        ) {
            up.flags = flags
            up.post(tap: .cghidEventTap)
        }
    }

    /// Slow-path fallback for Ghostty. Iterates tabs, within each tab
    /// cycles panes via Cmd+Option+Right, checking the window title
    /// against the marker after each step. Bounded by a 600 ms deadline
    /// and `maxPanesPerTab` iterations per tab.
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

        guard let tabGroup = axFirstChild(of: window, whereRole: kAXTabGroupRole as String)
        else { return false }

        let tabButtons = axChildren(of: tabGroup).filter { el in
            axStringAttr(el, kAXSubroleAttribute as String) == "AXTabButton"
        }
        guard !tabButtons.isEmpty else { return false }

        let deadline = Date().addingTimeInterval(0.6)  // 600 ms hard budget

        for button in tabButtons {
            if Date() >= deadline { return false }

            _ = AXUIElementPerformAction(button, kAXPressAction as CFString)
            Thread.sleep(forTimeInterval: 0.02)

            if let title = axStringAttr(window, kAXTitleAttribute as String),
               title.contains(marker) {
                return true
            }

            for _ in 0..<maxPanesPerTab {
                if Date() >= deadline { return false }
                postCmdOptionRight()
                Thread.sleep(forTimeInterval: 0.02)

                if let title = axStringAttr(window, kAXTitleAttribute as String),
                   title.contains(marker) {
                    return true
                }
            }
        }
        return false
    }
```

- [ ] **Step 2: Invoke Layer A' from `focusGhosttySession`**

Replace the Layer A' stub in `focusGhosttySession` (added in Task 6).

Find this block:

```swift
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        NSLog("ZackEyes: focusGhostty layer=A sid=%{public}@ hit=0 elapsed=%dms", sessionId, ms)

        // Layer A' added in Task 7. Stub for now: always returns false.
        return false
```

And replace with:

```swift
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        NSLog("ZackEyes: focusGhostty layer=A sid=%{public}@ hit=0 elapsed=%dms", sessionId, ms)

        // Layer A' — brute-force tab + pane cycling
        let cycleStart = Date()
        if focusGhosttyByCycling(appRef: appRef, marker: marker) {
            let cycleMs = Int(Date().timeIntervalSince(cycleStart) * 1000)
            NSLog("ZackEyes: focusGhostty layer=A-cycling sid=%{public}@ hit=1 elapsed=%dms",
                  sessionId, cycleMs)
            return true
        }
        let cycleMs = Int(Date().timeIntervalSince(cycleStart) * 1000)
        NSLog("ZackEyes: focusGhostty layer=A-cycling sid=%{public}@ hit=0 elapsed=%dms",
              sessionId, cycleMs)
        return false
```

- [ ] **Step 3: Build**

```bash
swift build 2>&1 | tail -10
```

Expected: clean build.

- [ ] **Step 4: Run full test suite**

```bash
swift test 2>&1 | tail -20
```

Expected: all existing tests still pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/AppLib/Terminal/TerminalLocator.swift
git commit -m "feat(terminal): Ghostty Layer A' — brute-force tab + pane cycling

Slow-path fallback when Layer A can't find the sid marker in any
AXTabButton title (split tab with non-focused claude pane case).
Iterates tabs via AXPress and within each tab cycles panes via
synthetic Cmd+Option+Right keystrokes (Ghostty's default
goto_split:next), reading the window title after each step.
Bounded by 600 ms wall-clock deadline and 4 pane cycles per tab.

Depends on Ghostty's default split-navigation keybinding; users
who remapped it will see this layer silently fall through to
Layer C (focusByAccessibility).
"
```

---


## Task 8: NotchViewModel wiring — call the new overload

Route the notch click path through the new session-aware overload so Ghostty Layer A actually gets a session id.

**Files:**
- Modify: `Sources/AppLib/Notch/NotchViewModel.swift`

- [ ] **Step 1: Change the call site**

In `Sources/AppLib/Notch/NotchViewModel.swift`, find the `activateTerminal(for:)` method. The last line inside the `Task.detached` block currently is:

```swift
            _ = TerminalLocator.activateTerminal(containingPid: pid, cwd: cwd)
```

Replace it with:

```swift
            _ = TerminalLocator.activateTerminal(
                containingPid: pid,
                cwd: cwd,
                sessionId: sessionId
            )
```

Note: `sessionId` is already captured at the top of `activateTerminal(for:)` (see the existing line `let sessionId = session.id`). No other changes needed in this file.

- [ ] **Step 2: Leave the AppDelegate notification tap path unchanged**

Verify `Sources/ZackEyes/AppDelegate.swift:26` still reads:

```swift
            _ = TerminalLocator.activateTerminal(containingPid: pid, cwd: session.cwd)
```

(the old overload, no sessionId). This is intentional — notifications don't need Ghostty Layer A precision, and keeping the old signature means less code churn. Do not change this file.

```bash
grep -n "TerminalLocator.activateTerminal" Sources/ZackEyes/AppDelegate.swift
```

Expected: one match, using the old `(containingPid:cwd:)` signature.

- [ ] **Step 3: Build**

```bash
swift build 2>&1 | tail -10
```

Expected: clean build.

- [ ] **Step 4: Full test suite**

```bash
swift test 2>&1 | tail -20
```

Expected: all tests pass.

- [ ] **Step 5: Assemble the app bundle**

```bash
make app 2>&1 | tail -5
```

Expected: `.build/ZackEyes.app` exists.

- [ ] **Step 6: Commit**

```bash
git add Sources/AppLib/Notch/NotchViewModel.swift
git commit -m "feat(notch): route click-to-jump through new session-aware overload

NotchViewModel.activateTerminal(for:) now passes session.id into
TerminalLocator.activateTerminal so the Ghostty Layer A code path
can find the right tab and pane. Notification-tap path in
AppDelegate still uses the old overload; no regression there.
"
```

---

## Task 9: End-to-end manual verification

No code change. Runs the integration tests from the spec and confirms the design works in practice.

- [ ] **Step 1: Start the app**

```bash
make run 2>&1 | tail -5
```

Expected: ZackEyes starts. Confirm with `ls -la /tmp/zackeyes.sock` (should exist).

- [ ] **Step 2: Grant Accessibility if not already**

If this is a first run with a new bundle, System Settings → Privacy & Security → Accessibility → add/enable ZackEyes.

- [ ] **Step 3: Multi-tab baseline test**

Open Ghostty with **3 tabs** in 3 different projects. In each tab run `claude` and submit an initial prompt. Verify the tab titles change to `{basename} · {prompt[:30]} · ze:{sid[:8]}` within a few seconds of the first prompt.

Click each session card in the ZackEyes notch expanded view. For each click:
- Ghostty must come forward
- The correct tab must become active (not just the window)

Log to check:

```bash
log stream --predicate 'process == "ZackEyes"' --info 2>&1 | grep focusGhostty
```

Expected: `layer=A sid=... hit=1 elapsed=Xms` on successful precision hits.

- [ ] **Step 4: Split-pane test (Layer A' code path)**

In one Ghostty tab: create a vertical split (Cmd+D by default). One
pane runs a plain shell, the other pane runs claude. Submit an
initial prompt in the claude pane so Bridge writes the OSC 2 title.

**Switch focus to the plain shell pane** (so that tab's AXTabButton
title now reflects the shell, NOT claude — this is what forces
Layer A to miss and Layer A' to kick in). Click the claude session
card in ZackEyes.

**Expected**:
- Ghostty comes forward
- Brief visible pane switch inside the split tab (Layer A' cycles
  via Cmd+Option+Right) — ~100 ms
- Final state: focus lands on the **claude pane**, tab title
  flips to the claude pane's title (`{basename} · {prompt} · ze:{sid[:8]}`)
- Log line `ZackEyes: focusGhostty layer=A-cycling sid=... hit=1 elapsed=Xms`

If the focus lands on a different pane or no transition happens,
double-check that Ghostty's `goto_split:next` is still bound to
`Cmd+Option+Right` (it's the default). If the user remapped it,
Layer A' fails silently and we fall through to Layer C.

Verify with:

```bash
/bin/bash -c 'log show --last 2m --predicate "process == \"ZackEyes\"" --info 2>&1 | grep focusGhostty'
```

- [ ] **Step 5: iTerm2 regression test**

Open iTerm2, start claude in a tab, click its session card in ZackEyes. Verify the existing precise-tab AppleScript path still works (unrelated to this change, but must not regress).

- [ ] **Step 6: Cold start test**

Kill ZackEyes while claude sessions are running:

```bash
pkill -f ZackEyes.app
```

Restart:

```bash
make run
```

Submit one more prompt in each session (so a UserPromptSubmit hook fires and the title is re-asserted). Click each session card. Verify precise jumping still works.

- [ ] **Step 7: No-cwd edge case**

(Optional; hard to reproduce without a synthetic event.) Confirm no crash by reading logs for any `fatalError` or panic.

- [ ] **Step 8: Update `CHANGELOG.md`**

Append an entry under the current unreleased section:

```markdown
- **Ghostty**: precise tab + split-pane click-to-jump. ZackEyes now
  embeds the session id in each tab title via an OSC 2 escape
  (written by Bridge on every hook event). On click, Layer A
  enumerates Ghostty's AX tab buttons and presses the one whose
  title contains the session id marker. When the claude pane is in
  a split and another pane is focused, Layer A' cycles tabs and
  panes via synthetic Cmd+Option+Right keystrokes (bounded 600 ms)
  until the marker is found.
```

- [ ] **Step 9: Commit the changelog**

```bash
git add CHANGELOG.md
git commit -m "docs(changelog): Ghostty precise tab-jump landed"
```

---

## Completion criteria

- All 9 tasks checked off
- `swift build` clean
- `swift test` all green (the new SharedTests / BridgeLibTests / AppLibTests tests plus existing suite)
- `make app` succeeds
- Manual tests in Task 9 pass for at least multi-tab baseline (Task 9 Step 3) and the split-pane case behaves per the Task 0 finding
- No `exit(2)` in Bridge code paths (grep verification):

```bash
grep -n "exit(2)" Sources/Bridge Sources/BridgeLib
```

Expected: no matches.

- iTerm2 and Apple Terminal regression check in Task 9 Step 5 passes
