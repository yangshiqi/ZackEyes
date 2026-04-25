# AskUserQuestion Click-to-Answer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user answer Claude Code's `AskUserQuestion` tool by tapping options in the ZackEyes notch — CC consumes the answer through the PreToolUse hook's `updatedInput.answers` channel and never renders its terminal UI.

**Architecture:** Bridge intercepts `PreToolUse + tool_name == "AskUserQuestion"` and blocks on the existing socket pattern (same as `PermissionRequest`). User taps in the notch → app sends a `PreToolUseHookResponse` carrying `answers` → bridge writes it to stdout → CC consumes. No click in 60s → bridge fallback → CC renders its own terminal UI.

**Tech Stack:** Swift 6 strict concurrency, SPM, Foundation/AppKit/SwiftUI, Unix Domain Socket, no third-party deps.

**Spec:** [docs/superpowers/specs/2026-04-25-askuq-click-to-answer-design.md](../specs/2026-04-25-askuq-click-to-answer-design.md)

---

## File Map

**Modified:**
- `Sources/Shared/EventProtocol.swift` — add `PreToolUseHookResponse` struct + `BridgeResponse` enum
- `Sources/BridgeLib/SocketClient.swift` — replace blocking `read()` with `poll()` so peer disconnect (POLLHUP) returns nil immediately
- `Sources/Bridge/main.swift` — new branch for `PreToolUse + AskUQ`
- `Sources/AppLib/Socket/SocketServer.swift` — generalize blocking predicate; auto-allow PermissionRequest+AskUQ
- `Sources/AppLib/Session/SessionStore.swift` — `responder` type to `(BridgeResponse) -> Void`; new `submitAskUQAnswer` API
- `Sources/AppLib/Notch/NotchViewModel.swift` — passthrough `submitAskUQAnswer`
- `Sources/AppLib/Notch/NotchExpandedView.swift` — clickable options + multi-select checkboxes + Submit
- `CHANGELOG.md` — entry under next minor version
- `ARCHITECTURE.md` — note PreToolUse blocking branch in data-flow section

**Test files modified:**
- `Tests/SharedTests/EventProtocolTests.swift`
- `Tests/BridgeLibTests/SocketClientTests.swift`
- `Tests/AppLibTests/SessionStoreTests.swift`

**No file structural changes** (no new files, no renames). All edits land in the files where the existing responsibilities already live.

---

## Task 1: Spike #2A — Verify fallback JSON shape

**Files:** none (manual verification using `/tmp/askuq-spike.py` from prior spike)

**Goal:** Decide whether the 60s soft-timeout fallback should write a literal `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}` or simply emit empty stdout.

- [ ] **Step 1: Restart the spike harness for "fallback" mode**

Edit `/tmp/askuq-spike.py` to add a new variant `"f-empty"` that does nothing on AskUQ (no stdout):

```python
elif variant == "f-empty":
    # Test (b): empty stdout fallback
    log("AskUQ fallback mode: empty stdout")
    return
```

And another `"f-allow"` for variant (a):

```python
elif variant == "f-allow":
    # Test (a): allow without updatedInput
    response = {
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "allow"
        }
    }
    response_str = json.dumps(response)
    with open(OUTPUT_FILE, "w") as f:
        f.write(response_str)
    sys.stdout.write(response_str)
    sys.stdout.flush()
    return
```

- [ ] **Step 2: Reinstall spike-only PreToolUse**

```fish
cp ~/.claude/settings.json ~/.claude/settings.json.spike-backup
python3 -c '
import json, pathlib
p = pathlib.Path.home() / ".claude/settings.json"
s = json.loads(p.read_text())
s.setdefault("hooks", {})
s["hooks"]["PreToolUse"] = [{
    "hooks": [{"type": "command", "command": "/tmp/askuq-spike.py", "timeout": 60}]
}]
p.write_text(json.dumps(s, indent=2, sort_keys=True))
'
```

Quit ZackEyes if running.

- [ ] **Step 3: Test (a) — `f-allow`**

```fish
echo f-allow > /tmp/askuq-spike.variant
rm -f /tmp/askuq-spike.in.json /tmp/askuq-spike.out.json /tmp/askuq-spike.log
```

Open a fresh `claude` terminal session, prompt: `Use the AskUserQuestion tool to ask me a single question with header "color" and three options: red, blue, green.`

Observe and record:
- Did the terminal AskUQ UI render? (expected: yes)
- Did Claude Code report a hook error? (expected: no)
- Did you successfully answer in the terminal? (expected: yes)

- [ ] **Step 4: Test (b) — `f-empty`**

```fish
echo f-empty > /tmp/askuq-spike.variant
rm -f /tmp/askuq-spike.in.json /tmp/askuq-spike.out.json /tmp/askuq-spike.log
```

Same prompt in a fresh terminal session. Record same three observations.

- [ ] **Step 5: Pick the winning shape**

Decision criteria:
- Both work cleanly → pick `f-empty` (less code, matches existing `Bridge/main.swift` PermissionRequest fail path)
- Only one works → pick that one
- Neither works → STOP. Re-evaluate the design.

Write the decision (and the literal stdout to use, if any) into a comment at the top of `/tmp/askuq-spike-decision.txt`. This file feeds Task 6.

- [ ] **Step 6: Commit nothing yet**

This is verification only — no repo changes. Move to Task 2.

---

## Task 2: Spike #2B — Verify multi-hook coexistence

**Files:** none

**Goal:** Decide whether ZackEyes can install alongside Vibe Island's existing PreToolUse hook without our `updatedInput.answers` getting overridden or causing CC errors.

- [ ] **Step 1: Restore the original 3-hook PreToolUse and add the spike**

```fish
mv ~/.claude/settings.json.spike-backup ~/.claude/settings.json
python3 -c '
import json, pathlib
p = pathlib.Path.home() / ".claude/settings.json"
s = json.loads(p.read_text())
existing = s["hooks"]["PreToolUse"]
existing.append({
    "hooks": [{"type": "command", "command": "/tmp/askuq-spike.py", "timeout": 60}]
})
s["hooks"]["PreToolUse"] = existing
p.write_text(json.dumps(s, indent=2, sort_keys=True))
print("PreToolUse now has", len(existing), "entries")
'
```

