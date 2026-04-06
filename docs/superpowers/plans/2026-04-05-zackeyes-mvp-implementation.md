# ZackEyes MVP Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a macOS native app that monitors Claude Code via hooks and shows a notch overlay panel for permission approval.

**Architecture:** Three components — Bridge CLI (invoked by Claude Code hooks, forwards events via Unix Socket), Main App (SwiftUI + AppKit, listens on socket, shows NotchPanel), and Hook Auto-Installer (injects hook config into `~/.claude/settings.json`). Communication is JSON over Unix Domain Socket.

**Tech Stack:** Swift 6, SwiftUI, AppKit (NSPanel), Foundation (Unix Socket), Swift Package Manager + Makefile for .app bundle assembly.

**Design Spec:** `docs/superpowers/specs/2026-04-05-zackeyes-mvp-design.md`

**Note on build system:** We use Swift Package Manager instead of .xcodeproj for agent-friendly builds. Open `Package.swift` in Xcode for IDE support. The Makefile assembles the .app bundle with Info.plist and embedded Bridge binary.

---

## File Map

### New Files — Shared

| File | Responsibility |
|------|---------------|
| `Package.swift` | SPM manifest: 3 targets (Shared library, ZackEyes executable, Bridge executable) |
| `Makefile` | Build, assemble .app bundle, run, clean |
| `Resources/Info.plist` | App metadata: LSUIElement, bundle ID, entitlements |
| `Sources/Shared/EventProtocol.swift` | Codable types: `BridgeEvent`, `PermissionResponse`, `SessionState` enum |

### New Files — Bridge CLI

| File | Responsibility |
|------|---------------|
| `Sources/BridgeLib/SocketClient.swift` | Connect to Unix socket, send JSON, optionally wait for response |
| `Sources/Bridge/main.swift` | Thin entry point: parse stdin, route by event, exit code handling |

### New Files — Main App

| File | Responsibility |
|------|---------------|
| `Sources/AppLib/Socket/SocketServer.swift` | Listen on `/tmp/zackeyes.sock`, accept connections, parse events, send responses |
| `Sources/AppLib/Session/SessionStore.swift` | ObservableObject: session state machine, pending permission request |
| `Sources/AppLib/Hooks/HookInstaller.swift` | Read/merge/write `~/.claude/settings.json`, deploy launcher script |
| `Sources/AppLib/Notch/NotchPanel.swift` | NSPanel subclass with correct window level, behavior, mouse events |
| `Sources/AppLib/Notch/NotchWindowController.swift` | Notch geometry, positioning, expand/collapse animation, screen change observer |
| `Sources/AppLib/Notch/NotchViewModel.swift` | ObservableObject bridging SessionStore to SwiftUI views |
| `Sources/AppLib/Notch/NotchCompactView.swift` | SwiftUI: status dot + label + tool badge |
| `Sources/AppLib/Notch/NotchExpandedView.swift` | SwiftUI: permission detail + Deny/Allow/Always buttons |
| `Sources/AppLib/Notch/NSScreen+Notch.swift` | Extension: hasNotch, notchSize, notchFrame |
| `Sources/AppLib/MenuBar/MenuBarFallback.swift` | NSStatusItem + NSPopover for notchless Macs |
| `Sources/ZackEyes/main.swift` | Thin entry point: NSApplication setup + AppDelegate |
| `Sources/ZackEyes/AppDelegate.swift` | NSApplicationDelegate, startup wiring |

**Why BridgeLib + AppLib?** SPM executable targets (with top-level `main.swift`) cannot be `@testable import`-ed. Extracting logic into library targets enables unit testing. The executable targets are thin wrappers.

### Test Files

| File | Tests |
|------|-------|
| `Tests/SharedTests/EventProtocolTests.swift` | JSON encode/decode round-trips for all event types |
| `Tests/BridgeLibTests/SocketClientTests.swift` | Connect, send, receive, timeout, socket-missing scenarios |
| `Tests/AppLibTests/SessionStoreTests.swift` | State transitions: idle to working to waiting to idle, edge cases |
| `Tests/AppLibTests/HookInstallerTests.swift` | Merge logic, backup creation, parse failure safety, uninstall |

---

## Task 1: Project Scaffolding

**Files:**
- Create: `Package.swift`
- Create: `Makefile`
- Create: `Resources/Info.plist`
- Create: `Sources/ZackEyes/App/main.swift` (minimal placeholder)
- Create: `Sources/Bridge/main.swift` (minimal placeholder)
- Create: `Sources/Shared/EventProtocol.swift` (minimal placeholder)

