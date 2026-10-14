# SSH Remote Observation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** Observe Claude/Codex sessions over one key-authenticated SSH stream per host, without remote approval or a daemon (#261).

**Architecture:** A Foundation-only RemoteCore owns bounded metadata DTOs, JSONL framing and transcript observation. The independent zackeyes-stream executable runs over foreground SSH. Mac-only configuration, transport and manager adapt snapshots into explicitly remote SessionInfo values; Settings and both panel paths share host status and source-aware visibility.

**Tech Stack:** Swift 6, Foundation, system SSH, Swift Testing; AppKit/SwiftUI on Mac only. No external packages. Docker Swift 6.0.3 supplies actual Linux validation.

**Spec:** `docs/superpowers/specs/2026-10-14-ssh-remote-observation-design.md` (approved).

## Global Constraints

- Build artifact `zackeyes-stream` must not collide with `ZackEyes` on case-insensitive macOS; install remote binary as `~/.local/bin/zackeyes`.
- Linux package builds/tests only RemoteCore/RemoteStream/RemoteCoreTests, with no AppLib/Shared/Bridge/AppKit dependencies.
- Protocol v1: complete JSONL snapshots and heartbeat every 5 seconds, max1MiB/frame and256sessions; bounded IDs/names/dates, no prompts/replies/tool arguments/credentials/PIDs.
- Only read Claude projects and Codex sessions; no hooks/config edits, no daemon/listening port.
- Up to8 configured hosts; key auth only, strict known hosts, no key updates or SSH multiplexing ownership, no local shell.
- One connection/task per enabled host, capped exponential reconnect, heartbeat timeout, generation cancellation and process teardown.
- Host namespace and `.remote` provenance protect all local process/Git/terminal/liveness paths; no remote permissions, ledger/journal/quota ingestion.
- Connecting/error/session hosts keep When Active affordance visible; Hidden suppresses remote-driven expansion/visibility, local permission behavior remains unchanged.

### Task 1: Portable protocol, observer and executable

**Files:** `Package.swift`; create `Sources/RemoteCore/{RemoteProtocol,RemoteTranscriptScanner}.swift`, `Sources/RemoteStream/main.swift`, `Tests/RemoteCoreTests/RemoteCoreTests.swift`.

**Interfaces:** public `RemoteSnapshot(version:observedAt:sessions:truncated:)`, `RemoteSessionSnapshot(id:agent:state:cwd:model:tool:lastActivity:)`; enums `RemoteAgent` and `RemoteSessionState`. `RemoteFrameCodec.encode(_:)`/`decode(_:)` enforce limits. `RemoteLineFramer.push(_:)` returns decoded snapshots. `RemoteTranscriptScanner(claudeRoot:codexRoot:).snapshot(now:) throws` emits metadata-only recent sessions with cached bounded fd reads.

- [ ] Add failing fixture tests for Claude/Codex state transitions/metadata, no text serialization, identity/recency, framing partial/multiple/oversized/bad-version data, duplicate sessions and empty snapshots.

```swift
var framer = RemoteLineFramer()
let bytes = try RemoteFrameCodec.encode(snapshot)
#expect(try framer.push(bytes.prefix(10)).isEmpty)
#expect(try framer.push(bytes.dropFirst(10)) == [snapshot])
```

- [ ] Run `swift test --filter RemoteCoreTests`; confirm expected missing APIs/behavior.
- [ ] Implement DTO validation and JSONL framing; observer reads regular nonlinked bounded transcript head/tail, caches unchanged files and infers only recorded transitions. Questions are read-only waiting; unknown states stay unknown. Stream CLI parses `--stream`/help, emits immediately and periodically, stdout protocol-only, exits on signals/broken pipe.
- [ ] Run Mac core tests and CLI pipe/disconnect checks; run `docker run --rm -v "$PWD:/workspace:ro" -w /workspace swift:6.0 swift test --scratch-path /tmp/zackeyes-linux-build` and separate Linux executable stream smoke. Commit `feat(session): add portable remote snapshot stream`.

### Task 2: Host config and owned SSH transport

**Files:** create `Sources/AppLib/Remote/{RemoteHostConfig,RemoteSSHTransport}.swift`; tests `Tests/AppLibTests/RemoteHostConfigTests.swift`, `RemoteSSHTransportTests.swift`.

**Interfaces:** `RemoteHostConfig` Codable/Identifiable with stable UUID, name, destination and enabled flag; `RemoteHostConfigStore(url:).load()/save(_:)` rejects malformed/unsupported data and preserves it. `RemoteSSHTransport.open(host:) -> RemoteConnection` provides AsyncThrowingStream plus idempotent cancellation and async process-exit wait. Internal SSH executable/config injection supports a real isolated SSH test without editing user SSH files.