Verify with: `python3 -c "import json,pathlib; print(json.dumps(json.loads((pathlib.Path.home()/'.claude/settings.json').read_text())['hooks']['PreToolUse'], indent=2))"`

- [ ] **Step 2: Set spike to variant 1 (single-select working answer)**

```fish
echo 1 > /tmp/askuq-spike.variant
rm -f /tmp/askuq-spike.in.json /tmp/askuq-spike.out.json /tmp/askuq-spike.log
```

- [ ] **Step 3: Trigger AskUQ in a fresh terminal session**

```
Use the AskUserQuestion tool to ask me a single question with header "color" and three options: red, blue, green.
```

- [ ] **Step 4: Observe and record**

Specifically:
- Does CC return the spike's pre-canned answer (`"red"`) or something else?
- Does CC render the terminal AskUQ UI? (expected: no, our spike beat the others)
- Any hook errors visible in the terminal?
- Check `/tmp/askuq-spike.log` — confirm spike was invoked
- Check Vibe Island's logs (`~/.vibe-island/`) — see if it also handled it

- [ ] **Step 5: Document the outcome**

In `/tmp/askuq-spike-decision.txt`, append the multi-hook conclusion: ✅ ZackEyes wins / ⚠️ conflict observed / ❌ CC errors out. If conflict, decide on a `HookInstaller` mitigation (warn user / refuse install / install anyway).

- [ ] **Step 6: Restore environment**

```fish
mv ~/.claude/settings.json.spike-backup ~/.claude/settings.json 2>/dev/null || true
# Restore by removing spike entry only
python3 -c '
import json, pathlib
p = pathlib.Path.home() / ".claude/settings.json"
s = json.loads(p.read_text())
s["hooks"]["PreToolUse"] = [
    e for e in s["hooks"]["PreToolUse"]
    if "askuq-spike.py" not in str(e)
]
p.write_text(json.dumps(s, indent=2, sort_keys=True))
'
```

Relaunch ZackEyes. Move to Task 3.

---

## Task 3: Add `PreToolUseHookResponse` and `BridgeResponse` to Shared

**Files:**
- Modify: `Sources/Shared/EventProtocol.swift` (append new types after `PermissionResponse`)
- Test: `Tests/SharedTests/EventProtocolTests.swift` (append new tests)

- [ ] **Step 1: Write the failing tests for `PreToolUseHookResponse`**

Append to `Tests/SharedTests/EventProtocolTests.swift`:

```swift
@Test func encodePreToolUseHookResponse_askUQAnswers() throws {
    let questions: [[String: Any]] = [[
        "question": "Pick a color",
        "header": "color",
        "multiSelect": false,
        "options": [
            ["label": "red", "description": "warm"],
            ["label": "blue", "description": "cool"],
        ],
    ]]
    let answers = ["Pick a color": "red"]
    let response = PreToolUseHookResponse.askUQAnswers(
        questions: questions, answers: answers
    )
    let data = try JSONEncoder().encode(response)
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    let hookOutput = json["hookSpecificOutput"] as! [String: Any]
    #expect(hookOutput["hookEventName"] as? String == "PreToolUse")
    #expect(hookOutput["permissionDecision"] as? String == "allow")
    let updated = hookOutput["updatedInput"] as! [String: Any]
    let returnedAnswers = updated["answers"] as! [String: String]
    #expect(returnedAnswers["Pick a color"] == "red")
}

@Test func bridgeResponse_encodesPermissionVariant() throws {
    let r: BridgeResponse = .permission(.allow(message: "ok"))
    let data = try r.encoded()
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    let hookOutput = json["hookSpecificOutput"] as! [String: Any]
    #expect(hookOutput["hookEventName"] as? String == "PermissionRequest")
}

@Test func bridgeResponse_encodesPreToolUseVariant() throws {
    let r: BridgeResponse = .preToolUse(
        .askUQAnswers(questions: [], answers: ["q": "a"])
    )
    let data = try r.encoded()
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    let hookOutput = json["hookSpecificOutput"] as! [String: Any]
    #expect(hookOutput["hookEventName"] as? String == "PreToolUse")
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
swift test --filter SharedTests 2>&1 | tail -20
```

Expected: compilation errors — `PreToolUseHookResponse` and `BridgeResponse` undefined.

- [ ] **Step 3: Implement `PreToolUseHookResponse` and `BridgeResponse`**

Append to `Sources/Shared/EventProtocol.swift` (after the existing `PermissionResponse`):

```swift
// MARK: - PreToolUseHookResponse

/// Response sent to Claude Code from a PreToolUse hook to either auto-allow
/// (with optional `updatedInput`) or auto-answer an `AskUserQuestion` tool
/// call by populating `updatedInput.answers`. CC consumes `answers` directly
/// and skips its own terminal UI for AskUserQuestion when this is set.
public struct PreToolUseHookResponse: Codable, Sendable {
    public let hookSpecificOutput: HookSpecificOutput

    public struct HookSpecificOutput: Codable, Sendable {
        public let hookEventName: String  // always "PreToolUse"
        public let permissionDecision: String  // "allow"
        public let updatedInput: [String: AnyCodable]?

        public init(updatedInput: [String: AnyCodable]? = nil) {
            self.hookEventName = "PreToolUse"
            self.permissionDecision = "allow"
            self.updatedInput = updatedInput
        }
    }

    /// Build a response that auto-answers AskUserQuestion. CC keys `answers`
    /// by the exact `question` text (verified in spike 2026-04-25); values
    /// are single strings (multi-select uses comma-joined labels).
    public static func askUQAnswers(
        questions: [[String: Any]],
        answers: [String: String]
    ) -> PreToolUseHookResponse {
        return PreToolUseHookResponse(
            hookSpecificOutput: HookSpecificOutput(
                updatedInput: [
                    "questions": AnyCodable(questions),
                    "answers": AnyCodable(answers),
                ]
            )
        )
    }
}

// MARK: - BridgeResponse

/// Sum type for any response the app sends back to a blocking bridge call.
/// `PermissionRequest` and `PreToolUse + AskUserQuestion` use structurally
/// different JSON shapes; this enum keeps them straight at the call sites.
public enum BridgeResponse: Sendable {
    case permission(PermissionResponse)
    case preToolUse(PreToolUseHookResponse)

    public func encoded() throws -> Data {
        switch self {
        case .permission(let r): return try JSONEncoder().encode(r)
        case .preToolUse(let r): return try JSONEncoder().encode(r)
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
swift test --filter SharedTests 2>&1 | tail -10
```

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/Shared/EventProtocol.swift Tests/SharedTests/EventProtocolTests.swift
git commit -m "$(cat <<'EOF'
feat(shared): add PreToolUseHookResponse and BridgeResponse enum