- [ ] **Step 1: Create Package.swift**

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ZackEyes",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ZackEyes", targets: ["ZackEyes"]),
        .executable(name: "bridge", targets: ["Bridge"]),
    ],
    targets: [
        // --- Libraries (testable) ---
        .target(
            name: "Shared",
            path: "Sources/Shared"
        ),
        .target(
            name: "BridgeLib",
            dependencies: ["Shared"],
            path: "Sources/BridgeLib"
        ),
        .target(
            name: "AppLib",
            dependencies: ["Shared"],
            path: "Sources/AppLib",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
            ]
        ),
        // --- Executables (thin entry points) ---
        .executableTarget(
            name: "ZackEyes",
            dependencies: ["AppLib"],
            path: "Sources/ZackEyes"
        ),
        .executableTarget(
            name: "Bridge",
            dependencies: ["BridgeLib"],
            path: "Sources/Bridge"
        ),
        // --- Tests (depend on libraries, not executables) ---
        .testTarget(
            name: "SharedTests",
            dependencies: ["Shared"],
            path: "Tests/SharedTests"
        ),
        .testTarget(
            name: "BridgeLibTests",
            dependencies: ["BridgeLib"],
            path: "Tests/BridgeLibTests"
        ),
        .testTarget(
            name: "AppLibTests",
            dependencies: ["AppLib"],
            path: "Tests/AppLibTests"
        ),
    ]
)
```

- [ ] **Step 2: Create Makefile**

```makefile
.PHONY: build build-release run clean app test

APP_NAME = ZackEyes
APP_BUNDLE = .build/$(APP_NAME).app
CONTENTS = $(APP_BUNDLE)/Contents
MACOS = $(CONTENTS)/MacOS
HELPERS = $(CONTENTS)/Helpers
RESOURCES = $(CONTENTS)/Resources

build:
	swift build

build-release:
	swift build -c release

app: build
	$(eval BIN_PATH := $(shell swift build --show-bin-path))
	mkdir -p $(MACOS) $(HELPERS) $(RESOURCES)
	cp $(BIN_PATH)/ZackEyes $(MACOS)/ZackEyes
	cp $(BIN_PATH)/bridge $(HELPERS)/bridge
	cp Resources/Info.plist $(CONTENTS)/Info.plist
	@echo "Built $(APP_BUNDLE)"

app-release: build-release
	$(eval BIN_PATH := $(shell swift build -c release --show-bin-path))
	mkdir -p $(MACOS) $(HELPERS) $(RESOURCES)
	cp $(BIN_PATH)/ZackEyes $(MACOS)/ZackEyes
	cp $(BIN_PATH)/bridge $(HELPERS)/bridge
	cp Resources/Info.plist $(CONTENTS)/Info.plist
	@echo "Built $(APP_BUNDLE) (release)"

run: app
	open $(APP_BUNDLE)

test:
	swift test

clean:
	swift package clean
	rm -rf $(APP_BUNDLE)
```

- [ ] **Step 3: Create Resources/Info.plist**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDisplayName</key>
    <string>ZackEyes</string>
    <key>CFBundleExecutable</key>
    <string>ZackEyes</string>
    <key>CFBundleIdentifier</key>
    <string>app.zackeyes.macos</string>
    <key>CFBundleName</key>
    <string>ZackEyes</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>ZackEyes needs to control terminal apps to jump to the correct window when you click a notification.</string>
</dict>
</plist>
```

- [ ] **Step 4: Create minimal source placeholders**

`Sources/Shared/EventProtocol.swift`:
```swift
import Foundation

// Placeholder — full implementation in Task 2
public enum SessionState: String, Codable, Sendable {
    case idle, working, waiting, stopped
}
```

`Sources/BridgeLib/SocketClient.swift`:
```swift
import Foundation

// Placeholder — full implementation in Task 3
public struct BridgeSocketClient: Sendable {
    public init(path: String) {}
}
```

`Sources/Bridge/main.swift`:
```swift
import Foundation
import BridgeLib

// Placeholder — full implementation in Task 4
exit(1)
```

`Sources/AppLib/Placeholder.swift`:
```swift
import Foundation

// Placeholder — full implementation in Tasks 5-9
// This file can be deleted once real modules are added.
public enum AppLibMarker {}
```

`Sources/ZackEyes/main.swift`:
```swift
import AppKit
import AppLib

// Placeholder — full implementation in Task 11
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.run()
```

- [ ] **Step 5: Verify build compiles**

Run: `cd /Users/ysq/Work/lab/ccisland && swift build 2>&1 | tail -5`
Expected: `Build complete!`

- [ ] **Step 6: Verify .app bundle assembles**

Run: `cd /Users/ysq/Work/lab/ccisland && make app 2>&1`
Expected: `Built .build/ZackEyes.app`

Run: `ls .build/ZackEyes.app/Contents/MacOS/ZackEyes .build/ZackEyes.app/Contents/Helpers/bridge .build/ZackEyes.app/Contents/Info.plist`
Expected: all three files exist

