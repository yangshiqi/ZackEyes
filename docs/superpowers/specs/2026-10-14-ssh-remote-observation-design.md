# SSH remote observation (#261)

Status: approved by the user on 2026-10-14. Part of #265; implement after #263 as a separate feature/PR. No remote approval channel is included.

## Intent and architectural choice

Watch Claude/Codex on configured SSH hosts in the existing native panel, with host identity and live/error connection state. The remote side runs only for the lifetime of an SSH connection: no daemon, remote listening port, hook installation or remote configuration edits.

The issue proposes a headless `zackeyes --stream` producing JSON lines. Adopt that approach rather than periodically spawning SSH once per session or forwarding the Bridge socket. The Mac maintains one long-lived SSH process per enabled host. This avoids per-session connection overhead and keeps all remote sessions read-only.

## Headless product and protocol

Add a `zackeyes-stream` executable product and a small Foundation-only stream library, independently buildable with `swift build -c release --product zackeyes-stream` on macOS and Linux. Install that binary as `~/.local/bin/zackeyes` on the remote host, providing the requested `zackeyes --stream` command. The build artifact must have a distinct name from the existing AppKit executable `ZackEyes`: names differing only by case collide on default macOS filesystems and would break `make app`. The new core must not depend on AppLib or pull the macOS-only Shared file-sync implementation into a Linux build. The wire DTO uses the existing session/agent concepts and is adapted into `SessionInfo` on the Mac; it does not serialize the UI model's closures or arbitrary tool inputs.

`zackeyes --stream` scans the user's local Claude projects and Codex sessions, immediately emits a complete snapshot and then emits periodic snapshots/heartbeats (5 seconds). Read bounded transcript tails and metadata with regular-file/symlink/size checks and an unchanged-file cache. Discover recently touched transcripts using the established per-agent windows (8h Claude, 30min Codex); explicitly label these as observed recent sessions, not proof that a remote PID is still alive. Extract genuine state transitions where recorded: user/task start and tool activity imply working, turn completion implies idle, explicit user-question events imply waiting. Unknown state must not invent a pending permission. A transcript snapshot cannot infer that an arbitrary tool call is awaiting permission.

Each newline-delimited frame contains protocol version 1, an observation timestamp and the complete sessions array. Session fields are bounded opaque ID, agent, project/cwd metadata, observed state, last activity, model and current tool name. Do not send prompts/replies, tool arguments/results, local PIDs, permission responders, secret files or account credentials. Empty snapshots authoritatively remove that host's sessions. stdout is protocol-only; CLI argument/I/O failures may report a short message to stderr. Exit cleanly on SSH disconnect/broken pipe and signals.

Limit each frame to 1 MiB and 256 sessions, validate enum/numeric/string/date fields and duplicate IDs before applying atomically, and reject unsupported versions. Bound the line buffer even if no newline arrives. A malformed/oversized stream transitions the host to error and triggers bounded reconnection rather than growing memory or partially applying a snapshot.

## SSH lifecycle and configuration

Use `/usr/bin/ssh` with argument arrays, no local shell, `-T`, BatchMode, public-key authentication only, StrictHostKeyChecking=yes, UpdateHostKeys=no, ControlMaster=no/ControlPath=none, connection timeout and server-alive probes. Never accept unknown host keys automatically, open password dialogs, edit ssh config/known_hosts, or write agent config. Normal SSH agent/key configuration and pre-established known_hosts entries remain the user's responsibility.

Store up to eight named hosts in an app-owned `~/.zackeyes/remote-hosts.json`, separate from agent configs and the existing Settings wrapper. Validate destination/alias syntax, reject option-like or control-character input, and persist stable host UUIDs with AtomicFileWriter. The remote command is fixed to `exec "$HOME/.local/bin/zackeyes" --stream`; documentation covers installing the binary there and testing key authentication. No arbitrary remote command field is needed for this first version.

