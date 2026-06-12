# Pending Event Queue + Watchdog Evaluation (#89) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When the app isn't running, the bridge spools replayable fire-and-forget hook events to `~/.zackeyes/pending/`; at next app startup they are replayed through the normal event pipeline (with stale-notification suppression) and deleted (GitHub issue #89).

**Architecture:** Write side lives in BridgeLib (`PendingEventQueue`) — called from `Bridge/main.swift`'s fire-and-forget default case only when the socket send fails; a whitelist restricts spooling to low-frequency lifecycle events (no StatusLine/tool spam). Read side lives in AppLib (`PendingEventReplayer`) — runs once at startup, replays files in filename (timestamp) order through `AppDelegate.handleEvent`, injecting a `_bridge_replayed` flag that suppresses notifications. Every file is consumed on replay regardless of outcome, so the queue can never grow across launches. Caps: 200 files (write-side prune-oldest), 24h expiry (read-side drop).

**Watchdog decision: NOT implementing** the claude-statistics `shutdown(fd, SHUT_RDWR)` watchdog. Rationale (recorded for the issue): the only blocking bridge path is PermissionRequest, whose `sendAndWaitForResponse` already polls with POLLHUP detection — if the app dies, the socket closes, poll() wakes, bridge exits 0 within ~1s (documented in ARCHITECTURE.md AskUQ flow: "app 崩溃时 < 1s 内回退"). AskUserQuestion is fire-and-forget since the keystroke-injection redesign. There is no 280s-hang scenario to defend against.

**Tech Stack:** Swift 6 strict concurrency, Foundation only, Swift Testing.

**Branch:** `feat/89-pending-queue` off `b02b4eb` (worktree `.claude/worktrees/feat-89-pending-queue`, baseline 262 tests green).

**Iron rules in blast radius:**
- Invariant #2 (bridge never pollutes the agent terminal): spool failures — unwritable dir, full disk, anything — are silently ignored; every bridge path still exits 0 with no stdout/stderr. The queue write is strictly best-effort.
- Replay must not fire stale notifications (a "session finished" ding for something that ended yesterday) — suppression via `BridgeEvent.isReplayed`.
- Blocking events (PermissionRequest) and high-frequency events (StatusLine, PreToolUse/PostToolUse) are NEVER spooled.

---

## File Structure

| File | Action | Responsibility |
|------|--------|----------------|
| `Sources/Shared/EventProtocol.swift` | Modify | `BridgeEvent.isReplayed` field (`_bridge_replayed`, defaults false) |
| `Sources/BridgeLib/PendingEventQueue.swift` | Create | Write-side spool: whitelist check, timestamped file write, count-cap prune; all-silent |
| `Sources/AppLib/Session/PendingEventReplayer.swift` | Create | Read-side: sort, expire, decode + tag, hand to handler, always delete |
| `Sources/Bridge/main.swift` | Modify | default case: spool on `sendFireAndForget` failure |
| `Sources/ZackEyes/AppDelegate.swift` | Modify | replay after `socketServer.start()`; two `!event.isReplayed` notification guards |
| `Tests/SharedTests/EventProtocolTests.swift` | Modify | isReplayed decode tests |
| `Tests/BridgeLibTests/PendingEventQueueTests.swift` | Create | spool/whitelist/cap/silent-failure tests |
| `Tests/AppLibTests/PendingEventReplayerTests.swift` | Create | order/expiry/malformed/tag/cleanup tests |
| `ARCHITECTURE.md` | Modify | Bridge row, 失败流, new module rows, watchdog decision |

---

### Task 1: `BridgeEvent.isReplayed` (Shared)

**Files:**
- Modify: `Sources/Shared/EventProtocol.swift` (BridgeEvent: field at :113, init param/assign :114-150, CodingKey :152-170, init(from:) :172-193)
- Test: `Tests/SharedTests/EventProtocolTests.swift` (append; read the file first to match its fixture style)

- [ ] **Step 1.1: Write the failing tests** — append to the existing test struct in `EventProtocolTests.swift`:

