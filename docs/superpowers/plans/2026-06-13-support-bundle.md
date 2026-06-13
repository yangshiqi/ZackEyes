# Privacy-Redacted Support Bundle (#47) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A user-initiated "Export Diagnostics…" that assembles a human-readable, privacy-redacted diagnostic report (app/OS/arch + hook health + launcher + socket + usage freshness), shows it in a review window so the user sees exactly what they'd share, and offers Copy / Save (GitHub issue #47).

**Architecture:** `Redactor` (pure path/username scrubbing helpers — the testable core per the acceptance criteria). `DiagnosticsReport` with a pure `generate(...)` taking already-gathered values → redacted plain-text string, plus a thin `current(usageSnapshot:)` that gathers `HookHealth().check()` (reuses #38) + `Bundle`/`ProcessInfo` and calls generate. `DiagnosticsWindow` (KeyablePanel pattern, like HookStatusWindow) renders the redacted text in a scrollable view with Copy / Save… / Close — showing it BEFORE sharing is the privacy guarantee made visible. Menu item "Export Diagnostics…" in both menus' maintenance block. No log-capture subsystem: the issue's last bullet is "recent redacted app logs OR structured diagnostic events" — the structured snapshot satisfies the OR, so OSLogStore/ring-buffer is deliberately not built (over-engineering for the stated need).

**Branch:** `feat/47-support-bundle` off `1bad82a` (worktree; baseline 291 Swift Testing + XCTest green).

**Privacy invariants:** NEVER emit prompt text, assistant text, tool/command arguments, or full config-file contents. Redact home dir → `~` and the macOS username → `<user>` in every path-bearing field (launcher paths, the statusLine `thirdParty(command:)` string). User-initiated only — no auto-export, no network. The report is assembled from already-public-to-the-user state (versions, health booleans, usage timestamps).

---

## File Structure

| File | Action | Responsibility |
|------|--------|----------------|
| `Sources/AppLib/Diagnostics/Redactor.swift` | Create | pure `redactPath` / `redact` helpers (home→`~`, user→`<user>`) |
| `Sources/AppLib/Diagnostics/DiagnosticsReport.swift` | Create | `generate(...)` pure assembler + `current(usageSnapshot:)` gatherer |
| `Sources/AppLib/MenuBar/DiagnosticsWindow.swift` | Create | review window (scroll text + Copy / Save… / Close) |
| `Sources/AppLib/MenuBar/StatusBarMenu.swift` | Modify | inject `usageTracker`; "Export Diagnostics…" item + handler |
| `Sources/AppLib/SimulatedNotch/GearMenuTarget.swift` | Modify | `exportDiagnosticsClicked` handler (has `usageTracker` already) |
| `Sources/AppLib/SimulatedNotch/SimulatedNotchFullView.swift` | Modify | gear "Export Diagnostics…" item |
| `Sources/ZackEyes/AppDelegate.swift` | Modify | pass `usageTracker` into StatusBarMenu init |
| `Tests/AppLibTests/RedactorTests.swift` | Create | redaction helper coverage |
| `Tests/AppLibTests/DiagnosticsReportTests.swift` | Create | structure + redaction-applied + no-sensitive-fields |
| `ARCHITECTURE.md` | Modify | Diagnostics module rows |

---

### Task 1: Redactor (pure helpers + tests)

**Files:** create `Sources/AppLib/Diagnostics/Redactor.swift` + `Tests/AppLibTests/RedactorTests.swift`.

- [ ] **Step 1.1 failing tests** — `RedactorTests.swift` (Swift Testing):

```swift
import Testing
import Foundation
@testable import AppLib

struct RedactorTests {

    @Test func redactsHomeDirectoryPrefixToTilde() {
        let home = "/Users/alice"
        let r = Redactor(homeDirectory: home, username: "alice")
        #expect(r.redact("/Users/alice/.zackeyes/bin/bridge") == "~/.zackeyes/bin/bridge")
    }

    @Test func redactsBareUsernameOccurrences() {
        let r = Redactor(homeDirectory: "/Users/alice", username: "alice")
        // username appearing outside the home prefix (e.g. inside a 3rd-party cmd)
        #expect(r.redact("/opt/tools/alice-helper --user alice")
            == "/opt/tools/<user>-helper --user <user>")
    }

    @Test func homePrefixTakesPrecedenceOverBareUsername() {
        let r = Redactor(homeDirectory: "/Users/alice", username: "alice")
        // The home prefix collapses to ~ first; no leftover bare "alice".
        #expect(r.redact("/Users/alice/projects/alice-app")
            == "~/projects/<user>-app")
    }

    @Test func leavesUnrelatedTextUntouched() {
        let r = Redactor(homeDirectory: "/Users/alice", username: "alice")
        #expect(r.redact("socket reachable; statusLine: direct")
            == "socket reachable; statusLine: direct")
    }

    @Test func handlesEmptyAndNilGracefully() {
        let r = Redactor(homeDirectory: "/Users/alice", username: "alice")
        #expect(r.redact("") == "")
        #expect(r.redactOptional(nil) == nil)
        #expect(r.redactOptional("/Users/alice/x") == "~/x")
    }

    @Test func shortOrEmptyUsernameDoesNotCorruptOutput() {
        // Guard against a pathological empty username turning every char into <user>.
        let r = Redactor(homeDirectory: "/Users/", username: "")
        #expect(r.redact("/Users/bob/file") == "/Users/bob/file")
    }
}
```

- [ ] **Step 1.2** run `swift test --filter RedactorTests 2>&1 | tail -8` → compile FAIL.

- [ ] **Step 1.3 implement** — `Redactor.swift`:

```swift
import Foundation

/// Pure, user-config-zero-touch text scrubbing for the diagnostics export
/// (#47). Collapses the home directory to `~` and replaces the macOS
/// username with `<user>` so a report is safe to attach to a public issue.
/// No I/O — values are injected so this is fully testable.
public struct Redactor: Sendable {

    private let homeDirectory: String
    private let username: String

    public init(
        homeDirectory: String = NSHomeDirectory(),
        username: String = NSUserName()
    ) {
        self.homeDirectory = homeDirectory
        self.username = username
    }

    /// Redact a string: home-dir prefix → `~`, then any remaining bare
    /// username occurrences → `<user>`. Order matters — the home collapse
    /// runs first so `/Users/<user>/...` becomes `~/...` rather than
    /// `/Users/<user>/...` with a dangling redaction.
    public func redact(_ text: String) -> String {
        var out = text
        if !homeDirectory.isEmpty {
            out = out.replacingOccurrences(of: homeDirectory, with: "~")
        }
        // Empty username would replace between every character — guard it.
        if !username.isEmpty {
            out = out.replacingOccurrences(of: username, with: "<user>")
        }
        return out
    }

    public func redactOptional(_ text: String?) -> String? {
        guard let text else { return nil }
        return redact(text)
    }
}
```

- [ ] **Step 1.4** `swift test 2>&1 | tail -3` → 291 Swift Testing + the 6 new RedactorTests pass.

- [ ] **Step 1.5 commit** `feat(diagnostics): add Redactor for path/username scrubbing`

---

### Task 2: DiagnosticsReport assembler

**Files:** create `Sources/AppLib/Diagnostics/DiagnosticsReport.swift` + `Tests/AppLibTests/DiagnosticsReportTests.swift`.

- [ ] **Step 2.1 failing tests** — `DiagnosticsReportTests.swift`. The pure `generate` takes a `HookHealthReport`, a `UsageTracker.Snapshot`, version/os/arch strings, and a `Redactor`:

```swift
import Testing
import Foundation
@testable import AppLib

struct DiagnosticsReportTests {

    private func sampleHealth(statusLine: HookHealthReport.StatusLineMode = .direct)
        -> HookHealthReport {
        HookHealthReport(
            claudeHooks: .installed,
            codexHooks: .notInstalled,
            bridgeLauncher: true,
            launcherResolvesApp: true,
            socketReachable: true,
            statusLine: statusLine
        )
    }

    private func sampleUsage(lastUpdated: Date?) -> UsageTracker.Snapshot {
        var s = UsageTracker.Snapshot.empty
        s.fiveHourUsedPct = 34
        s.lastUpdated = lastUpdated
        return s
    }

    private let redactor = Redactor(homeDirectory: "/Users/alice", username: "alice")

    @Test func reportContainsCoreSections() {
        let text = DiagnosticsReport.generate(
            health: sampleHealth(),
            usage: sampleUsage(lastUpdated: Date(timeIntervalSince1970: 1_700_000_000)),
            appVersion: "0.7.0",
            osVersion: "15.3.2",
            arch: "arm64",
            redactor: redactor,
            now: Date(timeIntervalSince1970: 1_700_000_060)
        )
        // Human-readable headers present
        #expect(text.contains("ZackEyes Diagnostics"))
        #expect(text.contains("App version: 0.7.0"))
        #expect(text.contains("macOS: 15.3.2"))
        #expect(text.contains("Architecture: arm64"))
        #expect(text.contains("Claude hooks: installed"))
        #expect(text.contains("Codex hooks: not installed"))
        #expect(text.contains("Bridge launcher: ok"))
        #expect(text.contains("Launcher resolves app: ok"))
        #expect(text.contains("Socket: reachable"))
        #expect(text.contains("statusLine: direct"))
        // usage freshness present (age, not raw prompt content)
        #expect(text.contains("Usage last updated:"))
    }

    @Test func reportRedactsThirdPartyStatusLinePath() {
        let text = DiagnosticsReport.generate(
            health: sampleHealth(statusLine: .thirdParty(
                command: "/Users/alice/.local/bin/hud --user alice")),
            usage: sampleUsage(lastUpdated: nil),
            appVersion: "0.7.0", osVersion: "15.3.2", arch: "arm64",
            redactor: redactor, now: Date(timeIntervalSince1970: 1_700_000_060)
        )
        #expect(text.contains("~/.local/bin/hud --user <user>"))
        #expect(!text.contains("/Users/alice"))
        #expect(!text.contains("alice"))
    }

    @Test func reportNeverContainsSensitiveLabels() {
        let text = DiagnosticsReport.generate(
            health: sampleHealth(),
            usage: sampleUsage(lastUpdated: Date(timeIntervalSince1970: 1_700_000_000)),
            appVersion: "0.7.0", osVersion: "15.3.2", arch: "arm64",
            redactor: redactor, now: Date(timeIntervalSince1970: 1_700_000_060)
        )
        // Sanity: report is a fixed-schema summary, so it must not carry
        // free-form prompt/assistant/tool-arg fields. These keys must be absent.
        #expect(!text.lowercased().contains("prompt"))
        #expect(!text.lowercased().contains("assistant"))
        #expect(!text.lowercased().contains("tool_input"))
    }

    @Test func usageMissingReportedAsNeverUpdated() {
        let text = DiagnosticsReport.generate(
            health: sampleHealth(),
            usage: sampleUsage(lastUpdated: nil),
            appVersion: "0.7.0", osVersion: "15.3.2", arch: "arm64",
            redactor: redactor, now: Date(timeIntervalSince1970: 1_700_000_060)
        )
        #expect(text.contains("Usage last updated: never"))
    }

    @Test func unreadableHookConfigSurfacedNotCrashed() {
        let text = DiagnosticsReport.generate(
            health: sampleHealth(),  // tweak below
            usage: sampleUsage(lastUpdated: nil),
            appVersion: "0.7.0", osVersion: "15.3.2", arch: "arm64",
            redactor: redactor, now: Date(timeIntervalSince1970: 1_700_000_060)
        )
        _ = text  // smoke: generate must not throw/crash on any health state
        let unreadable = DiagnosticsReport.generate(
            health: HookHealthReport(
                claudeHooks: .unreadable, codexHooks: .partial(missing: ["Stop"]),
                bridgeLauncher: false, launcherResolvesApp: false,
                socketReachable: false, statusLine: .unreadable),
            usage: sampleUsage(lastUpdated: nil),
            appVersion: "0.7.0", osVersion: "15.3.2", arch: "arm64",
            redactor: redactor, now: Date(timeIntervalSince1970: 1_700_000_060))
        #expect(unreadable.contains("Claude hooks: config unreadable"))
        #expect(unreadable.contains("Codex hooks: missing 1 event"))
        #expect(unreadable.contains("Bridge launcher: MISSING"))
        #expect(unreadable.contains("statusLine: unreadable"))
    }
}
```

VERIFY first: `UsageTracker.Snapshot.empty` exists and is the right zero value (it does — `:60` area), and `HookHealthReport`'s memberwise init is accessible from tests (`@testable`). Adapt field names if the real `Snapshot` differs.

- [ ] **Step 2.2** run → compile FAIL.

- [ ] **Step 2.3 implement** — `DiagnosticsReport.swift`:

```swift
import Foundation

/// Assembles a privacy-redacted, human-readable diagnostics report (#47).
/// `generate` is pure (all inputs injected) so it's fully testable; `current`
/// is the thin gatherer that reads live state. NEVER emits prompt/assistant/
/// tool-argument text or full config contents — it's a fixed-schema summary
/// of health booleans, versions, and usage timestamps, all run through the
/// `Redactor`.
public enum DiagnosticsReport {

    public static func generate(
        health: HookHealthReport,
        usage: UsageTracker.Snapshot,
        appVersion: String,
        osVersion: String,
        arch: String,
        redactor: Redactor,
        now: Date
    ) -> String {
        var lines: [String] = []
        lines.append("ZackEyes Diagnostics")
        lines.append("====================")
        lines.append("App version: \(appVersion)")
        lines.append("macOS: \(osVersion)")
        lines.append("Architecture: \(arch)")
        lines.append("")
        lines.append("Hooks")
        lines.append("-----")
        lines.append("Claude hooks: \(describe(health.claudeHooks))")
        lines.append("Codex hooks: \(describe(health.codexHooks))")
        lines.append("Bridge launcher: \(health.bridgeLauncher ? "ok" : "MISSING")")
        lines.append("Launcher resolves app: \(health.launcherResolvesApp ? "ok" : "MISMATCH")")
        lines.append("Socket: \(health.socketReachable ? "reachable" : "unreachable")")
        lines.append("statusLine: \(describe(health.statusLine, redactor: redactor))")
        lines.append("Overall: \(health.isHealthy ? "healthy" : "needs attention")")
        lines.append("")
        lines.append("Usage")
        lines.append("-----")
        lines.append("Usage last updated: \(freshness(usage.lastUpdated, now: now))")
        lines.append("Claude usage data: \(usage.hasClaudeData ? "present" : "none")")
        lines.append("Codex usage data: \(usage.hasCodexData ? "present" : "none")")
        return lines.joined(separator: "\n") + "\n"
    }

    /// Live gatherer. Reads HookHealth (real paths) + Bundle/ProcessInfo and
    /// the passed usage snapshot, then redacts. Caller supplies the snapshot
    /// so this stays free of the @MainActor UsageTracker dependency.
    @MainActor
    public static func current(usageSnapshot: UsageTracker.Snapshot) -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return generate(
            health: HookHealth().check(),
            usage: usageSnapshot,
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?",
            osVersion: "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)",
            arch: currentArch,
            redactor: Redactor(),
            now: Date()
        )
    }

    private static var currentArch: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    private static func describe(_ s: HookHealthReport.AgentHooksStatus) -> String {
        switch s {
        case .installed: return "installed"
        case .partial(let missing): return "missing \(missing.count) event\(missing.count == 1 ? "" : "s")"
        case .missing: return "not installed"
        case .notInstalled: return "not installed"
        case .unreadable: return "config unreadable"
        }
    }

    private static func describe(
        _ m: HookHealthReport.StatusLineMode, redactor: Redactor
    ) -> String {
        switch m {
        case .direct: return "direct"
        case .mux: return "mux"
        case .userRenderer: return "user renderer"
        case .thirdParty(let cmd): return "third-party: \(redactor.redact(cmd))"
        case .absent: return "not installed"
        case .unreadable: return "unreadable"
        }
    }

    private static func freshness(_ date: Date?, now: Date) -> String {
        guard let date else { return "never" }
        let secs = Int(now.timeIntervalSince(date))
        if secs < 60 { return "\(max(secs, 0))s ago" }
        if secs < 3600 { return "\(secs / 60)m ago" }
        if secs < 86400 { return "\(secs / 3600)h ago" }
        return "\(secs / 86400)d ago"
    }
}
```

Note: `.missing` and `.notInstalled` both render "not installed" — that's intentional for a user-facing summary (both mean "no ZackEyes hooks here"); the test only asserts the `.partial`/`.unreadable`/`.installed`/`.notInstalled` strings used in the fixtures. If a test distinguishes `.missing` vs `.notInstalled`, adjust the test, not the merge (flag it).

- [ ] **Step 2.4** `swift test 2>&1 | tail -3` → 291 + 6 Redactor + 5 DiagnosticsReport tests pass.

- [ ] **Step 2.5 commit** `feat(diagnostics): add redacted DiagnosticsReport assembler`

---

### Task 3: DiagnosticsWindow + menu wiring

**Files:** create `DiagnosticsWindow.swift`; modify StatusBarMenu, GearMenuTarget, SimulatedNotchFullView, AppDelegate.

- [ ] **Step 3.1 — DiagnosticsWindow** (clone the HookStatusWindow KeyablePanel shell: borderless+nonactivating, .floating, show-reuse, close-not-orderOut, nonisolated windowWillClose; size ~520×460 for a scrollable report). Root SwiftUI view:
  - A header "Diagnostics — safe to attach to a GitHub issue".
  - The redacted report text in a monospaced, selectable, scrollable view (`ScrollView { Text(report).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }`).
  - Buttons: **Copy** (`NSPasteboard.general.clearContents(); .setString(report, forType: .string)`), **Save…** (NSSavePanel → write `report` to chosen `.txt`; default name `zackeyes-diagnostics.txt`), **Close** (`.cancelAction`).
  - `onAppear` computes the report once: `report = makeReport()`.
  - Window init takes `makeReport: () -> String`. Wire as `{ DiagnosticsReport.current(usageSnapshot: usageTracker.snapshot) }`.

  NSSavePanel note: it's modal-ish but runs its own loop; call `panel.begin { ... }` (async, non-blocking) rather than `runModal()` to avoid starving the main actor — match the project's non-blocking-panel philosophy. Write with `try? report.data(using: .utf8)?.write(to: url)`.

- [ ] **Step 3.2 — StatusBarMenu**: add `private let usageTracker: UsageTracker`; add it to `init(updateChecker:downloader:usageTracker:)`; stored `private var diagnosticsWindow: DiagnosticsWindow?`; "Export Diagnostics…" item in the maintenance block (after "Check for Updates", before final separator); handler lazily creates + shows the window with the report closure.

- [ ] **Step 3.3 — AppDelegate**: pass `usageTracker` into the `StatusBarMenu(...)` construction (it already has `usageTracker` in scope — grep the existing `StatusBarMenu(updateChecker:` call site and add the arg).

- [ ] **Step 3.4 — GearMenuTarget + SimulatedNotchFullView**: `GearMenuTarget` gains `private var diagnosticsWindow: DiagnosticsWindow?` + `@objc func exportDiagnosticsClicked(_:)` (clear `isMenuOpen`; lazy-create + show with `{ DiagnosticsReport.current(usageSnapshot: self.usageTracker?.snapshot ?? .empty) }`). `SimulatedNotchFullView.popGearMenu`: "Export Diagnostics…" item in the maintenance block, same position, target `GearMenuTarget.shared`.

- [ ] **Step 3.5** final maintenance order BOTH menus: `Hook Status… | Uninstall Integrations… | Check for Updates | Export Diagnostics… | --- | Quit`.

- [ ] **Step 3.6** `swift build 2>&1 | tail -3` clean; `swift test 2>&1 | tail -3` → all green; `make app 2>&1 | tail -2` builds.

- [ ] **Step 3.7 commit** `feat(menubar): add Export Diagnostics window + menu items`

---

### Task 4: docs + ship

- [ ] **Step 4.1** ARCHITECTURE.md: new module rows for `Redactor` / `DiagnosticsReport` (a "Diagnostics" sub-table or fold into an existing section) + `DiagnosticsWindow` in the 菜单栏 fallback table. Note the privacy contract (fixed-schema summary, redacted, user-initiated, no prompt/config content). Commit plan + docs: `docs: document support-bundle diagnostics export (#47)`.
- [ ] **Step 4.2** Final whole-branch review (range `1bad82a..HEAD`).
- [ ] **Step 4.3** Push → PR (`Closes #47`; body: what's included, the privacy contract, the "logs OR structured events → structured satisfies the OR, log-capture subsystem deliberately not built" rationale, acceptance mapping). → bot dispositions → **PAUSE for user manual verification** (export from both menus; report is readable + contains no home path/username/prompt content; Copy + Save work) → squash-merge on user OK → tick #47 in #92 → **v0.7.0 milestone now fully done — flag to user that release-finish checklist applies** → memory.

---

## Self-Review Notes

- **Acceptance mapping:** "Export from Settings or menu" → both menu surfaces. "Human-readable + safe to attach" → plain-text fixed-schema summary shown in a review window before sharing. "Tests cover redaction helpers" → RedactorTests (6) + DiagnosticsReportTests asserting redaction applied to the statusLine third-party path.
- **Privacy by construction:** the report is a fixed set of booleans/enums/timestamps + versions — there is no code path that reads prompt/assistant/tool text into it. The only free-form string that enters is the statusLine third-party command, which is redacted. `reportNeverContainsSensitiveLabels` is a guard test.
- **Cut (flag in PR):** no OSLogStore / ring-buffer log capture — the issue's "recent logs OR structured events" is satisfied by the structured snapshot; building a log subsystem is over-engineering for the stated diagnostic needs (all named failure modes — hook drift, launcher, socket, usage freshness — are covered by the structured fields).
- **Reuse:** HookHealth (#38) supplies 4 of the 6 "Include" bullets for free — the report is mostly a redacted renderer over existing health data.
- **Save panel:** use async `begin {}` not `runModal()` — main-actor-friendly, consistent with AboutWindow/HookStatusWindow rationale.
- **v0.7.0 closeout:** #47 is the last open v0.7.0 issue — after merge, the milestone is empty → trigger the release-finish checklist conversation with the user (per memory [[release-finish-checklist]] / [[v060-scope-decisions]]).