Two response shapes for blocking bridge calls. PermissionRequest stays
unchanged; PreToolUse + AskUserQuestion gets a dedicated encoder that
populates updatedInput.questions and updatedInput.answers per the
spike-verified format.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Add POLLHUP detection to `SocketClient`

**Files:**
- Modify: `Sources/BridgeLib/SocketClient.swift` (rewrite the read portion of `sendAndWaitForResponse`)
- Test: `Tests/BridgeLibTests/SocketClientTests.swift` (add a peer-close test)

- [ ] **Step 1: Write the failing test**

Append to `Tests/BridgeLibTests/SocketClientTests.swift`:

```swift
@Test("sendAndWaitForResponse returns nil promptly when peer closes without writing")
func socketClient_pollHUPDetectsPeerClose() async throws {
    let path = "/tmp/zackeyes-test-\(UUID().uuidString).sock"
    defer { unlink(path) }

    let serverFd = socket(AF_UNIX, SOCK_STREAM, 0)
    #expect(serverFd >= 0)
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
        ptr.withMemoryRebound(to: CChar.self, capacity: 108) { buf in
            _ = path.withCString { strncpy(buf, $0, 107) }
        }
    }
    let bindResult = withUnsafePointer(to: &addr) { addrPtr in
        addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            bind(serverFd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    #expect(bindResult == 0)
    #expect(listen(serverFd, 1) == 0)

    // Server accepts then immediately closes — no write.
    Task.detached {
        let clientFd = accept(serverFd, nil, nil)
        if clientFd >= 0 { close(clientFd) }
        close(serverFd)
    }
    try await Task.sleep(nanoseconds: 50_000_000)

    let client = BridgeSocketClient(path: path)
    let start = Date()
    let result = client.sendAndWaitForResponse(
        data: Data("ping\n".utf8), timeoutSeconds: 30
    )
    let elapsed = Date().timeIntervalSince(start)

    #expect(result == nil, "Expected nil on peer-close")
    #expect(elapsed < 1.0, "Expected fast return (<1s) but took \(elapsed)s")
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
swift test --filter BridgeLibTests/socketClient_pollHUPDetectsPeerClose 2>&1 | tail -10
```

Expected: FAIL — without POLLHUP detection, `read()` blocks until the 30s `SO_RCVTIMEO`.

- [ ] **Step 3: Replace the read portion of `sendAndWaitForResponse`**

In `Sources/BridgeLib/SocketClient.swift`, replace the body of `sendAndWaitForResponse` from the comment about `// Skip the SO_RCVTIMEO option …` through the final `return Data(buffer[0..<n])` with:

```swift
        // Write all data
        var totalWritten = 0
        let count = data.count
        let sendOK: Bool = data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) -> Bool in
            guard let base = buf.baseAddress else { return false }
            while totalWritten < count {
                let n = write(fd, base.advanced(by: totalWritten), count - totalWritten)
                if n <= 0 { return false }
                totalWritten += n
            }
            return true
        }
        guard sendOK else { return nil }

        // Wait for either a response or peer disconnect (POLLHUP).
        // poll() takes milliseconds; -1 means wait forever. Even though we
        // only request POLLIN, the kernel always reports POLLHUP/POLLERR/
        // POLLNVAL in revents when relevant — that's how peer-close wakes
        // us up early instead of stalling on the SO_RCVTIMEO budget.
        let pollTimeoutMs: Int32 = timeoutSeconds > 0 ? Int32(timeoutSeconds * 1000) : -1
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let pollResult = poll(&pfd, 1, pollTimeoutMs)
        guard pollResult > 0 else { return nil }  // 0 = timeout, <0 = error
        guard (pfd.revents & Int16(POLLIN)) != 0 else { return nil }  // peer closed without data

        var buffer = [UInt8](repeating: 0, count: 65536)
        let n = read(fd, &buffer, buffer.count)
        return n > 0 ? Data(buffer[0..<n]) : nil
```

Also delete the `if timeoutSeconds > 0 { ... setsockopt SO_RCVTIMEO ... }` block above (now redundant — `poll()` owns the timeout).

The full replaced method should look like:

```swift
public func sendAndWaitForResponse(data: Data, timeoutSeconds: Int) -> Data? {
    let fd = connect()
    guard fd >= 0 else { return nil }
    defer { close(fd) }

    // Write all data
    var totalWritten = 0
    let count = data.count
    let sendOK: Bool = data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) -> Bool in
        guard let base = buf.baseAddress else { return false }
        while totalWritten < count {
            let n = write(fd, base.advanced(by: totalWritten), count - totalWritten)
            if n <= 0 { return false }
            totalWritten += n
        }
        return true
    }
    guard sendOK else { return nil }

    // Wait for either a response or peer disconnect (POLLHUP).
    // poll() takes milliseconds; -1 means wait forever. Even though we
    // only request POLLIN, the kernel always reports POLLHUP/POLLERR/
    // POLLNVAL in revents when relevant — that's how peer-close wakes
    // us up early instead of stalling on the SO_RCVTIMEO budget.
    let pollTimeoutMs: Int32 = timeoutSeconds > 0 ? Int32(timeoutSeconds * 1000) : -1
    var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
    let pollResult = poll(&pfd, 1, pollTimeoutMs)
    guard pollResult > 0 else { return nil }
    guard (pfd.revents & Int16(POLLIN)) != 0 else { return nil }

    var buffer = [UInt8](repeating: 0, count: 65536)
    let n = read(fd, &buffer, buffer.count)
    return n > 0 ? Data(buffer[0..<n]) : nil
}
```