- [ ] **Step 7: Initialize git and commit**

```bash
cd /Users/ysq/Work/lab/ccisland
git init
git add Package.swift Makefile Resources/Info.plist Sources/ .gitignore CLAUDE.md AGENTS.md ARCHITECTURE.md docs/
git commit -m "chore: scaffold project with SPM, Makefile, and harness docs"
```

---

## Task 2: Event Protocol (Shared Types)

**Files:**
- Modify: `Sources/Shared/EventProtocol.swift`
- Create: `Tests/SharedTests/EventProtocolTests.swift`

- [ ] **Step 1: Write tests for BridgeEvent decoding**

`Tests/SharedTests/EventProtocolTests.swift`:
```swift
import Testing
import Foundation
@testable import Shared

@Test func decodeBridgeEvent_sessionStart() throws {
    let json = """
    {"_bridge_event":"SessionStart","session_id":"abc","hook_event_name":"SessionStart","cwd":"/tmp"}
    """.data(using: .utf8)!
    let event = try JSONDecoder().decode(BridgeEvent.self, from: json)
    #expect(event.bridgeEvent == "SessionStart")
    #expect(event.sessionId == "abc")
    #expect(event.cwd == "/tmp")
    #expect(event.toolName == nil)
}

@Test func decodeBridgeEvent_permissionRequest() throws {
    let json = """
    {"_bridge_event":"PermissionRequest","session_id":"abc","hook_event_name":"PermissionRequest","cwd":"/tmp","tool_name":"Bash","tool_input":{"command":"rm -rf /tmp/test"}}
    """.data(using: .utf8)!
    let event = try JSONDecoder().decode(BridgeEvent.self, from: json)
    #expect(event.bridgeEvent == "PermissionRequest")
    #expect(event.toolName == "Bash")
    #expect(event.toolInput != nil)
}

@Test func encodePermissionResponse_allow() throws {
    let response = PermissionResponse.allow(message: "User approved via ZackEyes")
    let data = try JSONEncoder().encode(response)
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    let hookOutput = json["hookSpecificOutput"] as! [String: Any]
    let decision = hookOutput["decision"] as! [String: Any]
    #expect(decision["behavior"] as? String == "allow")
    #expect(decision["message"] as? String == "User approved via ZackEyes")
    #expect(hookOutput["hookEventName"] as? String == "PermissionRequest")
}

@Test func encodePermissionResponse_deny() throws {
    let response = PermissionResponse.deny(message: "User denied")
    let data = try JSONEncoder().encode(response)
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    let hookOutput = json["hookSpecificOutput"] as! [String: Any]
    let decision = hookOutput["decision"] as! [String: Any]
    #expect(decision["behavior"] as? String == "deny")
}

@Test func sessionState_allCases() {
    #expect(SessionState.idle.rawValue == "idle")
    #expect(SessionState.working.rawValue == "working")
    #expect(SessionState.waiting.rawValue == "waiting")
    #expect(SessionState.stopped.rawValue == "stopped")
}

@Test func decodeBridgeEvent_unknownFieldsIgnored() throws {
    let json = """
    {"_bridge_event":"PreToolUse","session_id":"s1","hook_event_name":"PreToolUse","cwd":"/tmp","tool_name":"Read","unknown_field":"ignored"}
    """.data(using: .utf8)!
    let event = try JSONDecoder().decode(BridgeEvent.self, from: json)
    #expect(event.bridgeEvent == "PreToolUse")
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/ysq/Work/lab/ccisland && swift test --filter SharedTests 2>&1 | tail -10`
Expected: FAIL — `BridgeEvent` and `PermissionResponse` not defined

- [ ] **Step 3: Implement EventProtocol types**

Replace `Sources/Shared/EventProtocol.swift` with full implementation containing: `SessionState` enum, `BridgeEvent` struct (Codable with snake_case CodingKeys, optional fields for toolName/toolInput/etc), `PermissionResponse` struct (with nested `HookSpecificOutput.Decision`, plus `allow(message:)` and `deny(message:)` factory methods), and `AnyCodable` type-erased wrapper for JSON passthrough of tool_input.

**IMPORTANT:** `BridgeEvent` MUST have an explicit `public init(...)` with all parameters (memberwise inits are `internal` by default — tests in other modules cannot construct instances without a public init):

```swift
public init(
    bridgeEvent: String,
    sessionId: String? = nil,
    hookEventName: String? = nil,
    cwd: String? = nil,
    toolName: String? = nil,
    toolInput: [String: AnyCodable]? = nil,
    permissionMode: String? = nil,
    transcriptPath: String? = nil
) { ... }
```

The `BridgeEvent` CodingKeys map `_bridge_event` to `bridgeEvent`, `session_id` to `sessionId`, `hook_event_name` to `hookEventName`, `tool_name` to `toolName`, `tool_input` to `toolInput`, `permission_mode` to `permissionMode`, `transcript_path` to `transcriptPath`.