One connection task owns each host's process, stdout reader, bounded stderr drain and reconnect timer. EOF, authentication failure, stale heartbeat or protocol error stops the current attempt, clears that host's current session snapshot, records a useful bounded error and reconnects with exponential delay capped at 60 seconds. A successful snapshot resets backoff. Generation/cancellation checks reject callbacks from superseded attempts. Host edit/removal/disable and app quit cancel timers, close pipes and terminate the owned process; re-enabling starts exactly one new attempt. No external persistent process survives app shutdown.

## App and UI boundary

Settings gains Remote Hosts with add/edit/remove, an enable toggle and connection/error state. Shared expanded content shows host chips even when a host has zero sessions, so failures remain visible. Session cards include host identity; equal local/remote IDs and equal project paths on different hosts remain distinct. Both notch surfaces and menu-bar fallback reflect remote activity and visibility changes. In When Active mode, an enabled host that is connecting, has observed sessions or has a connection error keeps the panel affordance visible even when there are no local sessions; connected hosts with empty snapshots do not keep it visible. Hidden suppresses remote-driven panel visibility and expansion even for remote session attention, with host state available through Settings/menu; existing local permission behavior is unchanged. Connection errors alone do not force expansion, chime or interrupt demo. Explicit remote session attention may stop demo; after exit restore Hidden when selected, otherwise expand the attention content. Add a zero-local-session/remote-disconnect acceptance case.

Adapt snapshots through one SessionStore API with explicit remote provenance and a host namespace; replacing a host affects only that host. Do not fabricate Bridge events or pending permissions. Add guards at the local liveness, port inspection, Git cwd and terminal-jump boundaries: remote PIDs/paths must never reach local subprocesses or AppleScript, and local sweeps must never evict remote cards. The current local SessionStore ingestion continues throughout. Remote waiting cards say to handle the request in the remote terminal and expose no Allow/Deny/answer controls. Aggregate waiting labels must distinguish remote attention from a locally answerable approval. Arrival of genuine remote attention can interrupt demo presentation without answering anything.

Remote snapshots do not update local quota readings, usage ledger or journal. Disconnect removes live cards and leaves the host error chip; reconnect replaces from the next complete snapshot. Demo remains a presentation-only local fixture and never opens SSH.

## Evidence found in the current code

- `Sources/ZackEyes/main.swift` unconditionally starts AppKit; a separate executable is required for headless/Linux use.
- `Sources/AppLib/Session/SessionScanner.swift` carries prompt/reply strings and lives in AppLib. Sending it directly would over-share content and link AppKit; use bounded metadata DTOs instead.
- `Sources/Shared/AtomicFileWriter.swift` uses `F_FULLFSYNC` without a Linux condition. Keep this dependency out of the stream core rather than changing config durability as incidental work.
- `AppDelegate.runLivenessSweep`, `SessionStore.portScanRoots`, `GitStatusReader.scanCwds` and `NotchViewModel.activateTerminal` operate on local process/path identities. Explicit provenance guards are required before introducing remote SessionInfo values.

## Verification and completion

Fixture tests cover both transcript formats, observation windows, state inference, no prompt/credential serialization, frame limits/partial lines/unknown versions, empty and duplicate snapshots, host collisions, local inspection/action isolation, config preservation/invalid input, zero-session/error-only When Active visibility, Hidden plus remote attention/demo interruption, no expansion on connection errors, one process per host, bounded stderr, retry backoff, generation cancellation, heartbeat timeout and teardown. Use fake transports for deterministic lifecycle tests, then a real key-based SSH round trip to an isolated test host (including disconnect/reconnect and removal). Validate the actual headless executable emits repeated valid snapshots and exits when its consumer disappears.

Build/test the stream product on Linux as well as macOS; build/test all existing macOS targets, `make app` and signing; verify native host Settings and both surface paths without focus regressions using an isolated home. Do independent specification/standards review, fix findings, create and merge a PR closing #261, then reconcile #265 and #92 plus README/architecture/website roadmap and LLM pages. Run website build/tests after content changes. No version bump or public release is implied.