- [ ] **Step 4: Run tests**

```bash
swift test --filter BridgeLibTests 2>&1 | tail -15
```

Expected: all 3 tests pass (existing 2 + new POLLHUP test).

- [ ] **Step 5: Commit**

```bash
git add Sources/BridgeLib/SocketClient.swift Tests/BridgeLibTests/SocketClientTests.swift
git commit -m "$(cat <<'EOF'
feat(bridge): SocketClient detects peer disconnect via poll()

Replaces blocking read() + SO_RCVTIMEO with a poll() that wakes up
on either POLLIN or POLLHUP. App crashing mid-prompt no longer makes
the bridge stall for the full timeout — fallback to terminal UI is
near-instant.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Bridge CLI — handle `PreToolUse + AskUserQuestion`

**Files:**
- Modify: `Sources/Bridge/main.swift` (insert new case before `default:`)

This task has no unit test (the CLI binary is a thin wrapper); it'll be exercised by the manual integration in Task 12.

- [ ] **Step 1: Insert the new case**

Open `Sources/Bridge/main.swift`. Find the `switch eventName` block. Between `case "StatusLine":` and `default:`, insert:

```swift
case "PreToolUse":
    // Only AskUserQuestion blocks. Everything else stays fire-and-forget
    // so we don't slow down the hot path of every tool call.
    if jsonObject["tool_name"] as? String == "AskUserQuestion" {
        // 60-second internal soft timeout. CC's hook timeout is 600s
        // by default — well above ours, so we always exit before CC
        // kills us. On socket failure / POLLHUP / soft timeout, fall
        // through to CC's own terminal AskUQ UI.
        guard let responseData = client.sendAndWaitForResponse(
            data: payloadData, timeoutSeconds: 60
        ) else {
            // Spike #2A decision: <PASTE FROM /tmp/askuq-spike-decision.txt>
            // If "f-empty": exit 0 with no stdout (matches PermissionRequest fail path)
            // If "f-allow": write the literal JSON before exit
            exit(0)
        }
        FileHandle.standardOutput.write(responseData)
        exit(0)
    }
    _ = client.sendFireAndForget(data: payloadData)
    exit(0)
```

- [ ] **Step 2: Apply the Spike #2A decision**

Read `/tmp/askuq-spike-decision.txt` (created in Task 1). Replace the placeholder block based on the recorded decision:

**If `f-empty` won:** the `exit(0)` line stays as-is. Remove the placeholder comment line.

**If `f-allow` won:** replace the `exit(0)` line with:

```swift
            let fallbackJSON = """
                {"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}
                """
            FileHandle.standardOutput.write(Data(fallbackJSON.utf8))
            exit(0)
```

- [ ] **Step 3: Build to verify it compiles**

```bash
swift build 2>&1 | tail -10
```

Expected: build succeeds (both `bridge` and `ZackEyes` targets).

- [ ] **Step 4: Smoke-test the fire-and-forget path is unchanged**

```bash
echo '{"hook_event_name":"PreToolUse","session_id":"smoke","tool_name":"Bash","tool_input":{"command":"ls"}}' | $(swift build --show-bin-path)/bridge --event PreToolUse
```

Expected: empty stdout, exit 0 (socket isn't there → silent fail). Verify with `echo $?`.

- [ ] **Step 5: Commit**

```bash
git add Sources/Bridge/main.swift
git commit -m "$(cat <<'EOF'
feat(bridge): block on PreToolUse for AskUserQuestion only

Routes AskUQ through sendAndWaitForResponse with a 60s soft timeout.
Other PreToolUse calls remain fire-and-forget. Soft-timeout fallback
shape decided by spike #2A.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: SocketServer — generalize blocking predicate

**Files:**
- Modify: `Sources/AppLib/Socket/SocketServer.swift`
- Modify: `Sources/Shared/EventProtocol.swift` (add `requiresBlockingResponse` extension)

- [ ] **Step 1: Add the extension to BridgeEvent**

At the bottom of `Sources/Shared/EventProtocol.swift`, append:

```swift
// MARK: - BridgeEvent helpers

extension BridgeEvent {
    /// True when this event needs the bridge to wait for an app-side response
    /// (the connection stays open instead of fire-and-forget).
    public var requiresBlockingResponse: Bool {
        if bridgeEvent == "PermissionRequest" { return true }
        if bridgeEvent == "PreToolUse" && toolName == "AskUserQuestion" {
            return true
        }
        return false
    }
}
```

- [ ] **Step 2: Replace the `PermissionRequest` predicate in SocketServer**

In `Sources/AppLib/Socket/SocketServer.swift`, find:

```swift
        if event.bridgeEvent == "PermissionRequest" {
```

Replace with:

```swift
        if event.requiresBlockingResponse {
```

- [ ] **Step 3: Update the responder type to `BridgeResponse`**

In `SocketServer.swift`, change the `setEventHandler` signature from:

```swift
public func setEventHandler(
    _ handler: @escaping @MainActor (BridgeEvent, (@Sendable (PermissionResponse) -> Void)?) -> Void
) {
```

to:

```swift
public func setEventHandler(
    _ handler: @escaping @MainActor (BridgeEvent, (@Sendable (BridgeResponse) -> Void)?) -> Void
) {
```

Also update the stored property `onEvent` to match:

```swift
private var onEvent: ((BridgeEvent, (@Sendable (BridgeResponse) -> Void)?) -> Void)?
```