The `PermissionResponse` encodes as `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow|deny","message":"..."}}}`.

The `AnyCodable` handles String, Int, Double, Bool, nested Dict, Array, and null — matching any JSON value Claude Code might send in `tool_input`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /Users/ysq/Work/lab/ccisland && swift test --filter SharedTests 2>&1 | tail -10`
Expected: All tests pass

- [ ] **Step 5: Commit**

```bash
git add Sources/Shared/ Tests/SharedTests/
git commit -m "feat(shared): add BridgeEvent, PermissionResponse, and SessionState types"
```

---

## Task 3: Bridge CLI — Socket Client

**Files:**
- Modify: `Sources/BridgeLib/SocketClient.swift` (replace placeholder)
- Create: `Tests/BridgeLibTests/SocketClientTests.swift`

- [ ] **Step 1: Write tests for SocketClient**

Test `BridgeSocketClient` with two scenarios: (1) `sendFireAndForget` returns false when socket path doesn't exist, (2) `sendAndWaitForResponse` works end-to-end by creating a temporary Unix socket server that echoes data back, then verifying the client receives the response.

`Tests/BridgeLibTests/SocketClientTests.swift` — use a UUID-based temp path `/tmp/zackeyes-test-{uuid}.sock` with `defer { unlink(path) }`. The echo server uses raw POSIX: `socket()`, `bind()`, `listen()`, `accept()`, `read()`, `write()`, `close()` — run it in a `Task.detached` with 50ms sleep before client connects.

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/ysq/Work/lab/ccisland && swift test --filter BridgeLibTests 2>&1 | tail -10`
Expected: FAIL — `BridgeSocketClient` not defined

- [ ] **Step 3: Implement SocketClient**

`Sources/Bridge/SocketClient.swift` — a `Sendable` struct with `init(path:)`. Two public methods:

`sendFireAndForget(data:) -> Bool`: connect, write data, close, return success. If connect fails, return false.

`sendAndWaitForResponse(data:, timeoutSeconds:) -> Data?`: connect, set `SO_RCVTIMEO`, write data, read up to 64KB response, close, return data or nil.

Both methods use private `connect() -> Int32` that creates `AF_UNIX`/`SOCK_STREAM` socket, fills `sockaddr_un`, calls `connect()`, returns fd or -1.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /Users/ysq/Work/lab/ccisland && swift test --filter BridgeLibTests 2>&1 | tail -10`
Expected: All tests pass

- [ ] **Step 5: Commit**

```bash
git add Sources/Bridge/SocketClient.swift Tests/BridgeLibTests/
git commit -m "feat(bridge): add SocketClient for Unix socket communication"
```

---

## Task 4: Bridge CLI — Main Entry Point

**Files:**
- Modify: `Sources/Bridge/main.swift`

- [ ] **Step 1: Implement Bridge main.swift**

Replace placeholder with full implementation. Note: `main.swift` imports `BridgeLib` and `Shared`:
1. Read stdin via `FileHandle.standardInput.availableData` — if empty, `exit(1)`
2. Parse `--event` from `CommandLine.arguments` — if missing, `exit(1)`
3. Parse stdin as JSON dict, inject `_bridge_event` field, re-serialize with trailing `\n`
4. Create `BridgeSocketClient(path: "/tmp/zackeyes.sock")`
5. Switch on eventName:
   - `"PermissionRequest"`: call `sendAndWaitForResponse(timeoutSeconds: 15)`, if nil → `exit(1)`, else write response to stdout → `exit(0)`
   - All others: call `sendFireAndForget`, always `exit(0)` (best-effort)

- [ ] **Step 2: Verify Bridge builds**

Run: `cd /Users/ysq/Work/lab/ccisland && swift build 2>&1 | tail -3`
Expected: `Build complete!`

- [ ] **Step 3: Manual test — Bridge with no socket (should exit 1 for PermissionRequest)**

Run:
```bash
rm -f /tmp/zackeyes.sock
echo '{"hook_event_name":"PermissionRequest","session_id":"test","cwd":"/tmp","tool_name":"Bash","tool_input":{"command":"ls"}}' | \
  .build/debug/bridge --event PermissionRequest
echo "Exit code: $?"
```
Expected: `Exit code: 1`

- [ ] **Step 4: Manual test — fire-and-forget with no socket (should exit 0)**

Run:
```bash
echo '{"hook_event_name":"SessionStart","session_id":"test","cwd":"/tmp"}' | \
  .build/debug/bridge --event SessionStart