```swift
    // MARK: - #89 isReplayed

    @Test func isReplayedDefaultsFalseWhenAbsent() throws {
        let json = #"{"_bridge_event":"Stop","session_id":"s1"}"#
        let event = try JSONDecoder().decode(BridgeEvent.self, from: Data(json.utf8))
        #expect(event.isReplayed == false)
    }

    @Test func isReplayedDecodesTrue() throws {
        let json = #"{"_bridge_event":"Stop","session_id":"s1","_bridge_replayed":true}"#
        let event = try JSONDecoder().decode(BridgeEvent.self, from: Data(json.utf8))
        #expect(event.isReplayed == true)
    }
```

- [ ] **Step 1.2:** `swift test --filter EventProtocolTests 2>&1 | tail -5` → compile FAIL (`no member 'isReplayed'`).

- [ ] **Step 1.3: Implement** — four touches in `BridgeEvent`:

After `public let cost: [String: AnyCodable]?`:
```swift
    /// True when this event was replayed from the pending spool at app
    /// startup rather than received live (#89). Suppresses notifications.
    public let isReplayed: Bool
```

Memberwise init: add final parameter `isReplayed: Bool = false` and `self.isReplayed = isReplayed` (default keeps all existing call sites compiling).

CodingKeys: add `case isReplayed = "_bridge_replayed"`.

`init(from:)`: add `self.isReplayed = (try? c.decodeIfPresent(Bool.self, forKey: .isReplayed)) ?? false`.

- [ ] **Step 1.4:** `swift test 2>&1 | tail -3` → 264 pass (262 + 2).

- [ ] **Step 1.5: Commit**

```bash
git add Sources/Shared/EventProtocol.swift Tests/SharedTests/EventProtocolTests.swift
git commit -m "feat(bridge): add BridgeEvent.isReplayed flag for spooled events"
```

---

### Task 2: PendingEventQueue (BridgeLib, write side)

**Files:**
- Create: `Sources/BridgeLib/PendingEventQueue.swift`
- Test: `Tests/BridgeLibTests/PendingEventQueueTests.swift`

- [ ] **Step 2.1: Write the failing tests**

```swift
import Testing
import Foundation
@testable import BridgeLib

struct PendingEventQueueTests {

    private func makeTmpDir() throws -> URL {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        return tmpDir
    }

    private func files(in dir: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()) ?? []
    }

    @Test func eligibleEventIsSpooled() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let dir = tmpDir.appendingPathComponent("pending")
        let queue = PendingEventQueue(directory: dir.path)
        let payload = Data(#"{"_bridge_event":"Stop","session_id":"s1"}"#.utf8)

        queue.enqueueIfEligible(event: "Stop", payload: payload)

        let names = files(in: dir)
        #expect(names.count == 1)
        // <unix-ms>-<pid>-<uuid>.json
        #expect(names[0].hasSuffix(".json"))
        #expect(names[0].split(separator: "-").count >= 3)
        let written = try Data(contentsOf: dir.appendingPathComponent(names[0]))
        #expect(written == payload)
    }

    @Test func ineligibleEventsAreNotSpooled() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let dir = tmpDir.appendingPathComponent("pending")
        let queue = PendingEventQueue(directory: dir.path)
        let payload = Data("{}".utf8)

        for event in ["StatusLine", "PermissionRequest", "PreToolUse", "PostToolUse"] {
            queue.enqueueIfEligible(event: event, payload: payload)
        }

        // Directory is never even created for ineligible events.
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }

    @Test func capPrunesOldestBeyondMaxCount() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let dir = tmpDir.appendingPathComponent("pending")
        let queue = PendingEventQueue(directory: dir.path, maxCount: 3)
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        for i in 0..<5 {
            queue.enqueueIfEligible(
                event: "Stop",
                payload: Data("{\"n\":\(i)}".utf8),
                now: base.addingTimeInterval(Double(i))
            )
        }

        let names = files(in: dir)
        #expect(names.count == 3)
        // Filename sort is chronological (fixed-width ms prefix) — the two
        // oldest timestamps must be the ones evicted.
        let survivingPrefixes = names.compactMap { $0.split(separator: "-").first }
        let expectedOldest = String(Int(base.timeIntervalSince1970 * 1000))
        #expect(!survivingPrefixes.contains(Substring(expectedOldest)))
    }

    @Test func spoolFailureIsSilent() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        // Point the queue at a path occupied by a regular FILE — directory
        // creation and the write both fail; enqueue must not throw or crash.
        let blocked = tmpDir.appendingPathComponent("blocked")
        try "x".write(to: blocked, atomically: true, encoding: .utf8)
        let queue = PendingEventQueue(directory: blocked.path)

        queue.enqueueIfEligible(event: "Stop", payload: Data("{}".utf8))

        let attrs = try FileManager.default.attributesOfItem(atPath: blocked.path)
        #expect((attrs[.type] as? FileAttributeType) == .typeRegular)  // untouched
    }

    @Test func sessionLifecycleWhitelistIsExact() {
        #expect(PendingEventQueue.replayableEvents == [
            "SessionStart", "SessionEnd", "Stop", "UserPromptSubmit",
            "Notification", "PreCompact", "PostCompact",
            "SubagentStart", "SubagentStop",
        ])
    }
}
```