And update the responder closure inside `handleConnection` from:

```swift
let responder: @Sendable (PermissionResponse) -> Void = { response in
    defer { tracker.completed = true }
    guard let responseData = try? JSONEncoder().encode(response) else {
        close(capturedFd)
        return
    }
```

to:

```swift
let responder: @Sendable (BridgeResponse) -> Void = { response in
    defer { tracker.completed = true }
    guard let responseData = try? response.encoded() else {
        close(capturedFd)
        return
    }
```

- [ ] **Step 4: Build to surface call-site fallout**

```bash
swift build 2>&1 | tail -30
```

Expected errors: `SessionStore.resolvePermission` calls `pending.responder(response)` with a `PermissionResponse`, no longer matches. Will be fixed in Task 7. Note the errors and proceed.

- [ ] **Step 5: Add a SharedTests test for `requiresBlockingResponse`**

Append to `Tests/SharedTests/EventProtocolTests.swift`:

```swift
@Test func requiresBlockingResponse_matrix() {
    let perm = BridgeEvent(bridgeEvent: "PermissionRequest", toolName: "Bash")
    let askUQ = BridgeEvent(bridgeEvent: "PreToolUse", toolName: "AskUserQuestion")
    let preBash = BridgeEvent(bridgeEvent: "PreToolUse", toolName: "Bash")
    let post = BridgeEvent(bridgeEvent: "PostToolUse", toolName: "AskUserQuestion")
    let start = BridgeEvent(bridgeEvent: "SessionStart")
    #expect(perm.requiresBlockingResponse == true)
    #expect(askUQ.requiresBlockingResponse == true)
    #expect(preBash.requiresBlockingResponse == false)
    #expect(post.requiresBlockingResponse == false)
    #expect(start.requiresBlockingResponse == false)
}
```

- [ ] **Step 6: Run SharedTests (build will still fail at app layer; only run Shared)**

```bash
swift test --filter SharedTests 2>&1 | tail -10
```

Expected: SharedTests pass; AppLib still won't compile (Task 7 fixes that).

- [ ] **Step 7: Commit (intermediate — does not yet build app target)**

```bash
git add Sources/Shared/EventProtocol.swift Sources/AppLib/Socket/SocketServer.swift Tests/SharedTests/EventProtocolTests.swift
git commit -m "$(cat <<'EOF'
refactor(socket): generalize blocking predicate to BridgeResponse

BridgeEvent.requiresBlockingResponse covers both PermissionRequest
and PreToolUse+AskUserQuestion. SocketServer's responder closure now
takes BridgeResponse. SessionStore call-site update lands in the
next commit.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: SessionStore — `BridgeResponse` responder + `submitAskUQAnswer`

**Files:**
- Modify: `Sources/AppLib/Session/SessionStore.swift`
- Test: `Tests/AppLibTests/SessionStoreTests.swift`

- [ ] **Step 1: Update `PendingPermission.responder` and `bridgeEventOrigin`**

In `Sources/AppLib/Session/SessionStore.swift`, find the `PendingPermission` struct (around line 440) and change:

```swift
public let responder: @Sendable (PermissionResponse) -> Void

