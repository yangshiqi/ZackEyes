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

## Task 0: Verify Ghostty AX tree assumption

Before writing any production code, confirm whether Ghostty exposes per-pane `AXUIElement`s with their own `kAXTitleAttribute`. This decides whether Layer A (AX tree walk) is viable as specified or whether the plan needs a Layer A' pane-cycling extension.

**Files:**
- Create: `Tools/verify-ghostty-ax.swift` (not added to `Package.swift`)
- Write-only artifact: `/tmp/ghostty-ax-dump.txt`

- [ ] **Step 1: Create the verification script**

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

## Task 5: TerminalLocator — testable `walk` function

Add the bounded AX tree walker as a pure function parameterized over attribute getters, so we can exhaustively unit-test depth/visit/deadline limits without touching the real AX API.

**Files:**
- Modify: `Sources/AppLib/Terminal/TerminalLocator.swift`
- Create: `Tests/AppLibTests/TerminalLocatorWalkTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `Tests/AppLibTests/TerminalLocatorWalkTests.swift`:

```swift
import XCTest
@testable import AppLib

/// Fake AX tree for testing the walker without AX.
/// Node identity is by reference (`ObjectIdentifier`) so the closures
/// can answer `title(for:)` / `children(for:)` by lookup.
final class FakeAXNode {
    let title: String?
    let children: [FakeAXNode]
    init(title: String?, children: [FakeAXNode] = []) {
        self.title = title
        self.children = children
    }
}

final class TerminalLocatorWalkTests: XCTestCase {

    /// Helper: build a FakeNodeFinder-style walk context closure pair.
    private func ctx(for root: FakeAXNode) -> (
        titleOf: (FakeAXNode) -> String?,
        childrenOf: (FakeAXNode) -> [FakeAXNode]
    ) {
        return ({ $0.title }, { $0.children })
    }

    func test_walk_findsDirectChildMatch() {
        let target = FakeAXNode(title: "ccisland · ze:3e0a4419")
        let root = FakeAXNode(title: "window", children: [
            FakeAXNode(title: "other", children: []),
            target,
        ])
        let (titleOf, childrenOf) = ctx(for: root)

        var visited = 0
        let result = TerminalLocator.walk(
            node: root,
            marker: "3e0a4419",
            depth: 0,
            maxDepth: 6,
            visited: &visited,
            maxVisited: 1000,
            deadline: Date.distantFuture,
            titleOf: titleOf,
            childrenOf: childrenOf
        )
        XCTAssertNotNil(result)
        XCTAssertTrue(result === target)
    }

    func test_walk_findsDeepDescendantMatch() {
        let target = FakeAXNode(title: "leaf · 3e0a4419 deep")
        let tree = FakeAXNode(title: "w", children: [
            FakeAXNode(title: "a", children: [
                FakeAXNode(title: "b", children: [
                    FakeAXNode(title: "c", children: [target]),
                ]),
            ]),
        ])
        let (titleOf, childrenOf) = ctx(for: tree)
        var visited = 0
        let result = TerminalLocator.walk(
            node: tree,
            marker: "3e0a4419",
            depth: 0,
            maxDepth: 6,
            visited: &visited,
            maxVisited: 1000,
            deadline: Date.distantFuture,
            titleOf: titleOf, childrenOf: childrenOf
        )
        XCTAssertTrue(result === target)
    }

    func test_walk_depthLimitRespected() {
        // Target is 7 levels deep; maxDepth 6 means we must NOT find it.
        func chain(depth: Int) -> FakeAXNode {
            if depth == 0 { return FakeAXNode(title: "3e0a4419") }
            return FakeAXNode(title: "n\(depth)", children: [chain(depth: depth - 1)])
        }
        let root = chain(depth: 7)
        var visited = 0
        let result = TerminalLocator.walk(
            node: root,
            marker: "3e0a4419",
            depth: 0,
            maxDepth: 6,
            visited: &visited,
            maxVisited: 1000,
            deadline: Date.distantFuture,
            titleOf: { $0.title },
            childrenOf: { $0.children }
        )
        XCTAssertNil(result, "should not reach depth 7 with maxDepth 6")
    }

    func test_walk_visitLimitRespected() {
        // Wide tree, 100 children each with no match. maxVisited=5 → stop early.
        let wide = FakeAXNode(
            title: "root",
            children: (0..<100).map { FakeAXNode(title: "x\($0)") }
        )
        var visited = 0
        _ = TerminalLocator.walk(
            node: wide,
            marker: "no-such-marker",
            depth: 0,
            maxDepth: 6,
            visited: &visited,
            maxVisited: 5,
            deadline: Date.distantFuture,
            titleOf: { $0.title },
            childrenOf: { $0.children }
        )
        XCTAssertLessThanOrEqual(visited, 5)
    }