- [ ] **Step 2.2:** `swift test --filter PendingEventQueueTests 2>&1 | tail -5` → compile FAIL.

- [ ] **Step 2.3: Implement** — create `Sources/BridgeLib/PendingEventQueue.swift`:

```swift
import Foundation

/// Write-side spool for fire-and-forget hook events that couldn't reach the
/// app's socket (#89). The bridge calls `enqueueIfEligible` only after a
/// failed `sendFireAndForget`; the app replays and deletes the files at next
/// startup via `PendingEventReplayer`.
///
/// Bridge invariant #2 applies in full: every operation here is best-effort
/// and silent. A failed directory creation, a full disk, a permission error —
/// all are swallowed; the caller still exits 0 with no output.
///
/// Only low-frequency lifecycle events are spooled. StatusLine ticks every
/// few seconds and its rate-limit payload is worthless when stale; tool
/// events (PreToolUse/PostToolUse) can number in the hundreds per session and
/// are reconstructed from transcripts by SessionScanner anyway;
/// PermissionRequest is blocking and meaningless to replay.
public struct PendingEventQueue: Sendable {

    public static let replayableEvents: Set<String> = [
        "SessionStart", "SessionEnd", "Stop", "UserPromptSubmit",
        "Notification", "PreCompact", "PostCompact",
        "SubagentStart", "SubagentStop",
    ]

    private let directory: String
    private let maxCount: Int

    public init(
        directory: String = NSHomeDirectory() + "/.zackeyes/pending",
        maxCount: Int = 200
    ) {
        self.directory = directory
        self.maxCount = maxCount
    }

    /// Best-effort spool of one newline-terminated JSON event payload.
    /// File name `<unix-ms>-<pid>-<uuid>.json` — the fixed-width millisecond
    /// prefix makes lexicographic order chronological for the replayer.
    public func enqueueIfEligible(event: String, payload: Data, now: Date = Date()) {
        guard Self.replayableEvents.contains(event) else { return }
        let fm = FileManager.default
        guard (try? fm.createDirectory(
            atPath: directory, withIntermediateDirectories: true)) != nil
        else { return }

        let ms = Int(now.timeIntervalSince1970 * 1000)
        let name = "\(ms)-\(getpid())-\(UUID().uuidString).json"
        let url = URL(fileURLWithPath: directory).appendingPathComponent(name)
        guard (try? payload.write(to: url, options: .atomic)) != nil else { return }

        pruneOverCap()
    }

    /// Evict oldest files beyond `maxCount`. Newer events win: a SessionEnd
    /// from five minutes ago beats a SessionStart from last week.
    private func pruneOverCap() {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory) else { return }
        let sorted = names.filter { $0.hasSuffix(".json") }.sorted()
        guard sorted.count > maxCount else { return }
        for name in sorted.prefix(sorted.count - maxCount) {
            try? fm.removeItem(atPath: directory + "/" + name)
        }
    }
}
```