public init(
    toolName: String,
    toolInput: [String: Any],
    cwd: String?,
    responder: @escaping @Sendable (PermissionResponse) -> Void
) {
```

to:

```swift
public let bridgeEventOrigin: String  // "PermissionRequest" | "PreToolUse"
public let responder: @Sendable (BridgeResponse) -> Void

public init(
    toolName: String,
    toolInput: [String: Any],
    cwd: String?,
    bridgeEventOrigin: String,
    responder: @escaping @Sendable (BridgeResponse) -> Void
) {
    self.bridgeEventOrigin = bridgeEventOrigin
```

(Insert `self.bridgeEventOrigin = bridgeEventOrigin` first in the init body, then the existing field assignments.)

- [ ] **Step 2: Update `resolvePermission` to wrap in `.permission(...)`**

Find `resolvePermission` (around line 254). Change:

```swift
let response: PermissionResponse = allow
    ? .allow(message: "User approved via ZackEyes")
    : .deny(message: "User denied via ZackEyes")
pending.responder(response)
```

to:

```swift
let response: PermissionResponse = allow
    ? .allow(message: "User approved via ZackEyes")
    : .deny(message: "User denied via ZackEyes")
pending.responder(.permission(response))
```

- [ ] **Step 3: Add `submitAskUQAnswer`**

Append to `SessionStore` (next to `resolvePermission`):

```swift
/// Send AskUserQuestion answers back through the blocking PreToolUse hook.
/// `answers` is keyed by question text; for multi-select the value is a
/// comma-joined string of selected option labels (verified in spike).
public func submitAskUQAnswer(sessionId: String, answers: [String: String]) {
    guard var session = sessions[sessionId],
          let pending = session.pendingPermission,
          pending.isAskUserQuestion else { return }

    // Reconstruct the questions array CC sent us so updatedInput.questions
    // round-trips intact.
    let questions = (pending.toolInput["questions"] as? [[String: Any]]) ?? []
    let response = PreToolUseHookResponse.askUQAnswers(
        questions: questions, answers: answers
    )
    pending.responder(.preToolUse(response))

    session.pendingPermission = nil
    session.state = .working
    session.lastActiveAt = Date()
    sessions[sessionId] = session
}
```

- [ ] **Step 4: Update construction sites**

The PendingPermission init now requires `bridgeEventOrigin`. Find every constructor call (likely two):

(a) In `SocketServer.swift` (around line 162 — inside `handleConnection`'s blocking branch). The `onEvent` callback constructs PendingPermission via the AppDelegate; the actual PendingPermission init is in AppDelegate / event handler code. Check `grep -rn "PendingPermission(" Sources/`.

```bash
grep -rn "PendingPermission(" Sources/
```

For each call site, add `bridgeEventOrigin: event.bridgeEvent` argument (the BridgeEvent at hand — its `bridgeEvent` field is exactly `"PermissionRequest"` or `"PreToolUse"`).

- [ ] **Step 5: Write tests for `submitAskUQAnswer`**

Append to `Tests/AppLibTests/SessionStoreTests.swift`:

```swift
@Test @MainActor func submitAskUQAnswer_callsResponderWithEncodedJSON() throws {
    let store = SessionStore()
    var capturedData: Data?

    let pending = SessionStore.PendingPermission(
        toolName: "AskUserQuestion",
        toolInput: ["questions": [
            ["question": "Pick a color",
             "header": "color",
             "multiSelect": false,
             "options": [["label": "red", "description": "warm"]]]
        ]],
        cwd: "/tmp",
        bridgeEventOrigin: "PreToolUse",
        responder: { response in
            capturedData = try? response.encoded()
        }
    )
    store.handlePermissionRequest(sessionId: "s1", permission: pending)

    store.submitAskUQAnswer(
        sessionId: "s1",
        answers: ["Pick a color": "red"]
    )

    let data = try #require(capturedData)
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    let hook = json["hookSpecificOutput"] as! [String: Any]
    #expect(hook["hookEventName"] as? String == "PreToolUse")
    let updated = hook["updatedInput"] as! [String: Any]
    let answers = updated["answers"] as! [String: String]
    #expect(answers["Pick a color"] == "red")

    // pending should be cleared
    #expect(store.sessions["s1"]?.pendingPermission == nil)
    #expect(store.sessions["s1"]?.state == .working)
}
```

- [ ] **Step 6: Run all tests**

```bash
swift test 2>&1 | tail -25
```

Expected: all green (Shared, BridgeLib, AppLib).

- [ ] **Step 7: Commit**

```bash
git add Sources/AppLib/Session/SessionStore.swift Tests/AppLibTests/SessionStoreTests.swift Sources/AppLib/  # any files touched in step 4
git commit -m "$(cat <<'EOF'
feat(session): submitAskUQAnswer routes answers via PreToolUse responder

PendingPermission.responder now takes BridgeResponse and carries a
bridgeEventOrigin tag so callers know which channel produced this
prompt. submitAskUQAnswer reconstructs updatedInput.{questions,answers}
and clears the pending state.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: SocketServer — auto-allow PermissionRequest+AskUQ

**Files:**
- Modify: `Sources/AppLib/Socket/SocketServer.swift` (or wherever the event is dispatched into PendingPermission — likely in AppDelegate)

The risk this avoids: a user with restrictive permissions whose AskUserQuestion isn't pre-allowed would otherwise see the old read-only preview block (PermissionRequest path) **on top of** the new clickable block (PreToolUse path) for the same tool call.

- [ ] **Step 1: Locate the dispatch into PendingPermission**

```bash
grep -rn "PendingPermission(" Sources/AppLib/
```

The dispatch likely lives in `AppDelegate` (or an event router) inside the `setEventHandler` callback.

- [ ] **Step 2: Add the shortcut**

In the dispatch site, before constructing `PendingPermission`, insert:

```swift
// PreToolUse path now owns AskUserQuestion. If a stale PermissionRequest
// for AskUQ comes through (user with strict allow list), auto-allow so
// it doesn't render the old read-only preview behind the new flow.
if event.bridgeEvent == "PermissionRequest" && event.toolName == "AskUserQuestion" {
    responder?(.permission(.allow(message: "Handled by PreToolUse")))
    return
}
```

- [ ] **Step 3: Build + run tests**

```bash
swift build && swift test 2>&1 | tail -10
```

Expected: green.

- [ ] **Step 4: Commit**

```bash
git add Sources/AppLib/  # adjust path
git commit -m "$(cat <<'EOF'
fix(session): auto-allow stale PermissionRequest for AskUserQuestion

PreToolUse path is the single source of truth for AskUQ now. A leftover
PermissionRequest from CC (when AskUQ isn't in the allow list) gets an
immediate allow so the old read-only preview never renders behind the
new clickable UI.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: NotchViewModel — passthrough `submitAskUQAnswer`

**Files:**
- Modify: `Sources/AppLib/Notch/NotchViewModel.swift`

- [ ] **Step 1: Add the method**

In `Sources/AppLib/Notch/NotchViewModel.swift`, near the existing `resolvePermission` calls (around line 50-60), add:

```swift
public func submitAskUQAnswer(sessionId: String, answers: [String: String]) {
    sessionStore.submitAskUQAnswer(sessionId: sessionId, answers: answers)
}
```

- [ ] **Step 2: Build**

```bash
swift build 2>&1 | tail -10
```

Expected: succeeds.

- [ ] **Step 3: Commit**

```bash
git add Sources/AppLib/Notch/NotchViewModel.swift
git commit -m "$(cat <<'EOF'
feat(notch): expose submitAskUQAnswer through NotchViewModel

Thin pass-through so the SwiftUI view can call into the session store
without holding a direct reference to it.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 10: NotchExpandedView — clickable single-select options

**Files:**
- Modify: `Sources/AppLib/Notch/NotchExpandedView.swift` (`askUserQuestionBlock`)

- [ ] **Step 1: Replace the option list with `Button`**

In `NotchExpandedView.swift`, find `askUserQuestionBlock` (line ~413). Inside the `ForEach` that renders options (currently lines ~448-481), replace the static option row with a `Button`-wrapped version that **only fires for non-multi-select questions**:

```swift
VStack(spacing: 4) {
    ForEach(Array(question.options.enumerated()), id: \.element.id) { index, option in
        if !question.multiSelect {
            Button {
                viewModel.submitAskUQAnswer(
                    sessionId: session.id,
                    answers: [question.text: option.label]
                )
            } label: {
                askUQOptionRow(index: index, option: option, selected: false)
            }
            .buttonStyle(.plain)
        } else {
            // Multi-select rendering lands in Task 11
            askUQOptionRow(index: index, option: option, selected: false)
        }
    }
}
```

- [ ] **Step 2: Extract `askUQOptionRow` as a private helper**

After `askUserQuestionBlock`, add:

```swift
@ViewBuilder
private func askUQOptionRow(
    index: Int,
    option: PendingPermission.QuestionOption,
    selected: Bool
) -> some View {
    HStack(alignment: .top, spacing: 10) {
        Text("\(index + 1)")
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .foregroundColor(Color(red: 0.31, green: 0.80, blue: 0.77))
            .frame(width: 20, height: 20)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(red: 0.31, green: 0.80, blue: 0.77).opacity(selected ? 0.35 : 0.15))
            )
        VStack(alignment: .leading, spacing: 2) {
            Text(option.label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(1)
                .truncationMode(.tail)
            if let desc = option.description {
                Text(desc)
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.6))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        Spacer(minLength: 0)
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
        RoundedRectangle(cornerRadius: 6)
            .fill(Color.white.opacity(selected ? 0.10 : 0.04))
    )
}
```

- [ ] **Step 3: Remove the "请在终端回答" footer**

Find the `Button(action: { viewModel.activateTerminal(...) })` block at the bottom of `askUserQuestionBlock` (around line 487-510). Delete it entirely. The block ends with `}` closing the outer `VStack`.

- [ ] **Step 4: Build the app and smoke-test**

```bash
make app && open .build/ZackEyes.app
```

Trigger an AskUQ from a CC session in some directory:
```
Use the AskUserQuestion tool to ask me a single question with header "color" and three options: red, blue, green.
```

Verify:
- Notch expands automatically
- Three option rows are clickable (cursor changes on hover)
- Tapping `red` causes Claude Code to receive `"red"` as the answer
- Notch collapses after the tap

If smoke fails, debug before committing.

- [ ] **Step 5: Commit**

```bash
git add Sources/AppLib/Notch/NotchExpandedView.swift
git commit -m "$(cat <<'EOF'
feat(notch): make AskUQ single-select options clickable

Tapping an option submits it via submitAskUQAnswer, CC consumes the
answer through the PreToolUse updatedInput channel. The terminal
fallback footer is removed — terminal answering is now the soft-timeout
path, not a primary UI element.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 11: NotchExpandedView — multi-select with Submit

**Files:**
- Modify: `Sources/AppLib/Notch/NotchExpandedView.swift`

- [ ] **Step 1: Add local @State for selected labels**

In the body of `askUserQuestionBlock`, before the `ForEach(pending.questions)`, add a `@State` selection set keyed by question index. Since SwiftUI can't put `@State` inside a `@ViewBuilder` helper, refactor the multi-select rendering into its own struct view:

Add this new view struct in the same file (above `askUserQuestionBlock`):

```swift
private struct AskUQMultiSelectQuestion: View {
    let session: SessionInfo
    let question: PendingPermission.Question
    let viewModel: NotchViewModel
    @State private var selected: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(question.options.enumerated()), id: \.element.id) { index, option in
                Button {
                    if selected.contains(option.label) {
                        selected.remove(option.label)
                    } else {
                        selected.insert(option.label)
                    }
                } label: {
                    askUQMultiSelectRow(
                        index: index,
                        option: option,
                        selected: selected.contains(option.label)
                    )
                }
                .buttonStyle(.plain)
            }
            Button {
                let joined = question.options
                    .map(\.label)
                    .filter(selected.contains)
                    .joined(separator: ", ")
                viewModel.submitAskUQAnswer(
                    sessionId: session.id,
                    answers: [question.text: joined]
                )
            } label: {
                Text("Submit")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(selected.isEmpty ? .white.opacity(0.4) : .white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(selected.isEmpty
                                  ? Color.white.opacity(0.08)
                                  : Color(red: 0.31, green: 0.80, blue: 0.77).opacity(0.4))
                    )
            }
            .buttonStyle(.plain)
            .disabled(selected.isEmpty)
        }
    }

    @ViewBuilder
    private func askUQMultiSelectRow(
        index: Int,
        option: PendingPermission.QuestionOption,
        selected: Bool
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: selected ? "checkmark.square.fill" : "square")
                .font(.system(size: 14))
                .foregroundColor(selected
                                 ? Color(red: 0.31, green: 0.80, blue: 0.77)
                                 : .white.opacity(0.5))
                .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(option.label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                if let desc = option.description {
                    Text(desc)
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.6))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.white.opacity(selected ? 0.10 : 0.04))
        )
    }
}
```

- [ ] **Step 2: Wire it into `askUserQuestionBlock`**

In `askUserQuestionBlock`, replace the inner placeholder for multi-select (the `else` branch added in Task 10) with the new view:

```swift
ForEach(Array(pending.questions.enumerated()), id: \.offset) { _, question in
    VStack(alignment: .leading, spacing: 8) {
        // Question header (unchanged)
        HStack(alignment: .top, spacing: 4) {
            if let header = question.header {
                Text("[\(header)]")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color(red: 0.31, green: 0.80, blue: 0.77))
            }
            Text(question.text)
                .font(.system(size: 11))
                .foregroundColor(.white)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
        }

        if question.multiSelect {
            AskUQMultiSelectQuestion(
                session: session,
                question: question,
                viewModel: viewModel
            )
        } else {
            VStack(spacing: 4) {
                ForEach(Array(question.options.enumerated()), id: \.element.id) { index, option in
                    Button {
                        viewModel.submitAskUQAnswer(
                            sessionId: session.id,
                            answers: [question.text: option.label]
                        )
                    } label: {
                        askUQOptionRow(index: index, option: option, selected: false)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
```

- [ ] **Step 3: Build + manual smoke**

```bash
make app && open .build/ZackEyes.app
```

Trigger a multi-select AskUQ:
```
Use the AskUserQuestion tool to ask me one multi-select question with header "toppings" and four options: cheese, mushroom, pepperoni, olive. Then tell me what I picked and stop.
```

Verify:
- Each row toggles checkbox on tap
- Submit is grayed out until ≥1 selected
- Submit fires → CC reports e.g. `"cheese, mushroom"`

- [ ] **Step 4: Commit**

```bash
git add Sources/AppLib/Notch/NotchExpandedView.swift
git commit -m "$(cat <<'EOF'
feat(notch): multi-select AskUQ with checkbox + Submit

Multi-select questions render as a list of toggleable checkbox rows
plus a Submit button (disabled while nothing is selected). On submit,
selected labels are joined with ', ' to match CC's verified single-string
answer shape.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 12: Manual integration tests

**Files:** none (verification only)

Run all 7 tests from `2026-04-25-askuq-click-to-answer-design.md` § Testing § Manual Integration. Capture results in a checklist:

- [ ] **Step 1: Test #1 — single-select happy path**

Trigger AskUQ → tap red → expected: CC receives `"red"`, no terminal UI.

- [ ] **Step 2: Test #2 — soft timeout to terminal**

Trigger AskUQ → don't click for 60s → expected: notch collapses, terminal AskUQ UI appears, you can answer there.

- [ ] **Step 3: Test #3 — multi-select**

Trigger multi-select AskUQ → check 2 boxes → Submit → expected: CC receives `"a, b"`.

- [ ] **Step 4: Test #4 — app not running**

Quit ZackEyes. Trigger AskUQ. Expected: terminal UI appears immediately (no notch, no delay).

- [ ] **Step 5: Test #5 — quit ZackEyes mid-prompt**

Launch ZackEyes. Trigger AskUQ (notch shows). While it's showing, quit ZackEyes via menu. Expected: terminal UI appears within ~1s (POLLHUP-driven fallback from Task 4).

- [ ] **Step 6: Test #6 — multi-session concurrency**

Open two `claude` terminals in different cwds. Trigger AskUQ in both. Expected: notch shows two separate questions, each tappable independently.

- [ ] **Step 7: Document the run**

Append a short paragraph to `CHANGELOG.md` (will be formalized in Task 13) noting any failures or unexpected behaviors observed.

---

## Task 13: Docs — CHANGELOG + ARCHITECTURE.md

**Files:**
- Modify: `CHANGELOG.md`
- Modify: `ARCHITECTURE.md`

- [ ] **Step 1: Add a CHANGELOG entry**

Open `CHANGELOG.md`. Determine the next version (current is 0.2.7 per the recent commit `47f9203 chore: bump version to 0.2.7`). Add at the top:

```markdown
## 0.2.8 — 2026-04-25

### Added
- AskUserQuestion can now be answered with a tap in the notch — Claude Code's terminal AskUQ UI is bypassed entirely when ZackEyes is running. Single-select submits on tap; multi-select uses checkboxes plus a Submit button. If no answer in 60s, falls back silently to CC's terminal UI.

### Changed
- Bridge `SocketClient` now uses `poll()` instead of `read()` + `SO_RCVTIMEO`, so app crashes during a permission/AskUQ prompt fall back to the terminal almost instantly.
- Internal `BridgeResponse` enum unifies `PermissionResponse` and the new `PreToolUseHookResponse` at responder call sites.
```

- [ ] **Step 2: Update ARCHITECTURE.md data flow**

In `ARCHITECTURE.md`, find the section `### 状态更新流（单向，fire-and-forget）`. After it, add a new subsection:

```markdown
### AskUserQuestion 自动作答流（双向，同步）

```
Claude Code 触发 PreToolUse hook (tool_name="AskUserQuestion")
  → bridge --event PreToolUse 阻塞 60s 等响应
    → SocketServer 持 fd（沿用 PermissionRequest 的 fd-hold 模式）
    → SessionStore 标 pending（bridgeEventOrigin="PreToolUse"）
    → NotchExpandedView 渲染可点击选项
    → 用户点 → submitAskUQAnswer 通过 responder 写回 PreToolUseHookResponse
    → bridge stdout = JSON → CC 消费 updatedInput.answers，跳过终端 UI
  → 60s 内未点 / app 崩 / socket 异常 → bridge 静默 fallback → CC 渲染终端 UI
```

`BridgeEvent.requiresBlockingResponse` 把"哪些 hook 走阻塞"集中起来：当前 `PermissionRequest` + `PreToolUse(AskUserQuestion)`。
```

Also update the section `### 失败流` to cover the AskUQ POLLHUP path.

- [ ] **Step 3: Bump VERSION + Info.plist via `make release`**

Per memory `feedback_release_workflow.md`, use the standard release workflow:

```bash
make release VERSION=0.2.8
```

Verify the commit and tag are clean:

```bash
git log -2 --oneline
git tag -l v0.2.8
```

- [ ] **Step 4: Final test sweep**

```bash
swift test 2>&1 | tail -10
```

Expected: all green.

- [ ] **Step 5: Push**

(Only if user explicitly asks. Per repo conventions, don't push without confirmation.)

---

## Self-Review Notes

- ✅ **Spec coverage**: every section in the design spec maps to at least one task. Spike #2 → Tasks 1-2. Architecture flow → Tasks 3-6. Component changes → Tasks 3-11. UX → Tasks 10-11. Failure modes → exercised in Task 12. Testing → embedded in each TDD task + Task 12.
- ✅ **No placeholders**: every `Step N` has the actual code/command. The Spike #2A decision is the one explicit placeholder (Task 5 Step 2) — and that's gated on Task 1 producing the answer.
- ✅ **Type consistency**: `PreToolUseHookResponse.askUQAnswers(questions:answers:)` and `submitAskUQAnswer(sessionId:answers:)` and the test signatures all line up. `BridgeResponse` is consistently `.permission` / `.preToolUse`.
- ✅ **TDD where it makes sense**: Tasks 3, 4, 7 are pure TDD. Task 5 (CLI), Task 6 (refactor + extension), Task 8/9 (small wires), and Tasks 10-11 (UI) skip TDD because the right test is the manual integration in Task 12.
- ✅ **Frequent commits**: 11 atomic commits across the implementation tasks (one per task), each independently buildable except Task 6 which warns of the intermediate state explicitly.