echo "Exit code: $?"
```
Expected: `Exit code: 0`

- [ ] **Step 5: Commit**

```bash
git add Sources/Bridge/main.swift
git commit -m "feat(bridge): implement main entry point with stdin parsing and event routing"
```

---

## Task 5: Socket Server

**Files:**
- Create: `Sources/AppLib/Socket/SocketServer.swift`

- [ ] **Step 1: Implement SocketServer**

`Sources/AppLib/Socket/SocketServer.swift` — `@MainActor final class` with:

- `init(path: String = "/tmp/zackeyes.sock")`
- `setEventHandler(_ handler:)` — callback receives `BridgeEvent` + optional responder closure for PermissionRequest
- `start() throws` — unlink stale socket, create `AF_UNIX`/`SOCK_STREAM`, bind, listen(5), launch `Task.detached` for accept loop
- `stop()` — close fd, unlink path
- `acceptLoop()` — loop calling `accept()`, spawn `Task.detached` per connection
- `handleConnection(fd:)` — read up to 64KB, trim trailing newline, decode `BridgeEvent`, dispatch to handler on MainActor.

**CRITICAL — PermissionRequest fd lifecycle:** Do NOT use `defer { close(fd) }` for PermissionRequest connections. The fd must stay open until the user clicks Allow/Deny. Pattern:

```swift
if event.bridgeEvent == "PermissionRequest" {
    // DO NOT close fd here — the responder closure owns it
    let capturedFd = fd
    let responder: @Sendable (PermissionResponse) -> Void = { response in
        guard let data = try? JSONEncoder().encode(response) else {
            close(capturedFd)
            return
        }
        var payload = data
        payload.append(UInt8(ascii: "\n"))
        payload.withUnsafeBytes { ptr in
            _ = write(capturedFd, ptr.baseAddress!, ptr.count)
        }
        close(capturedFd)  // Close AFTER writing response
    }
    await MainActor.run { onEvent?(event, responder) }
    // Keep this task alive while waiting (bridge has 15s timeout)
    // Poll for POLLHUP: if bridge disconnects early, we can clean up
    for _ in 0..<200 { // 20s max
        var pfd = pollfd(fd: fd, events: Int16(POLLHUP), revents: 0)
        if poll(&pfd, 1, 0) > 0 && pfd.revents & Int16(POLLHUP) != 0 { break }
        try? await Task.sleep(for: .milliseconds(100))
    }
} else {
    // Fire-and-forget: dispatch event, close immediately
    await MainActor.run { onEvent?(event, nil) }
    close(fd)
}
```

- [ ] **Step 2: Verify build compiles**

Run: `cd /Users/ysq/Work/lab/ccisland && swift build 2>&1 | tail -3`
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Sources/ZackEyes/Socket/
git commit -m "feat(socket): add SocketServer with Unix domain socket listener"
```

---

## Task 6: Session Store

**Files:**
- Create: `Sources/AppLib/Session/SessionStore.swift`
- Create: `Tests/AppLibTests/SessionStoreTests.swift`

- [ ] **Step 1: Write tests for SessionStore**

Test these state transitions (all `@MainActor`):
- Initial state is `.idle` with nil sessionId, toolName, pendingPermission
- `handleEvent(SessionStart)` sets `.working` + sessionId + cwd
- `handleEvent(PreToolUse)` sets `currentToolName`
- `handlePermissionRequest(pending)` sets `.waiting` + stores pending
- `resolvePermission(allow: true)` calls responder, sets `.working`, clears pending
- `handleEvent(SessionEnd)` resets everything to `.idle`
- `handleEvent(Stop)` sets `.stopped`

Use a `BridgeEvent.mock(event:sessionId:cwd:toolName:)` helper that creates BridgeEvent with the given fields.

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/ysq/Work/lab/ccisland && swift test --filter AppLibTests 2>&1 | tail -10`
Expected: FAIL — `SessionStore`, `PendingPermission` not defined

- [ ] **Step 3: Implement SessionStore**

`Sources/AppLib/Session/SessionStore.swift` — `@MainActor public final class: ObservableObject` with `@Published` properties: `state: SessionState`, `sessionId: String?`, `cwd: String?`, `currentToolName: String?`, `pendingPermission: PendingPermission?`.

`handleEvent(_ event:)` switches on `event.bridgeEvent` for SessionStart/SessionEnd/PreToolUse/PostToolUse/Stop.

`handlePermissionRequest(_ permission:)` sets state to `.waiting` and stores the pending permission.

`resolvePermission(allow: Bool)` creates `PermissionResponse.allow` or `.deny`, calls `pending.responder(response)`, clears pending, returns state to `.working` (if sessionId exists) or `.idle`.

`PendingPermission` struct holds `toolName: String`, `toolInput: [String: Any]`, `cwd: String?`, `responder: @Sendable (PermissionResponse) -> Void`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /Users/ysq/Work/lab/ccisland && swift test --filter AppLibTests 2>&1 | tail -10`
Expected: All tests pass