- [ ] **Step 2.4:** `swift test --filter PendingEventQueueTests 2>&1 | tail -5` → 5 pass; full suite → 269.

- [ ] **Step 2.5: Commit**

```bash
git add Sources/BridgeLib/PendingEventQueue.swift Tests/BridgeLibTests/PendingEventQueueTests.swift
git commit -m "feat(bridge): spool undeliverable lifecycle events to ~/.zackeyes/pending"
```

---

### Task 3: PendingEventReplayer (AppLib, read side)

**Files:**
- Create: `Sources/AppLib/Session/PendingEventReplayer.swift`
- Test: `Tests/AppLibTests/PendingEventReplayerTests.swift`

- [ ] **Step 3.1: Write the failing tests**

```swift
import Testing
import Foundation
import Shared
@testable import AppLib

struct PendingEventReplayerTests {

    private func makeTmpDir() throws -> URL {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        return tmpDir
    }

    /// Write a spool file the way PendingEventQueue would name it.
    private func writePending(
        dir: URL, msTimestamp: Int, sessionId: String, body: String? = nil
    ) throws {
        let payload = body ?? #"{"_bridge_event":"Stop","session_id":"\#(sessionId)"}"#
        let name = "\(msTimestamp)-123-\(UUID().uuidString).json"
        try payload.write(
            to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    @Test func replaysInTimestampOrderThenDeletes() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let now = Date(timeIntervalSince1970: 1_700_000_100)
        let baseMs = 1_700_000_000_000
        try writePending(dir: tmpDir, msTimestamp: baseMs + 2000, sessionId: "third")
        try writePending(dir: tmpDir, msTimestamp: baseMs, sessionId: "first")
        try writePending(dir: tmpDir, msTimestamp: baseMs + 1000, sessionId: "second")

        var seen: [String] = []
        let replayer = PendingEventReplayer(directory: tmpDir.path)
        let count = replayer.replayAll(now: now) { seen.append($0.sessionId ?? "?") }

        #expect(count == 3)
        #expect(seen == ["first", "second", "third"])
        #expect((try? FileManager.default.contentsOfDirectory(atPath: tmpDir.path))?.isEmpty == true)
    }

    @Test func expiredFilesDeletedWithoutReplay() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let now = Date(timeIntervalSince1970: 1_700_100_000)
        let staleMs = Int((now.timeIntervalSince1970 - 25 * 3600) * 1000)  // 25h old
        try writePending(dir: tmpDir, msTimestamp: staleMs, sessionId: "stale")

        var seen = 0
        let replayer = PendingEventReplayer(directory: tmpDir.path, maxAge: 24 * 3600)
        let count = replayer.replayAll(now: now) { _ in seen += 1 }

        #expect(count == 0)
        #expect(seen == 0)
        #expect((try? FileManager.default.contentsOfDirectory(atPath: tmpDir.path))?.isEmpty == true)
    }

    @Test func malformedFilesDeletedSilently() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let now = Date(timeIntervalSince1970: 1_700_000_100)
        try writePending(
            dir: tmpDir, msTimestamp: 1_700_000_000_000,
            sessionId: "x", body: "{not json")

        var seen = 0
        let count = PendingEventReplayer(directory: tmpDir.path)
            .replayAll(now: now) { _ in seen += 1 }

        #expect(count == 0 && seen == 0)
        #expect((try? FileManager.default.contentsOfDirectory(atPath: tmpDir.path))?.isEmpty == true)
    }

    @Test func replayedEventsCarryIsReplayedFlag() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let now = Date(timeIntervalSince1970: 1_700_000_100)
        try writePending(dir: tmpDir, msTimestamp: 1_700_000_000_000, sessionId: "s1")

        var flags: [Bool] = []
        _ = PendingEventReplayer(directory: tmpDir.path)
            .replayAll(now: now) { flags.append($0.isReplayed) }

        #expect(flags == [true])
    }

    @Test func nonJsonFilesAreLeftAlone() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        try "junk".write(
            to: tmpDir.appendingPathComponent(".DS_Store"), atomically: true, encoding: .utf8)

        let count = PendingEventReplayer(directory: tmpDir.path)
            .replayAll(now: Date(timeIntervalSince1970: 1)) { _ in }

        #expect(count == 0)
        #expect(FileManager.default.fileExists(atPath: tmpDir.appendingPathComponent(".DS_Store").path))
    }

    @Test func missingDirectoryIsANoOp() {
        let replayer = PendingEventReplayer(
            directory: "/nonexistent/zackeyes-test-\(UUID().uuidString)")
        let count = replayer.replayAll(now: Date()) { _ in }
        #expect(count == 0)
    }
}
```