    func test_walk_deadlineRespected() {
        let wide = FakeAXNode(
            title: "root",
            children: (0..<100).map { FakeAXNode(title: "x\($0)") }
        )
        var visited = 0
        _ = TerminalLocator.walk(
            node: wide,
            marker: "no-such-marker",
            depth: 0,
            maxDepth: 6,
            visited: &visited,
            maxVisited: 1000,
            deadline: Date().addingTimeInterval(-1),  // already expired
            titleOf: { $0.title },
            childrenOf: { $0.children }
        )
        XCTAssertEqual(visited, 0, "deadline already expired; walk must return immediately")
    }

    func test_walk_returnsNilWhenNothingMatches() {
        let tree = FakeAXNode(title: "w", children: [
            FakeAXNode(title: "a", children: [
                FakeAXNode(title: "b"),
            ]),
        ])
        var visited = 0
        let result = TerminalLocator.walk(
            node: tree,
            marker: "nope",
            depth: 0,
            maxDepth: 6,
            visited: &visited,
            maxVisited: 1000,
            deadline: Date.distantFuture,
            titleOf: { $0.title },
            childrenOf: { $0.children }
        )
        XCTAssertNil(result)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
swift test --filter AppLibTests.TerminalLocatorWalkTests 2>&1 | tail -20
```

Expected: compilation error — `walk` not defined.

- [ ] **Step 3: Add the generic walker to TerminalLocator**

Append to the `TerminalLocator` enum in `Sources/AppLib/Terminal/TerminalLocator.swift` (before the closing `}` of the enum):

```swift
    // MARK: - Bounded AX tree walk
    //
    // Generic over the node type so it can be unit-tested with a fake
    // tree. Production callers pass `AXUIElement` nodes plus AX-backed
    // closures; tests pass `FakeAXNode` plus in-memory closures.

