# Complete Integration Uninstall (#46) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A user-facing "Uninstall Integrations…" flow: preview exactly what will be removed → confirm → ZackEyes-owned hooks/statusLine/launcher/spool removed (third-party + user files preserved, every config write backed up) → app quits (GitHub issue #46).

**Architecture:** Data layer `IntegrationUninstaller` (AppLib/Hooks): read-only `preview()` reusing installer internals (`isZackEyesEntry`, `statusLineMode(of:)` — same anti-drift seam as HookHealth) + best-effort `execute()` composing the existing `uninstallHooks()` primitives plus removal of ZackEyes-generated files. Both `uninstallHooks()` gain backup-before-write + no-op skip (acceptance: "Every config write is backed up first" — install has it, uninstall currently doesn't). UI clones the HookStatusWindow KeyablePanel pattern; entry items in both menus. After cleanup the card explains the auto-reinstall semantics and quits the app (startup `HookRepair.run` would otherwise resurrect hooks on next tick of life).

**Removal set** (exists-check before listing): ZackEyes hook entries (claude 12 events / codex 6), owned statusLine (direct or mux — uninstall already restores the preserved third-party original), `<binDir>/bridge`, `<binDir>/statusline-mux`, `<zackDir>/.app-path`, `<zackDir>/.statusline-original`, `<zackDir>/pending/` (#89 spool). **Preserved:** `config.json`, `pricing-cache.json`, `<binDir>/statusline-user` (user-authored), all third-party hook/statusLine entries, `~/.codex/config.toml` never touched.

**Branch:** `feat/46-uninstall-cleanup` off `ab1a9d6` (worktree, baseline 280 green).

---

## File Structure

| File | Action | Responsibility |
|------|--------|----------------|
| `Sources/AppLib/Hooks/HookInstaller.swift` | Modify | `uninstallHooks()`: backup-before-write + no-op skip |
| `Sources/AppLib/Hooks/CodexHookInstaller.swift` | Modify | same |
| `Sources/AppLib/Hooks/IntegrationUninstaller.swift` | Create | `preview() -> Plan` (read-only) + `execute()` |
| `Sources/AppLib/MenuBar/UninstallWindow.swift` | Create | confirm card (preview list → Remove & Quit / Cancel → done state → quit) |
| `Sources/AppLib/MenuBar/StatusBarMenu.swift` | Modify | "Uninstall Integrations…" item + handler |
| `Sources/AppLib/SimulatedNotch/GearMenuTarget.swift` + `SimulatedNotchFullView.swift` | Modify | gear-menu entry |
| `Tests/AppLibTests/HookInstallerTests.swift` / `CodexHookInstallerTests.swift` | Modify | uninstall backup/no-op tests |
| `Tests/AppLibTests/IntegrationUninstallerTests.swift` | Create | preview accuracy + mixed-config preservation + file selectivity + idempotence |
| `ARCHITECTURE.md` | Modify | module rows; 安全模型 note |

---

### Task 1: uninstallHooks backup + no-op skip (both installers)

**Files:** the two installers + their two test files.

- [ ] **Step 1.1 failing tests** — append to `HookInstallerTests`:

```swift
    // MARK: - #46 uninstall backup + no-op

    @Test func uninstallBacksUpBeforeWrite() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let claudeDir = tmpDir.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        let settingsURL = claudeDir.appendingPathComponent("settings.json")
        let installer = HookInstaller(
            settingsPath: settingsURL.path,
            bridgePath: tmpDir.appendingPathComponent(".zackeyes/bin/bridge").path)
        try installer.installHooks()
        // Clear install-time backups so the assertion isolates uninstall.
        for name in try backupFiles(in: claudeDir) {
            try FileManager.default.removeItem(at: claudeDir.appendingPathComponent(name))
        }

        try installer.uninstallHooks()

        #expect(try backupFiles(in: claudeDir).count == 1)
        let doc = try JSONSerialization.jsonObject(
            with: Data(contentsOf: settingsURL)) as! [String: Any]
        #expect(doc["hooks"] == nil)
    }

    @Test func uninstallOnCleanConfigIsNoOpWithoutBackup() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let claudeDir = tmpDir.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        let settingsURL = claudeDir.appendingPathComponent("settings.json")
        try #"{"permissions":{"allow":["Bash"]}}"#
            .write(to: settingsURL, atomically: true, encoding: .utf8)
        let installer = HookInstaller(
            settingsPath: settingsURL.path,
            bridgePath: tmpDir.appendingPathComponent(".zackeyes/bin/bridge").path)

        try installer.uninstallHooks()   // nothing of ours present

        #expect(try backupFiles(in: claudeDir).isEmpty)
    }
```

Mirror ONE codex test in `CodexHookInstallerTests` (`uninstallBacksUpBeforeWrite` — install, clear backups, uninstall, expect 1 `hooks.json.backup.*`; note: codex uninstall DELETES the file when the doc becomes empty — assert the backup exists AND `hooks.json` is gone, matching existing `uninstall` test expectations; READ the existing codex uninstall tests first to mirror their end-state assertions).

- [ ] **Step 1.2** run → backup tests FAIL (no backup written today). Confirm.
- [ ] **Step 1.3 implement** — in BOTH `uninstallHooks()`: capture `originalData`/`originalSettings` at parse time; after mutation compute the no-op guard `NSDictionary(dictionary: result).isEqual(to: original) → return` BEFORE any write/delete; otherwise write timestamped backup (`settings.json.backup.<epoch>` / `hooks.json.backup.<epoch>`) then write (or, codex empty-doc case: backup then delete file). Mirror the exact structure `installHooks()` got in #38 Task 4. ⚠️ The claude path's mux-restore branch (`readMuxOriginalCommand` → restore + `cleanupStatusLineMuxFiles`) mutates the dict and ALSO deletes mux files — keep file cleanup AFTER the no-op guard so a true no-op touches nothing.
- [ ] **Step 1.4** full suite → 280 + 3 = 283 pass (existing uninstall tests must stay green — they assert end-state contents, unaffected by added backups).
- [ ] **Step 1.5 commit** `feat(hooks): back up configs before uninstall writes`

---

### Task 2: IntegrationUninstaller

**Files:** create `Sources/AppLib/Hooks/IntegrationUninstaller.swift` + `Tests/AppLibTests/IntegrationUninstallerTests.swift`.

- [ ] **Step 2.1 failing tests** (hermetic tmp-dir fixtures, build real state with the real installers — same approach as HookHealthTests; read that file's helpers first):

Test list (write all six):
1. `previewListsOwnedEntriesAndFiles` — full install (claude+codex) + deploy launcher via `deployLauncherScript(appPath:)` + create `pending/` with one file → preview: `claudeHookEvents == 12`, `claudeOwnsStatusLine == true`, `codexHookEvents == 6`, `files` contains bridge + .app-path + pending dir paths (sorted), does NOT contain `statusline-user` even when present (create an executable one to prove it).
2. `previewOnCleanMachineIsEmpty` — empty tmp → all zeros/false/empty files.
3. `executeRemovesOursPreservesThirdParty` — mixed fixture (third-party hook entries on every event + ours; third-party statusLine wrapped by our mux with `.statusline-original`) → execute → third-party entries intact on all events, statusLine restored to the original third-party command, our files gone, `statusline-user` SURVIVES, `config.json` (create one) SURVIVES.
4. `executeIsIdempotent` — second execute: no error, no new backups (count unchanged), state unchanged.
5. `executeBacksUpConfigs` — after fixture install + clearing backups, execute → exactly one settings backup + one hooks backup.
6. `previewMatchesExecuteScope` — after execute, preview returns empty (zeros/empty files).

- [ ] **Step 2.2** run → compile FAIL.
- [ ] **Step 2.3 implement**:

```swift
import Foundation

/// #46 — complete integration cleanup. `preview()` is strictly read-only
/// (same probe seam as HookHealth: the installers' own detection internals,
/// so the preview can't drift from what execute() removes). `execute()`
/// composes the existing uninstall primitives — every config write is backed
/// up inside uninstallHooks() — plus removal of ZackEyes-generated files.
///
/// Never touched: user config keys, third-party hook/statusLine entries,
/// `config.json`, `pricing-cache.json`, the user-authored `statusline-user`,
/// and `~/.codex/config.toml` (never read nor written, invariant #1).
public struct IntegrationUninstaller {

    public struct Plan: Equatable, Sendable {
        /// Claude hook events carrying a ZackEyes entry (0–12).
        public let claudeHookEvents: Int
        /// We own the statusLine slot (direct or via mux).
        public let claudeOwnsStatusLine: Bool
        /// Codex hook events carrying a ZackEyes entry (0–6).
        public let codexHookEvents: Int
        /// Absolute paths of ZackEyes-generated files that exist now.
        public let files: [String]

        public var isEmpty: Bool {
            claudeHookEvents == 0 && !claudeOwnsStatusLine
                && codexHookEvents == 0 && files.isEmpty
        }
    }

    private let claudeSettingsPath: String
    private let codexHooksPath: String
    private let bridgePath: String

    public init(
        claudeSettingsPath: String = NSHomeDirectory() + "/.claude/settings.json",
        codexHooksPath: String = NSHomeDirectory() + "/.codex/hooks.json",
        bridgePath: String = "$HOME/.zackeyes/bin/bridge"
    ) {
        self.claudeSettingsPath = claudeSettingsPath
        self.codexHooksPath = codexHooksPath
        self.bridgePath = bridgePath
    }

    private var expandedBridgePath: String {
        bridgePath.replacingOccurrences(of: "$HOME", with: NSHomeDirectory())
    }
    private var binDir: String { (expandedBridgePath as NSString).deletingLastPathComponent }
    private var zackDir: String { (binDir as NSString).deletingLastPathComponent }

    /// ZackEyes-generated artifacts, in display order. `statusline-user` is
    /// deliberately absent — user-authored, never ours to delete.
    private var candidateFiles: [String] {
        [
            expandedBridgePath,
            binDir + "/statusline-mux",
            zackDir + "/.app-path",
            zackDir + "/.statusline-original",
            zackDir + "/pending",
        ]
    }

    // MARK: - Preview (read-only)

    public func preview() -> Plan {
        let claudeInstaller = HookInstaller(
            settingsPath: claudeSettingsPath, bridgePath: bridgePath)
        let codexInstaller = CodexHookInstaller(
            hooksPath: codexHooksPath, bridgePath: bridgePath)

        let claudeDoc = load(claudeSettingsPath)
        let codexDoc = load(codexHooksPath)

        let statusLineCommand =
            (claudeDoc?["statusLine"] as? [String: Any])?["command"] as? String
        let ownsStatusLine: Bool
        switch claudeInstaller.statusLineMode(of: statusLineCommand) {
        case .direct, .mux, .userRenderer: ownsStatusLine = true
        case .thirdParty, .absent, .unreadable: ownsStatusLine = false
        }

        return Plan(
            claudeHookEvents: ownedEventCount(
                in: claudeDoc, events: HookInstaller.hookEvents,
                isOurs: claudeInstaller.isZackEyesEntry),
            claudeOwnsStatusLine: ownsStatusLine,
            codexHookEvents: ownedEventCount(
                in: codexDoc, events: CodexHookInstaller.hookEvents,
                isOurs: codexInstaller.isZackEyesEntry),
            files: candidateFiles.filter { FileManager.default.fileExists(atPath: $0) }
        )
    }

    private func load(_ path: String) -> [String: Any]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func ownedEventCount(
        in doc: [String: Any]?, events: [String], isOurs: ([String: Any]) -> Bool
    ) -> Int {
        guard let hooks = doc?["hooks"] as? [String: Any] else { return 0 }
        return events.filter { event in
            ((hooks[event] as? [[String: Any]]) ?? []).contains(where: isOurs)
        }.count
    }

    // MARK: - Execute

    /// Best-effort: each step independent, errors logged not thrown. The
    /// uninstall primitives carry the safety contract (backup-before-write,
    /// third-party preservation, parse-failure bail).
    public func execute() {
        do {
            try HookInstaller(
                settingsPath: claudeSettingsPath, bridgePath: bridgePath
            ).uninstallHooks()
        } catch {
            NSLog("ZackEyes: claude uninstall failed: \(error)")
        }
        do {
            try CodexHookInstaller(
                hooksPath: codexHooksPath, bridgePath: bridgePath
            ).uninstallHooks()
        } catch {
            NSLog("ZackEyes: codex uninstall failed: \(error)")
        }
        for path in candidateFiles {
            try? FileManager.default.removeItem(atPath: path)
        }
    }
}
```

NOTE for implementer: `uninstallHooks()` already removes the mux files via `cleanupStatusLineMuxFiles()` — the `candidateFiles` sweep re-removing them is harmless (`try?` on missing). Verify `statusLineMode(of:)` handles `nil` doc (settings file absent → command nil → `.absent` → ownsStatusLine false).

- [ ] **Step 2.4** suite → 283 + 6 = 289.
- [ ] **Step 2.5 commit** `feat(hooks): add IntegrationUninstaller with read-only preview`

---

### Task 3: UninstallWindow + menu entries

**Files:** create `Sources/AppLib/MenuBar/UninstallWindow.swift`; modify `StatusBarMenu.swift`, `GearMenuTarget.swift`, `SimulatedNotchFullView.swift`.

- [ ] **Step 3.1** `UninstallWindow` — clone the `HookStatusWindow` shell EXACTLY (KeyablePanel, borderless+nonactivating, .floating, close-not-orderOut, nonisolated windowWillClose; size 360×340). Root view:

```swift
private struct UninstallCardView: View {
    let runPreview: () -> IntegrationUninstaller.Plan
    let runExecute: () -> Void
    let onDismiss: () -> Void

    @State private var plan: IntegrationUninstaller.Plan?
    @State private var done = false

    private static let danger = Color(red: 0.95, green: 0.45, blue: 0.40)

    var body: some View {
        ZStack {
            Color.black.opacity(0.6)
                .contentShape(Rectangle())
                .onTapGesture { if !done { onDismiss() } }

            VStack(alignment: .leading, spacing: 8) {
                Text(done ? "Integrations Removed" : "Uninstall Integrations")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.bottom, 4)

                if done {
                    Text("ZackEyes-owned hooks, statusLine entries and the launcher are gone. Third-party hooks and your own files were preserved.\n\nZackEyes will quit now — relaunching the app reinstalls the integrations. To finish removal, drag ZackEyes.app to the Trash.")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.8))
                        .fixedSize(horizontal: false, vertical: true)
                } else if let plan {
                    if plan.isEmpty {
                        Text("Nothing to remove — no ZackEyes integrations found on this machine.")
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.7))
                    } else {
                        Text("This will remove:")
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.7))
                        if plan.claudeHookEvents > 0 {
                            bullet("Claude hooks on \(plan.claudeHookEvents) events")
                        }
                        if plan.claudeOwnsStatusLine {
                            bullet("Claude statusLine entry (third-party original is restored)")
                        }
                        if plan.codexHookEvents > 0 {
                            bullet("Codex hooks on \(plan.codexHookEvents) events")
                        }
                        ForEach(plan.files, id: \.self) { path in
                            bullet((path as NSString).abbreviatingWithTildeInPath)
                        }
                        Text("Preserved: third-party hooks & statusLine, config.json, statusline-user. Configs are backed up before every write.")
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.5))
                            .padding(.top, 4)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                HStack(spacing: 10) {
                    Spacer()
                    if done {
                        Button(action: quitApp) { buttonLabel("Quit ZackEyes", color: Self.danger) }
                            .buttonStyle(.plain)
                            .keyboardShortcut(.defaultAction)
                    } else {
                        if let plan, !plan.isEmpty {
                            Button {
                                runExecute()
                                done = true
                            } label: { buttonLabel("Remove & Quit", color: Self.danger) }
                            .buttonStyle(.plain)
                        }
                        Button(action: onDismiss) {
                            buttonLabel("Cancel", color: .white.opacity(0.7), dim: true)
                        }
                        .buttonStyle(.plain)
                        .keyboardShortcut(.cancelAction)
                    }
                }
                .padding(.top, 8)
            }
            .padding(20)
            .frame(width: 330)
            .frame(minHeight: 220, alignment: .top)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(white: 0.12)))
            .contentShape(Rectangle())
            .onTapGesture { /* swallow */ }
        }
        .onAppear { plan = runPreview() }
    }

    private func quitApp() {
        NSApp.terminate(nil)
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("•").foregroundColor(Self.danger)
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(.white)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func buttonLabel(_ title: String, color: Color, dim: Bool = false) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(color)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(dim ? Color.white.opacity(0.08) : color.opacity(0.15))
            .cornerRadius(6)
    }
}
```

Window wiring: `runPreview: { IntegrationUninstaller().preview() }`, `runExecute: { IntegrationUninstaller().execute() }`. The done-state Quit button calls `NSApp.terminate(nil)` (clean shutdown runs `applicationWillTerminate` → socket teardown).

- [ ] **Step 3.2** menus — mirror the Hook Status wiring from #38 exactly: `StatusBarMenu` lazy `uninstallWindow` + item "Uninstall Integrations…" placed AFTER "Hook Status…"; `GearMenuTarget.uninstallClicked` (clears `isMenuOpen`); gear item in `SimulatedNotchFullView.popGearMenu` after the Hook Status item.
- [ ] **Step 3.3** `swift build` clean, suite 289 green.
- [ ] **Step 3.4 commit** `feat(menubar): add uninstall-integrations confirm flow`

---

### Task 4: Docs + sweep

- [ ] ARCHITECTURE.md: Hook 安装 table rows (`IntegrationUninstaller`), 菜单栏 fallback row (`UninstallWindow`), installer rows append `；卸载亦先备份（#46）`; 安全模型 Hook 注入安全 list — extend item 1 to mention uninstall backups.
- [ ] Full sweep incl. `make app`; commit plan + docs: `docs: document complete integration uninstall (#46)`.

### Task 5: Ship

- [ ] Final whole-branch review → push → PR (`Closes #46`, acceptance mapping, removal/preserve table) → bot dispositions → **PAUSE for user manual verification** (destructive UI flow: preview accuracy on the real machine, cancel path, repair-after-uninstall via Hook Status window) → squash-merge on user confirmation → #92 tick (#46 in the combined line) → memory.

---

## Self-Review Notes

- Acceptance: preview-before-confirm → card lists exact entries/files; backup-every-write → Task 1 closes the uninstall gap (install/repair already have it); third-party survival → primitive contract + `executeRemovesOursPreservesThirdParty`; mixed-config tests → Task 2 list.
- Auto-reinstall trap: documented in the done-state copy; quit is part of the flow. NOT adding a "don't reinstall" persistent flag — running the app declares wanting integrations (recorded design decision; revisit only if users complain).
- `pending/` removal is a directory removeItem — fine via FileManager.
- Idempotence: second execute hits uninstall's new no-op guards (no backup spam) + `try?` file removals.