- [ ] **Step 3.2:** `swift test --filter PendingEventReplayerTests 2>&1 | tail -5` → compile FAIL.

- [ ] **Step 3.3: Implement** — create `Sources/AppLib/Session/PendingEventReplayer.swift`:

```swift
import Foundation
import Shared

/// Read side of the pending-event spool (#89). At app startup, replays the
/// events `PendingEventQueue` wrote while the app was closed, in filename
/// (timestamp) order, through the same handler the live socket uses.
///
/// Every `.json` file is consumed — replayed, expired, or malformed, it is
/// deleted afterwards — so the spool can never accumulate across launches.
/// Replayed events carry `isReplayed == true` (injected `_bridge_replayed`)
/// so the event pipeline suppresses stale notifications.
public struct PendingEventReplayer {

    private let directory: String
    private let maxAge: TimeInterval

    public init(
        directory: String = NSHomeDirectory() + "/.zackeyes/pending",
        maxAge: TimeInterval = 24 * 3600
    ) {
        self.directory = directory
        self.maxAge = maxAge
    }

    /// Returns the number of events handed to `handler`.
    @discardableResult
    public func replayAll(
        now: Date = Date(),
        handler: (BridgeEvent) -> Void
    ) -> Int {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory) else { return 0 }

        var replayed = 0
        for name in names.filter({ $0.hasSuffix(".json") }).sorted() {
            let path = directory + "/" + name
            // Consume unconditionally: replayed, expired, or unreadable, the
            // file is done after this iteration.
            defer { try? fm.removeItem(atPath: path) }

            guard let ts = Self.timestamp(fromFileName: name),
                  now.timeIntervalSince(ts) <= maxAge,
                  let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  var json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { continue }

            json["_bridge_replayed"] = true
            guard let tagged = try? JSONSerialization.data(withJSONObject: json),
                  let event = try? JSONDecoder().decode(BridgeEvent.self, from: tagged)
            else { continue }

            handler(event)
            replayed += 1
        }
        return replayed
    }

    /// `<unix-ms>-<pid>-<uuid>.json` → spool time.
    static func timestamp(fromFileName name: String) -> Date? {
        guard let msPart = name.split(separator: "-").first,
              let ms = Double(msPart) else { return nil }
        return Date(timeIntervalSince1970: ms / 1000)
    }
}
```

- [ ] **Step 3.4:** `swift test --filter PendingEventReplayerTests 2>&1 | tail -5` → 6 pass; full suite → 275.

- [ ] **Step 3.5: Commit**

```bash
git add Sources/AppLib/Session/PendingEventReplayer.swift Tests/AppLibTests/PendingEventReplayerTests.swift
git commit -m "feat(session): replay spooled pending events at startup"
```

---

### Task 4: Wiring — Bridge spool call + AppDelegate replay + notification suppression

**Files:**
- Modify: `Sources/Bridge/main.swift` (default case only)
- Modify: `Sources/ZackEyes/AppDelegate.swift` (after `try socketServer.start()` :71; two guards in `handleEvent` default-case notify blocks :575, :606)

