# Demo mode with a synthetic fleet (#262)

Status: draft for user review. No implementation has started.

Origin: [#262](https://github.com/yangshiqi/ZackEyes/issues/262), under [tracking issue #265](https://github.com/yangshiqi/ZackEyes/issues/265). #262 explicitly asks that demo mode be built first. #260 is implemented and merged in PR #266.

## Goal

Show the existing macOS session interface without running an agent: clearly marked sample Claude/Codex sessions transition through working, needs-you and idle. Starting and exiting the demo each take one action. Use the existing notch and simulated-notch components.

## Scope and entry points

- Add a checked `Demo mode` item to the shared status/gear menu. It toggles the current app's demo presentation and remains reachable when the notch is hidden.
- Honor `--demo` when starting a new app process; an already running app uses the existing single-instance policy and the menu entry.
- The expanded session panel shows `Demo sessions` and an `Exit demo` button. Each synthetic card and the compact presentation carry a visible `DEMO` cue.
- Demo state is ephemeral. Relaunch without `--demo` returns to the real session presentation.
- Global quota readings continue to come from their existing live sources. This feature demonstrates session state and per-session metadata; it does not invent account quota/history data.
- SSH monitoring, the historical usage ledger and stale-quota prefixes are separate issues and are not part of this change.

## Approaches considered

1. **Recommended: isolated demo store at the presentation boundary.** A controller owns a separate in-memory SessionStore. Views can present it while AppDelegate continues receiving real events into its original store. Exiting switches presentation back to the current real state.
2. Inject synthetic hook events into the live store. This has fewer initial UI changes, but mixes fake entries with liveness, notifications, scanner imports and real approvals. It makes cleanup depend on every live ingestion path respecting a fake-ID convention.
3. Build a separate demo-only interface. This avoids affecting live data but does not exercise the actual UI used for screenshots or development and duplicates layout behavior.

## Data ownership and integration

`AppDelegate.sessionStore` stays the live ingestion destination for SocketServer, scanner, liveness sweeps and Codex tailer callbacks. No fixture is routed through AppDelegate.handleEvent or the Bridge.

Add a small `@MainActor DemoSessionController` that owns its synthetic SessionStore, active state and one cancellable cycle task. Its fixture builder takes an explicit date, and its phase advancement is callable without waiting for a timer so tests can cover actual state transitions deterministically.

`NotchViewModel` keeps its existing real `sessionStore` reference and exposes a separate `presentationStore`. That property selects the demo controller's store only while demo is active. Compact cards, expanded grouping, controller presentation checks and aggregate session text read the presentation store. Ingestion continues to use the original real store.

Forward changes from both stores and demo state through the view model. MenuBarFallback subscribes to the view model's forwarded changes rather than binding permanently to the originally selected store.

Add `SessionSource.demo` for explicit provenance. Synthetic session IDs have a dedicated prefix as a diagnostic aid, but action isolation checks the actual demo-store entry and source rather than trusting a string prefix.

## Scripted fleet and behavior

Seed four stable sample projects, using only fictitious task text and paths:

| Project | Agent | Initial state | Content |
| --- | --- | --- | --- |
| Storefront | Claude | Working | A tool operation, context percentage and model/effort metadata |
| API | Codex | Working | Tool/task progress and model/effort metadata |
| Docs | Claude | Needs you | A simulated permission request, later a simple choice question |
| Tests | Codex | Idle | A short completion recap and illustrative session token/cost data |

Rotate the scenarios every six seconds so a user sees transitions within ten seconds. Keep at least one working, one needs-you and one idle example visible across the main phases. Re-entering starts from the same initial fixture state.

Allow/Deny and question selections update only the corresponding synthetic request and session. They never approve a real request, invoke a CLI or write a response to a socket. Card/terminal actions for demo sessions do not perform PID discovery, AppleScript activation, Git inspection or terminal title writes. The compact/expanded DEMO cues identify the illustrative metadata as sample data.

On exit, cancel the cycle task, clear the demo queue and discard the synthetic store's entries. A cancelled or previous-generation callback cannot repopulate the demo after exit or a subsequent restart.

## Real attention during a demo

Starting the demo is unavailable while the real store has a question, permission request, waiting state or surfaced error requiring attention. If real attention arrives during a demo, exit demo presentation and show that real state using the existing expansion behavior. Ordinary real work continues to update in the background and is immediately visible when the user exits.

Demo transitions generate no system notifications, completion chimes, usage cache writes or journal entries. Real events retain their existing behavior.

## Panel behavior

Start demo expands the active real-notch or simulated-notch surface through AppDelegate's existing controller hooks. It does not persist a visibility change or replace NSPanel style/collection behavior. Exit restores presentation and reapplies the current visibility preference against the actual live session count. A hidden panel can always exit via the shared menu.

## Planned file boundaries

- New `Sources/AppLib/Session/DemoSessionController.swift`: fixtures, in-memory store, phases and task lifecycle.
- `Sources/AppLib/Session/SessionStore.swift`: the `.demo` source marker only; real event/liveness handling stays in the existing store.
- `Sources/AppLib/Notch/NotchViewModel.swift`: presentation selection, forwarded observation and routing of demo actions.
- `Sources/AppLib/Notch/NotchExpandedView.swift`, `NotchCompactView.swift`, `SimulatedNotchView.swift`: shared banner/exit, card badges and compact DEMO cue.
- `Sources/AppLib/MenuBar/MenuBarFallback.swift`, `StatusBarMenu.swift`: observe presentation changes and expose the mode toggle.
- `Sources/AppLib/Notch/NotchWindowController.swift`, `Sources/AppLib/SimulatedNotch/SimulatedNotchController.swift`: presentation-based checks and restoration of visibility.
- `Sources/ZackEyes/AppDelegate.swift`: controller/menu wiring, `--demo` startup, real-attention handoff and teardown.
- New `Tests/AppLibTests/DemoSessionControllerTests.swift` and `DemoPresentationTests.swift`: transitions, actions, observation and isolation.
- `ARCHITECTURE.md` and README: ownership, entry points and ephemeral behavior.

## Acceptance and verification

1. With no agents running, demo immediately displays clearly marked Claude and Codex samples in the existing grouped UI.
2. Within ten seconds, users see a state transition. The fixture/date-driven tests assert working, needs-you and idle phases without real six-second waits.
3. Menu toggle and expanded `Exit demo` each stop the demo in one action; repeated start/stop does not create duplicate timers or fixtures.
4. A real session created or updated during demo survives with its latest state after exit. A real permission/question interrupts demo and remains answerable exactly once.
5. Synthetic Allow/Deny/Submit affect only the displayed fake request; clicking a fake card performs no terminal or process operation.
6. Fake data does not enter the real session store, quota persistence, notifications or journal collectors.
7. Enter/exit and cancelled callback tests verify no stale phase can resurrect demo data. View-model/menu observation sees demo transitions and exit.
8. `swift build`, full `swift test`, `make app`, and deep strict codesign verification pass.
9. Manually exercise the existing simulated-notch UI with isolated config, verify visible DEMO cues, interactive sample choices, one-click exit, real-attention handoff, visibility restoration and no focus theft. Physical-notch behavior shares the presentation but remains separately reported if hardware is unavailable.

No user hooks/config files need changes for demo mode. Bridge is unaffected; its silent exit-0 contract and the prohibition on reading or writing Codex config.toml continue to apply.