- [ ] **Step 5: Commit**

```bash
git add Sources/ZackEyes/Session/ Tests/ZackEyesTests/SessionStoreTests.swift
git commit -m "feat(session): add SessionStore with state machine and permission handling"
```

---

## Task 7: Hook Installer

**Files:**
- Create: `Sources/AppLib/Hooks/HookInstaller.swift`
- Create: `Tests/AppLibTests/HookInstallerTests.swift`

- [ ] **Step 1: Write tests for HookInstaller**

Test with temporary directories (UUID-based, with defer cleanup):
- `mergeIntoEmptySettings`: existing `{"permissions":{...},"defaultMode":"default"}` → hooks added, original keys preserved
- `preservesExistingHooks`: existing `{"hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"other-tool"}]}]}}` → should have 2 PreToolUse entries after install
- `createsBackup`: after install, a `settings.json.backup.*` file exists in the dir
- `skipOnParseFailure`: file with "not valid json {{" → install doesn't throw, file unchanged
- `uninstall_removesOnlyOurEntries`: install then uninstall → hooks key removed (was empty)

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/ysq/Work/lab/ccisland && swift test --filter AppLibTests 2>&1 | tail -10`
Expected: FAIL — `HookInstaller` not defined

- [ ] **Step 3: Implement HookInstaller**

`Sources/AppLib/Hooks/HookInstaller.swift` — public struct with `init(settingsPath:, bridgePath:)`.

`hookConfig` computed property: generates dict for all 6 events (PreToolUse, PostToolUse, PermissionRequest, SessionStart, SessionEnd, Stop), each as `[{"hooks":[{"type":"command","command":"$HOME/.zackeyes/bin/bridge --event EventName"}]}]`.

`installHooks()`: check claude dir exists, read settings, parse JSON (skip on failure), backup, remove existing zackeyes entries (idempotent), append new entries per event, write back with `.prettyPrinted` + `.sortedKeys`.

`uninstallHooks()`: read, parse, remove entries where `isZackEyesEntry` matches (command contains "zackeyes"), clean up empty event arrays and hooks key.

`deployLauncherScript(appPath:)`: create `~/.zackeyes/bin/`, write the zsh launcher script, chmod 755, write app path to `~/.zackeyes/.app-path`.

`isZackEyesEntry` helper: checks if any hook in the entry's `hooks` array has a `command` containing "zackeyes".

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /Users/ysq/Work/lab/ccisland && swift test --filter AppLibTests 2>&1 | tail -10`
Expected: All tests pass

- [ ] **Step 5: Commit**

```bash
git add Sources/ZackEyes/Hooks/ Tests/ZackEyesTests/HookInstallerTests.swift
git commit -m "feat(hooks): add HookInstaller with safe merge, backup, and uninstall"
```

---

## Task 8: NotchPanel + Window Controller + Screen Extension

**Files:**
- Create: `Sources/AppLib/Notch/NSScreen+Notch.swift`
- Create: `Sources/AppLib/Notch/NotchPanel.swift`
- Create: `Sources/AppLib/Notch/NotchWindowController.swift`
- Create: `Sources/AppLib/Notch/NotchViewModel.swift` (placeholder)
- Create: `Sources/AppLib/Notch/NotchCompactView.swift` (placeholder with NotchRootView)
- Delete: `Sources/AppLib/Placeholder.swift` (no longer needed)

- [ ] **Step 1: Implement NSScreen+Notch**

Extension on `NSScreen` with three computed properties:
- `hasNotch: Bool` — returns `safeAreaInsets.top > 0`
- `notchSize: CGSize?` — uses `auxiliaryTopLeftArea?.width` + `auxiliaryTopRightArea?.width`, formula: `width = frame.width - left - right + 4`, `height = safeAreaInsets.top`
- `notchFrame: CGRect?` — centers notchSize at top of screen

- [ ] **Step 2: Implement NotchPanel**

NSPanel subclass with: `.borderless` + `.nonactivatingPanel`, level `.screenSaver`, `isFloatingPanel = true`, `becomesKeyOnlyIfNeeded = true`, transparent background, `hasShadow = false`, `isMovable = false`, `ignoresMouseEvents = true`, collectionBehavior `[.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]`. Override `canBecomeKey` → true, `canBecomeMain` → false.

- [ ] **Step 3: Implement NotchWindowController**

`@MainActor class` with `PanelState` enum (collapsed/compact/expanded).

`setup()`: create panel, observe screen changes, observe mouse movement.

`createPanel()`: guard screen has notch, create `NotchPanel(contentRect: notchFrame)`, host `NotchRootView` via `NSHostingView`, order front.