- [ ] **Step 4.1: Bridge** — replace the final `default:` case body in `main.swift`:

```swift
default:
    // Fire-and-forget observation-only hook. Always exit 0. If the socket
    // isn't reachable (app not running), spool replayable lifecycle events
    // to ~/.zackeyes/pending/ for startup replay (#89); everything else is
    // dropped and recovered by the periodic SessionScanner sweep. The spool
    // itself is best-effort and silent — invariant #2 holds either way.
    if !client.sendFireAndForget(data: payloadData) {
        PendingEventQueue().enqueueIfEligible(event: eventName, payload: payloadData)
    }
    exit(0)
```

(`PendingEventQueue` is in BridgeLib, already imported by main.swift.)

- [ ] **Step 4.2: AppDelegate replay** — immediately after the `try socketServer.start()` line (inside the same do/catch or following it — read the surrounding code and place it right after the successful start):

```swift
        // #89 — replay fire-and-forget events the bridge spooled while the
        // app was closed. Same routing as live socket events; isReplayed
        // suppresses stale notifications inside handleEvent.
        let replayedCount = PendingEventReplayer().replayAll { [weak self] event in
            self?.handleEvent(event, responder: nil)
        }
        if replayedCount > 0 {
            NSLog("ZackEyes: replayed %d pending hook events", replayedCount)
        }
```

- [ ] **Step 4.3: Suppression guards** — in `handleEvent`'s default case:

The error-notification block (currently `if let errLabel = session.errorMessage, session.errorAt != priorErrorAt {`) becomes:

```swift
            // Replayed events never notify — the error/finish happened while
            // the app was closed; the panel state is refreshed silently.
            if !event.isReplayed,
               let errLabel = session.errorMessage,
               session.errorAt != priorErrorAt {
```

The Stop-notification block (currently `if event.bridgeEvent == "Stop", session.errorMessage == nil, priorState == .working || priorState == .waiting {`) becomes:

```swift
            if !event.isReplayed,
               event.bridgeEvent == "Stop",
               session.errorMessage == nil,    // don't double-notify on errors
               priorState == .working || priorState == .waiting {
```

No other handleEvent changes. (PermissionRequest/StatusLine/PreToolUse cases are unreachable for replays by whitelist.)

- [ ] **Step 4.4:** `swift build 2>&1 | tail -3` clean; `swift test 2>&1 | tail -3` → 275 pass.

- [ ] **Step 4.5: Manual smoke (bridge side, hermetic)** — verify the spool happens with the app socket absent, WITHOUT touching the running app: run the bridge with a nonexistent socket by temporarily pointing HOME at a tmp dir:

```bash
mkdir -p /tmp/zacktest-home && env HOME=/tmp/zacktest-home sh -c 'echo "{\"hook_event_name\":\"Stop\",\"session_id\":\"spool-test\",\"cwd\":\"/tmp\"}" | $(swift build --show-bin-path)/bridge --event Stop --agent claude; echo "exit=$?"; ls /tmp/zacktest-home/.zackeyes/pending/'
```

Expected: `exit=0`, exactly one `<ms>-<pid>-<uuid>.json` file. ⚠️ Caveat: if the REAL app is running, `/tmp/zackeyes.sock` is reachable and the send succeeds — no spool. In that case verify the inverse (no pending dir created) and rely on the unit tests, OR use `env HOME=... ` plus a bind-blocked socket path — do NOT stop the user's running app. Also note: the bridge connects to the FIXED `/tmp/zackeyes.sock`, so with the app running this smoke proves only the happy path; the failure path is covered by unit tests. Report which variant you observed.

Then clean up: `rm -rf /tmp/zacktest-home`.

- [ ] **Step 4.6: Commit**

```bash
git add Sources/Bridge/main.swift Sources/ZackEyes/AppDelegate.swift
git commit -m "feat(bridge): wire pending-event spool and startup replay"
```

---

### Task 5: Docs

**Files:**
- Modify: `ARCHITECTURE.md`