- [ ] Write/run failing host validation/config-preservation and exact SSH argument tests; transport fixtures exercise repeated frames, stderr flooding, EOF/partial/invalid output, heartbeat timeout and cancellation.

```swift
#expect(try RemoteHostConfig(name:"Build",destination:"user@build").destination == "user@build")
#expect(throws:(any Error).self) { try RemoteHostConfig(name:"Bad",destination:"-oProxyCommand=x") }
```

- [ ] Implement atomic app-owned remote-hosts.json, max8 unique IDs/destinations, restricted destination syntax, bounded UI labels. SSH argument arrays set publickey-only/BatchMode/strict known hosts/no key updates/no multiplexing; fixed remote exec command. Dedicated I/O queues drain both pipes with bounds, framing uses RemoteCore, cancellation terminates/escalates and waits, heartbeat timeout finishes a dead stream.
- [ ] Run focused tests, real temporary sshd/key/config roundtrip and client-close teardown; commit `feat(session): manage key-only SSH host streams`.

### Task 3: Reconnect manager and source-safe SessionStore adaptation

**Files:** create `Sources/AppLib/Remote/RemoteHostManager.swift`; modify `SessionStore.swift`, `NotchViewModel.swift`, `GitStatusReader.swift`, AppDelegate liveness/visibility boundaries and both notch controllers. Test `RemoteHostManagerTests.swift`, `RemoteSessionPresentationTests.swift`.

**Interfaces:** manager publishes `[RemoteHostStatus]`, configuration errors and post-change callback; `start()/stop()/saveHost()/removeHost()` own one task per host and await old connection termination before replacement. `SessionStore.replaceRemoteSessions(host:snapshot:)` replaces only namespaced host entries; `removeRemoteSessions(hostID:)`. `.remote` plus remote host metadata is explicit in SessionInfo. ViewModel exposes `hasActivityForVisibility` and local-vs-remote attention distinction.

- [ ] Write/run failing fake-transport tests for one connection/host, drop/backoff/reset, empty snapshots, disable/remove/edit/stop/generation, host/agent/local-ID collisions, no responder/action/process discovery, and zero-session error visibility/Hidden/demo transitions.

```swift
store.replaceRemoteSessions(host:host,snapshot:snapshot)
#expect(store.sessions.values.allSatisfy { $0.source == .remote && $0.pendingPermission == nil && $0.claudePid == nil })
#expect(SessionStore.portScanRoots(Array(store.sessions.values)).isEmpty)
#expect(GitStatusReader.scanCwds(Array(store.sessions.values)).isEmpty)
```

- [ ] Implement reconnect lifecycle and safe adaptation. Explicitly exclude remote sources from local liveness candidates, nil-cwd pruning, port/Git scans and terminal activation. Host errors clear live cards but retain status chips; aggregate waiting text never implies a remote approval is locally answerable. Both surfaces apply source-aware visibility; local permissions retain their existing behavior.
- [ ] Run all related local session/demo/visibility tests as well as new tests; commit `feat(session): present remote hosts without local actions`.

### Task 4: Native host Settings, cards and integration completion

**Files:** create `Sources/AppLib/Remote/RemoteHostsView.swift`; wire SettingsRootView/Window, NotchExpandedView, AppDelegate lifecycle/menu, README, ARCHITECTURE, this plan and relevant tests.

- [ ] Add a Remote Hosts Settings section with add/edit/remove/toggle, status/error, setup guidance and validation. Expanded shared content shows status chips for empty/error hosts, host labels on cards and terminal-only remote question copy, with no Allow/Deny/answer controls.
- [ ] Native isolated-home checks cover host editing/error/empty states and both surface rendering paths. Real SSH tests use generated local keys/sshd/config and the actual stream executable; assert reconnect after drop and no owned process after removal/shutdown. Actual user SSH/agent files stay unchanged.
- [ ] Run Mac `swift build`, full `swift test`, `make app`, strict codesign and diff checks; run Linux core tests/product build/CLI smoke. Use independent Spec and Standards reviews against base10a8b70, fix findings and rerun affected verification.
- [ ] Commit/push, create PR closing261 with exact validation/limits, inspect checks, merge expected full tested head, verify closed issue and update265.
- [ ] Final separate documentation/roadmap PR reconciles265/92, README/architecture, website roadmap/LLM pages and both implementation-plan completion records. Run website build/tests. Do not publish a release or claim these master-only features are in the current download.