    /// Visit `node` and its descendants depth-first, returning the first
    /// node whose title contains `marker`. Bounded by depth, visit count,
    /// and wall-clock deadline.
    static func walk<Node: AnyObject>(
        node: Node,
        marker: String,
        depth: Int,
        maxDepth: Int,
        visited: inout Int,
        maxVisited: Int,
        deadline: Date,
        titleOf: (Node) -> String?,
        childrenOf: (Node) -> [Node]
    ) -> Node? {
        if depth > maxDepth || visited >= maxVisited || Date() >= deadline {
            return nil
        }
        visited += 1

        if let title = titleOf(node), title.contains(marker) {
            return node
        }

        for child in childrenOf(node) {
            if let found = walk(
                node: child,
                marker: marker,
                depth: depth + 1,
                maxDepth: maxDepth,
                visited: &visited,
                maxVisited: maxVisited,
                deadline: deadline,
                titleOf: titleOf,
                childrenOf: childrenOf
            ) {
                return found
            }
        }
        return nil
    }
```

`walk` is the generic bounded tree walker. Production code in Task 6 calls it with `AXUIElement` as `Node`; tests call it with `FakeAXNode`. No name clash with anything else in `TerminalLocator`.

- [ ] **Step 4: Run the tests to verify they pass**

```bash
swift test --filter AppLibTests.TerminalLocatorWalkTests 2>&1 | tail -20
```

Expected: all 6 walk tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/AppLib/Terminal/TerminalLocator.swift Tests/AppLibTests/TerminalLocatorWalkTests.swift
git commit -m "feat(terminal): bounded AX tree walker with unit tests

Generic walker over any node type with (title, children) closures.
Enforces depth, visit, and deadline limits. Tested with a fake tree
so the logic is exercised without touching AX.
"
```

---

## Task 6: focusGhosttySession — Layer A (AX tree walk)

Wrap the generic walker with AX-backed closures and build `focusGhosttySession`. Wire it into the Ghostty case of `activateTerminal`.

**Files:**
- Modify: `Sources/AppLib/Terminal/TerminalLocator.swift`

- [ ] **Step 1: Add `axFindElementMatching` and `focusGhosttySession` to TerminalLocator**

Append to the `TerminalLocator` enum, **just below** the `walk` function added in Task 5:

```swift
    /// AX-backed adapter over `walk`. Searches the windows of `appRef`
    /// for an element whose title contains `marker`. Returns the matching
    /// element along with its ancestor AX window (the tab it lives in).
    static func axFindElementMatching(
        appRef: AXUIElement,
        marker: String
    ) -> (window: AXUIElement, element: AXUIElement)? {
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appRef, kAXWindowsAttribute as CFString, &windowsRef
        ) == .success,
              let windows = windowsRef as? [AXUIElement], !windows.isEmpty
        else { return nil }

        let deadline = Date().addingTimeInterval(0.05)  // 50 ms budget
        var visited = 0

        let titleOf: (AXUIElement) -> String? = { el in
            var v: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                el, kAXTitleAttribute as CFString, &v
            ) == .success else { return nil }
            return v as? String
        }
        let childrenOf: (AXUIElement) -> [AXUIElement] = { el in
            var v: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                el, kAXChildrenAttribute as CFString, &v
            ) == .success else { return [] }
            return (v as? [AXUIElement]) ?? []
        }

        for window in windows {
            if let match = walk(
                node: window,
                marker: marker,
                depth: 0,
                maxDepth: 6,
                visited: &visited,
                maxVisited: 1000,
                deadline: deadline,
                titleOf: titleOf,
                childrenOf: childrenOf
            ) {
                return (window, match)
            }
            if Date() >= deadline || visited >= 1000 { break }
        }
        return nil
    }

    /// High-level Ghostty (and similar AX-only terminals) tab+pane focus.
    /// Returns true on success; caller should fall back to
    /// `focusByAccessibility` on false.
    static func focusGhosttySession(
        app: NSRunningApplication,
        sessionId: String
    ) -> Bool {
        guard AXIsProcessTrusted() else {
            NSLog("ZackEyes: focusGhostty layer=A skip=noPermission sid=%@", sessionId)
            return false
        }
        let marker = String(sessionId.prefix(8))
        let appRef = AXUIElementCreateApplication(app.processIdentifier)
        let start = Date()

        if let (window, element) = axFindElementMatching(appRef: appRef, marker: marker) {
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            if CFEqual(window, element) == false {
                AXUIElementSetAttributeValue(
                    element, kAXFocusedAttribute as CFString, kCFBooleanTrue
                )
            }
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            NSLog("ZackEyes: focusGhostty layer=A sid=%@ hit=1 elapsed=%dms", sessionId, ms)
            return true
        }

        let ms = Int(Date().timeIntervalSince(start) * 1000)
        NSLog("ZackEyes: focusGhostty layer=A sid=%@ hit=0 elapsed=%dms", sessionId, ms)
        return false
    }
```

- [ ] **Step 2: Wire `focusGhosttySession` into `activateTerminal`**

Find the existing switch case in `activateTerminal(containingPid:cwd:)` for Ghostty/Warp/Kitty/Alacritty (around line 169–177 of the original file). Add a **new overload** just above the existing function, keeping the old one intact for non-session callers:

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
            // Layer C fallback
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

**Do not modify** the existing `activateTerminal(containingPid:cwd:)` method — it stays in place for callers that don't have a session id (notification tap, etc.).

- [ ] **Step 3: Build**

```bash
swift build 2>&1 | tail -10
```

Expected: clean build.

- [ ] **Step 4: Full test suite**

```bash
swift test 2>&1 | tail -20
```

Expected: all tests pass. No AX calls are exercised at unit-test time.

- [ ] **Step 5: Commit**

```bash
git add Sources/AppLib/Terminal/TerminalLocator.swift
git commit -m "feat(terminal): Ghostty Layer A — AX tree walk tab+pane focus

New overload activateTerminal(containingPid:cwd:sessionId:) routes
Ghostty through focusGhosttySession, which walks the AX subtree of
each Ghostty window looking for an element whose title contains
the sid marker. On hit: AXRaise the ancestor window and set
kAXFocusedAttribute on the matched element. Falls back to the
existing focusByAccessibility on miss. iTerm2/Terminal paths
untouched.
"
```

---

## Task 7: focusGhosttySession — Layer B (Window menu AXPress)

Add the Window-menu fallback between Layer A and Layer C.

**Files:**
- Modify: `Sources/AppLib/Terminal/TerminalLocator.swift`

- [ ] **Step 1: Add `pressWindowMenuItemMatching` to TerminalLocator**

Append to the `TerminalLocator` enum, below `focusGhosttySession`:

```swift
    /// Layer B fallback: press the matching item in the app's Window menu.
    /// Works whenever the target tab's focused pane has a title containing
    /// our marker — macOS auto-populates the Window menu with tab titles.
    static func pressWindowMenuItemMatching(
        appRef: AXUIElement,
        marker: String,
        cwd: String?
    ) -> Bool {
        // Step 1: get menu bar
        var barRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appRef, kAXMenuBarAttribute as CFString, &barRef
        ) == .success, let menuBar = barRef else { return false }
        // Runtime-cast via CF type check
        guard CFGetTypeID(menuBar) == AXUIElementGetTypeID() else { return false }
        let menuBarEl = menuBar as! AXUIElement

        // Step 2: find "Window" top-level item (localized)
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
               let title = t as? String,
               windowMenuTitles.contains(title) {
                windowBarItem = item
                break
            }
        }
        guard let barItem = windowBarItem else { return false }

        // Step 3: descend into the AXMenu
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

        // Fixed items to skip — static English list for MVP
        let skipTitles: Set<String> = [
            "Minimize", "Zoom", "Move Tab to New Window",
            "Merge All Windows", "Show Previous Tab", "Show Next Tab",
            "Move Tab Left", "Move Tab Right", "Bring All to Front",
            "Close Tab", "Close Window",
        ]

        let basename = (cwd as NSString?)?.lastPathComponent ?? ""
        var best: (el: AXUIElement, score: Int)?

        for item in items {
            var t: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                item, kAXTitleAttribute as CFString, &t
            ) == .success,
                  let title = t as? String,
                  !title.isEmpty,
                  !skipTitles.contains(title) else { continue }

            var score = 0
            if title.contains(marker) { score = 5 }
            else if !basename.isEmpty, title.contains(basename) { score = 2 }
            else { continue }

            if score > (best?.score ?? 0) {
                best = (item, score)
            }
        }

        guard let target = best, target.score >= 3 else { return false }
        let result = AXUIElementPerformAction(target.el, kAXPressAction as CFString)
        NSLog("ZackEyes: focusGhostty layer=B hit=%d score=%d", result == .success ? 1 : 0, target.score)
        return result == .success
    }
```

- [ ] **Step 2: Call Layer B from `focusGhosttySession`**

Edit `focusGhosttySession` (added in Task 6). After the Layer A block returns false (before `return false`), insert Layer B:

Replace:

```swift
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        NSLog("ZackEyes: focusGhostty layer=A sid=%@ hit=0 elapsed=%dms", sessionId, ms)
        return false
```

With:

```swift
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        NSLog("ZackEyes: focusGhostty layer=A sid=%@ hit=0 elapsed=%dms", sessionId, ms)

        // Layer B — Window menu press
        if pressWindowMenuItemMatching(
            appRef: appRef,
            marker: marker,
            cwd: nil  // basename not available here; marker-only match in Layer B
        ) {
            return true
        }
        return false
```

Note: we intentionally pass `cwd: nil` so Layer B only matches on the marker (score 5). Basename matching is left to Layer C (`focusByAccessibility`). This keeps Layer B's failure mode strict — if the marker is missing, fall through to Layer C rather than guess wrong in Layer B.

- [ ] **Step 3: Build**

```bash
swift build 2>&1 | tail -10
```

Expected: clean build.

- [ ] **Step 4: Full test suite**

```bash
swift test 2>&1 | tail -20
```

Expected: all existing tests still pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/AppLib/Terminal/TerminalLocator.swift
git commit -m "feat(terminal): Ghostty Layer B — Window menu AXPress fallback

When Layer A can't find a matching AX element (e.g. Ghostty doesn't
expose non-focused pane titles), try pressing the matching item in
the app's Window menu. macOS auto-populates Window menu with the
title of each tab's focused pane, so this catches tab-level matches
when the claude pane is the focused one. Marker-only match — no
basename guessing, that stays in Layer C.
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

- [ ] **Step 4: Split-pane test**

In one Ghostty tab: create a vertical split (Cmd+D by default). One pane runs a plain shell, the other pane runs claude. Submit an initial prompt in the claude pane.

Switch focus to the plain shell pane (so the tab title shows the shell's title, not claude's). Click the claude session card in ZackEyes.

**Expected**:
- If Layer A is viable (Task 0 result): the claude pane receives focus — cursor should land inside it, tab title flips to the claude pane's title.
- If Layer A is not viable: at minimum the correct tab becomes active; pane may still be the plain shell. (This is the degraded case documented in the spec.)

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
  embeds the session id in each tab title via an OSC 2 escape (written
  by Bridge on every hook event) and uses a bounded AX tree walk to
  focus the exact pane on click. Layered fallbacks (Window menu
  AXPress, existing AX raise) keep less-common cases reasonable.
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