- [ ] **Step 5.1:** Four edits, matching surrounding Chinese style:

1. Bridge component table (组件架构 section, Bridge CLI row) — append to 职责: `；socket 不可达时把白名单生命周期事件落盘 `~/.zackeyes/pending/` 供启动补播（#89）`.
2. 失败流 section (the `bridge 连接 /tmp/zackeyes.sock 失败` diagram) — after the `→ bridge exit(0) 且不写 stdout` line, add a line: `→ 白名单生命周期事件（SessionStart/End、Stop、UserPromptSubmit、Notification、compact/subagent）先落盘 ~/.zackeyes/pending/（上限 200 个 / 24h 过期，写盘失败同样静默）`.
3. Module tables: add to **Bridge** table: `| PendingEventQueue | Sources/BridgeLib/PendingEventQueue.swift | #89 写侧:socket 发送失败时白名单事件落盘 <ms>-<pid>-<uuid>.json；200 个上限裁剪最旧;一切失败静默(invariant #2) |`; add to **Socket / Session 核心** table: `| PendingEventReplayer | Sources/AppLib/Session/PendingEventReplayer.swift | #89 读侧:启动时按时间序补播 pending 事件进 handleEvent(isReplayed 抑制过期通知),24h 过期丢弃,文件一律消费删除 |`.
4. 安全模型 Bridge 防御性设计 table — update the `Socket 不存在 / App 未运行` row's 行为 cell: `静默退出（无 stdout）；白名单事件先落盘 pending 队列` (exit code stays 0).

Also append one line to the 失败流 catch-up sentence ("App 重连后靠 SessionScanner 做 catch-up sweep") mentioning the pending replay happens first: adapt in place, e.g. `App 重启后先补播 pending 队列，再靠 SessionScanner 做 catch-up sweep`.

- [ ] **Step 5.2:** `swift build 2>&1 | tail -2 && swift test 2>&1 | tail -2 && make app 2>&1 | tail -2` — all green. Stage the plan file too.

- [ ] **Step 5.3: Commit**

```bash
git add ARCHITECTURE.md docs/superpowers/plans/2026-06-12-pending-event-queue.md
git commit -m "docs: document pending-event spool/replay and watchdog decision"
```

---

### Task 6: Ship

- [ ] Final whole-branch review (fresh reviewer, 19bf47a-style range review off b02b4eb).
- [ ] Push, PR `feat(bridge): spool undeliverable hook events and replay at startup (#89)`; body: motivation, watchdog NOT-implemented rationale (quote the POLLHUP fallback), whitelist + caps, invariant #2 statement, acceptance-criteria mapping, test counts. `Closes #89`.
- [ ] Bot review (gemini + coderabbit) → evaluate → fix valid → reply dispositions → squash-merge per precedent.
- [ ] Post-merge: tick #89 in roadmap #92 v0.7.0 section; update memory; pull master in main checkout.

---

## Self-Review Notes

- **Acceptance mapping:** replay after close → Task 3+4 (+ unit tests `replaysInTimestampOrderThenDeletes`); silent failure → `spoolFailureIsSilent` + invariant comment in queue; cap + expiry → `capPrunesOldestBeyondMaxCount` + `expiredFilesDeletedWithoutReplay`; tests → 13 new.
- **Watchdog:** explicitly evaluated and skipped (header rationale); PR + issue comment will record it so the checkbox isn't read as "forgot".
- **Replay vs SessionScanner ordering:** replay runs synchronously right after socket start, before the scanner Task gets scheduled; but both paths are state-merge tolerant (scanner skips sessions the store already knows). No hard ordering requirement.
- **`writePending` test helper uses `\#(...)` interpolation inside a raw string (`#"..."#`)** — correct Swift; implementers shouldn't "fix" it.
- **Why payload (not BridgeEvent) is spooled:** the bridge already holds the enriched newline-terminated JSON bytes; writing them verbatim avoids a second encode and keeps the replayer's input identical to what the socket would have carried.