`updatePanelState(_:)`: switch on state — collapsed restores to notchFrame with `ignoresMouseEvents = true`, compact expands to 320px pill with `ignoresMouseEvents = true`, expanded drops to 380x280 panel with `ignoresMouseEvents = false`. Uses `NSAnimationContext` for 0.2s ease-in-out animation.

`forceExpand()`: sets state to expanded (called when PermissionRequest arrives).

Mouse tracking via `NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved)` with proximity-based state transitions and 300ms delayed collapse from expanded.

Screen change observer on `NSApplication.didChangeScreenParametersNotification` — recreates panel.

- [ ] **Step 4: Create placeholder NotchViewModel and NotchRootView**

`NotchViewModel`: `@MainActor ObservableObject` with `sessionStore: SessionStore` and `@Published panelState`.

`NotchRootView` (in NotchCompactView.swift): switches on `viewModel.panelState` to show CollapsedDot, NotchCompactView, or NotchExpandedView (placeholder Text for now).

- [ ] **Step 5: Verify build compiles**

Run: `cd /Users/ysq/Work/lab/ccisland && swift build 2>&1 | tail -3`
Expected: `Build complete!`

- [ ] **Step 6: Commit**

```bash
git add Sources/ZackEyes/Notch/
git commit -m "feat(notch): add NotchPanel, WindowController, screen geometry, and view placeholders"
```

---

## Task 9: Notch SwiftUI Views

**Files:**
- Modify: `Sources/AppLib/Notch/NotchViewModel.swift`
- Modify: `Sources/AppLib/Notch/NotchCompactView.swift`
- Create: `Sources/AppLib/Notch/NotchExpandedView.swift`

- [ ] **Step 1: Implement full NotchViewModel**

Add computed properties: `statusColor` (green for working, orange for waiting, gray for idle/stopped), `statusText` ("working"/"awaiting approval"/"idle"/"stopped"), `toolBadge` (currentToolName from sessionStore).

Add methods: `approve()` calls `sessionStore.resolvePermission(allow: true)`, `deny()` calls `sessionStore.resolvePermission(allow: false)`.

- [ ] **Step 2: Implement NotchCompactView + NotchRootView**

`NotchRootView` switches on `viewModel.panelState`: collapsed shows 8px gray dot, compact shows `NotchCompactView`, expanded shows `NotchExpandedView`.

`NotchCompactView`: HStack with status dot (8px circle, color-coded with shadow), "Claude Code" label, "·" separator, status text in status color, optional tool badge (small rounded rect).

Black background, rounded rectangle clip shape, horizontal padding 16.

- [ ] **Step 3: Implement NotchExpandedView**

VStack with:
- Header row: status dot + "Claude Code" + Spacer + status badge
- CWD line (monospaced, gray)
- If `pendingPermission` exists: permission detail section with "PERMISSION REQUEST" label, tool name in orange, command preview in monospaced font on dark background (lineLimit 3), then three buttons in HStack: "Deny" (red), "Allow Once" (teal), "Always" (stronger teal)

All buttons use `.buttonStyle(.plain)` and call viewModel.deny() or viewModel.approve().

16px padding, black background, rounded rectangle clip.

- [ ] **Step 4: Verify build compiles**

Run: `cd /Users/ysq/Work/lab/ccisland && swift build 2>&1 | tail -3`
Expected: `Build complete!`

- [ ] **Step 5: Commit**

```bash
git add Sources/ZackEyes/Notch/
git commit -m "feat(notch): implement compact and expanded SwiftUI views with permission approval UI"
```

---

## Task 10: Menu Bar Fallback

**Files:**
- Create: `Sources/AppLib/MenuBar/MenuBarFallback.swift`

- [ ] **Step 1: Implement MenuBarFallback**

`@MainActor class MenuBarFallback: NSObject` (must inherit from NSObject for `@objc` selector support) with `NSStatusItem`, `NSPopover`, and `NotchViewModel`.

`setup()`: create status item with variable length, set button title to eye icon, set action to `togglePopover`. Create NSPopover with `contentSize: 360x260`, `.transient` behavior, hosting `NotchExpandedView` wrapped in padding + black background.

`teardown()`: remove status item.

`togglePopover()`: show/close popover relative to status item button.

- [ ] **Step 2: Verify build compiles**

Run: `cd /Users/ysq/Work/lab/ccisland && swift build 2>&1 | tail -3`
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Sources/ZackEyes/MenuBar/
git commit -m "feat(menubar): add NSStatusItem + NSPopover fallback for notchless Macs"
```

---

## Task 11: App Delegate + Wiring

**Files:**
- Create: `Sources/ZackEyes/AppDelegate.swift`
- Modify: `Sources/ZackEyes/main.swift`

- [ ] **Step 1: Implement AppDelegate**

`Sources/ZackEyes/AppDelegate.swift` — imports `AppLib` and `Shared`. `@MainActor class AppDelegate: NSObject, NSApplicationDelegate` with properties for `SocketServer`, `SessionStore`, `NotchViewModel`, `NotchWindowController?`, `MenuBarFallback?`.

`applicationDidFinishLaunching`:
1. Create SessionStore
2. Create NotchViewModel(sessionStore:)
3. Create SocketServer, set event handler, start()
4. If screen has notch → create NotchWindowController, setup(). Else → create MenuBarFallback, setup()
5. Task: install hooks + deploy launcher script (best-effort, log errors)

Event handler routes: PermissionRequest → create PendingPermission from event fields, call `sessionStore.handlePermissionRequest()`, call `windowController?.forceExpand()`. Other events → `sessionStore.handleEvent()`, auto-show compact on SessionStart, collapse on SessionEnd/Stop.

`applicationWillTerminate`: stop socket server, teardown UI.

- [ ] **Step 2: Update main.swift**

`Sources/ZackEyes/main.swift`:
```swift
import AppKit
import AppLib

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
```

- [ ] **Step 3: Verify full build + app bundle**

Run: `cd /Users/ysq/Work/lab/ccisland && make app 2>&1`
Expected: `Built .build/ZackEyes.app`

- [ ] **Step 4: Verify app launches and creates socket**

Run:
```bash
open .build/ZackEyes.app
sleep 2
ls -la /tmp/zackeyes.sock
```
Expected: socket file exists

Run: `pkill -f ZackEyes` to stop the app.

- [ ] **Step 5: Commit**

```bash
git add Sources/ZackEyes/App/
git commit -m "feat(app): wire AppDelegate with SocketServer, SessionStore, NotchPanel, and HookInstaller"
```

---

## Task 12: End-to-End Verification

**Files:** None (manual testing)

- [ ] **Step 1: Build and launch the app**

```bash
cd /Users/ysq/Work/lab/ccisland
make app
open .build/ZackEyes.app
sleep 2
```

Verify: `/tmp/zackeyes.sock` exists.

- [ ] **Step 2: Test fire-and-forget event (SessionStart)**

```bash
echo '{"hook_event_name":"SessionStart","session_id":"e2e-test","cwd":"/Users/ysq/Work/lab/ccisland"}' | \
  .build/debug/bridge --event SessionStart
echo "Exit: $?"
```

Expected: Exit 0. The notch panel should transition from collapsed to compact showing "Claude Code - working".

- [ ] **Step 3: Test PreToolUse event**

```bash
echo '{"hook_event_name":"PreToolUse","session_id":"e2e-test","cwd":"/tmp","tool_name":"Bash","tool_input":{"command":"ls -la"}}' | \
  .build/debug/bridge --event PreToolUse
```

Expected: Exit 0. Compact view should show "Bash" tool badge.

- [ ] **Step 4: Test PermissionRequest (the critical path)**

```bash
echo '{"hook_event_name":"PermissionRequest","session_id":"e2e-test","cwd":"/tmp","tool_name":"Bash","tool_input":{"command":"rm -rf /tmp/test-output"},"permission_mode":"default"}' | \
  timeout 20 .build/debug/bridge --event PermissionRequest
```

Expected: Notch panel expands showing permission request UI with "Bash" and the command. Click "Allow Once" in the notch. Bridge should output JSON to stdout and exit 0.

- [ ] **Step 5: Test SessionEnd**

```bash
echo '{"hook_event_name":"SessionEnd","session_id":"e2e-test","cwd":"/tmp"}' | \
  .build/debug/bridge --event SessionEnd
```

Expected: Notch collapses back to collapsed state.

- [ ] **Step 6: Run full test suite**

```bash
cd /Users/ysq/Work/lab/ccisland && swift test 2>&1 | tail -20
```

Expected: All tests pass.

- [ ] **Step 7: Final commit**

```bash
pkill -f ZackEyes
git add -A
git commit -m "test: verify end-to-end flow with bridge, socket, and notch panel"
```

---

## Summary

| Task | Component | Commits |
|------|-----------|---------|
| 1 | Project Scaffolding | `chore: scaffold project` |
| 2 | Event Protocol | `feat(shared): add types` |
| 3 | Bridge Socket Client | `feat(bridge): add SocketClient` |
| 4 | Bridge Main | `feat(bridge): implement main` |
| 5 | Socket Server | `feat(socket): add SocketServer` |
| 6 | Session Store | `feat(session): add SessionStore` |
| 7 | Hook Installer | `feat(hooks): add HookInstaller` |
| 8 | NotchPanel + Controller | `feat(notch): add NotchPanel` |
| 9 | Notch Views | `feat(notch): implement views` |
| 10 | Menu Bar Fallback | `feat(menubar): add fallback` |
| 11 | App Wiring | `feat(app): wire everything` |
| 12 | E2E Verification | `test: verify E2E` |
