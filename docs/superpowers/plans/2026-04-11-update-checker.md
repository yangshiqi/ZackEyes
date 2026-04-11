# Update Checker Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Detect new GitHub releases and notify users via gear menu badge + system notification.

**Architecture:** `UpdateChecker` polls GitHub Releases API on startup and every 6h, publishes state as `@Published` properties. `SimulatedNotchFullView` observes it for gear badge + menu item. `NotificationManager` sends a one-time system notification per new version.

**Tech Stack:** Swift 6, Foundation (URLSession, JSONDecoder, Timer, UserDefaults), UNUserNotifications

---

## File Structure

| File | Responsibility |
|------|---------------|
| **New** `Sources/AppLib/Update/UpdateChecker.swift` | GitHub API call, semantic version compare, 6h timer, `@Published` state |
| **New** `Tests/AppLibTests/UpdateCheckerTests.swift` | Version comparison + JSON parsing tests |
| **Mod** `Sources/AppLib/SimulatedNotch/SimulatedNotchFullView.swift` | Gear icon red badge, "Update Available" menu item |
| **Mod** `Sources/AppLib/SimulatedNotch/GearMenuTarget.swift` | `updateClicked()` handler + `releaseURL` storage |
| **Mod** `Sources/AppLib/Notifications/NotificationManager.swift` | `notifyUpdateAvailable()` method |
| **Mod** `Sources/ZackEyes/AppDelegate.swift` | Create UpdateChecker, route update notification taps |

---

### Task 1: Version comparison and GitHub response parsing

**Files:**
- Create: `Sources/AppLib/Update/UpdateChecker.swift`
- Create: `Tests/AppLibTests/UpdateCheckerTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
// Tests/AppLibTests/UpdateCheckerTests.swift
import XCTest
@testable import AppLib

final class UpdateCheckerTests: XCTestCase {

    // MARK: - Version comparison

    func testNewerMajor() {
        XCTAssertTrue(UpdateChecker.isNewer(remote: "1.0.0", thanLocal: "0.1.0"))
    }

    func testNewerMinor() {
        XCTAssertTrue(UpdateChecker.isNewer(remote: "0.2.0", thanLocal: "0.1.0"))
    }

    func testNewerPatch() {
        XCTAssertTrue(UpdateChecker.isNewer(remote: "0.1.1", thanLocal: "0.1.0"))
    }

    func testSameVersion() {
        XCTAssertFalse(UpdateChecker.isNewer(remote: "0.1.0", thanLocal: "0.1.0"))
    }

    func testOlderVersion() {
        XCTAssertFalse(UpdateChecker.isNewer(remote: "0.0.9", thanLocal: "0.1.0"))
    }

    func testStripsVPrefix() {
        XCTAssertTrue(UpdateChecker.isNewer(remote: "v0.2.0", thanLocal: "0.1.0"))
    }

    func testMalformedRemoteReturnsFalse() {
        XCTAssertFalse(UpdateChecker.isNewer(remote: "not-a-version", thanLocal: "0.1.0"))
    }

    func testMalformedLocalReturnsFalse() {
        XCTAssertFalse(UpdateChecker.isNewer(remote: "0.2.0", thanLocal: "bad"))
    }

    func testTwoComponentVersion() {
        XCTAssertTrue(UpdateChecker.isNewer(remote: "0.2", thanLocal: "0.1.0"))
    }

    // MARK: - GitHub JSON parsing

    func testParseReleaseJSON() throws {
        let json = """
        {
            "tag_name": "v0.2.0",
            "html_url": "https://github.com/yangshiqi/ZackEyes/releases/tag/v0.2.0"
        }
        """.data(using: .utf8)!

        let release = try JSONDecoder().decode(GitHubRelease.self, from: json)
        XCTAssertEqual(release.tagName, "v0.2.0")
        XCTAssertEqual(release.htmlURL.absoluteString, "https://github.com/yangshiqi/ZackEyes/releases/tag/v0.2.0")
    }

    func testParseReleaseIgnoresExtraFields() throws {
        let json = """
        {
            "tag_name": "v0.3.0",
            "html_url": "https://github.com/yangshiqi/ZackEyes/releases/tag/v0.3.0",
            "name": "Release 0.3.0",
            "draft": false,
            "prerelease": false,
            "body": "changelog here"
        }
        """.data(using: .utf8)!

        let release = try JSONDecoder().decode(GitHubRelease.self, from: json)
        XCTAssertEqual(release.tagName, "v0.3.0")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter UpdateCheckerTests 2>&1 | tail -20`
Expected: FAIL — `UpdateChecker` and `GitHubRelease` not found

- [ ] **Step 3: Implement UpdateChecker with version compare + GitHubRelease model**

```swift
// Sources/AppLib/Update/UpdateChecker.swift
import Foundation

/// Minimal model for GitHub's /releases/latest response.
public struct GitHubRelease: Codable, Sendable {
    public let tagName: String
    public let htmlURL: URL

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
    }
}

/// Checks GitHub Releases for new versions of ZackEyes.
///
/// Usage: create once, call `start()`. Publishes `availableVersion` and
/// `releaseURL` when a newer release is found.
@MainActor
public final class UpdateChecker: ObservableObject {

    @Published public var availableVersion: String?
    @Published public var releaseURL: URL?

    private var timer: Timer?
    private let checkInterval: TimeInterval
    private let repoOwner = "yangshiqi"
    private let repoName = "ZackEyes"

    /// Current app version from Info.plist.
    private var localVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    public init(checkInterval: TimeInterval = 6 * 3600) {
        self.checkInterval = checkInterval
    }

    public func start() {
        Task { await check() }
        timer = Timer.scheduledTimer(withTimeInterval: checkInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.check()
            }
        }
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Check logic

    private func check() async {
        guard let url = URL(string: "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/latest") else { return }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }
            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            let remoteVersion = release.tagName.hasPrefix("v")
                ? String(release.tagName.dropFirst())
                : release.tagName

            if Self.isNewer(remote: remoteVersion, thanLocal: localVersion) {
                availableVersion = remoteVersion
                releaseURL = release.htmlURL
            }
        } catch {
            // Network/parse failure — silent, retry on next timer tick
        }
    }

    // MARK: - Semantic version comparison

    /// Returns true if `remote` is strictly newer than `local`.
    /// Strips leading "v" from either string. Returns false on parse failure.
    public static func isNewer(remote: String, thanLocal local: String) -> Bool {
        let r = parseVersion(remote)
        let l = parseVersion(local)
        guard !r.isEmpty, !l.isEmpty else { return false }

        for i in 0..<max(r.count, l.count) {
            let rv = i < r.count ? r[i] : 0
            let lv = i < l.count ? l[i] : 0
            if rv > lv { return true }
            if rv < lv { return false }
        }
        return false
    }

    private static func parseVersion(_ string: String) -> [Int] {
        let stripped = string.hasPrefix("v") ? String(string.dropFirst()) : string
        let parts = stripped.split(separator: ".").compactMap { Int($0) }
        // Must have at least one valid component
        guard !parts.isEmpty, parts.count == stripped.split(separator: ".").count else { return [] }
        return parts
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter UpdateCheckerTests 2>&1 | tail -20`
Expected: All tests PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/AppLib/Update/UpdateChecker.swift Tests/AppLibTests/UpdateCheckerTests.swift
git commit -m "feat(update): add UpdateChecker with version compare and GitHub API model"
```

---

### Task 2: System notification for new version

**Files:**
- Modify: `Sources/AppLib/Notifications/NotificationManager.swift`

- [ ] **Step 1: Add `notifyUpdateAvailable` method and `onUpdateTap` callback**

In `Sources/AppLib/Notifications/NotificationManager.swift`, add after `onSessionTap` (line 12):

```swift
    /// Called when the user taps an update notification. Payload is the release URL.
    public var onUpdateTap: ((URL) -> Void)?
```

Add this method after `notifySessionFinished` (after line 78):

```swift
    /// Post a notification for a new app version. Only sends once per version
    /// (tracked via UserDefaults).
    public func notifyUpdateAvailable(version: String, releaseURL: URL) {
        let lastNotified = UserDefaults.standard.string(forKey: "lastNotifiedVersion")
        guard lastNotified != version else { return }

        let content = UNMutableNotificationContent()
        content.title = "ZackEyes Update Available"
        content.body = "Version \(version) is available. Click to download."
        content.sound = .default
        content.categoryIdentifier = "update"
        content.userInfo = ["releaseURL": releaseURL.absoluteString]

        let request = UNNotificationRequest(
            identifier: "update-\(version)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                NSLog("ZackEyes: update notification failed: %@", error.localizedDescription)
            }
        }
        UserDefaults.standard.set(version, forKey: "lastNotifiedVersion")
    }
```

Update the `didReceive` delegate method (lines 91-104) to also handle update taps. Replace:

```swift
    nonisolated public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let sessionId = response.notification.request.content.userInfo["sessionId"] as? String
        // Call completion immediately — we don't need to block the framework
        completionHandler()
        Task { @MainActor [weak self] in
            if let sessionId = sessionId {
                self?.onSessionTap?(sessionId)
            }
        }
    }
```

With:

```swift
    nonisolated public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let sessionId = userInfo["sessionId"] as? String
        let releaseURLString = userInfo["releaseURL"] as? String
        completionHandler()
        Task { @MainActor [weak self] in
            if let releaseURLString, let url = URL(string: releaseURLString) {
                self?.onUpdateTap?(url)
            } else if let sessionId {
                self?.onSessionTap?(sessionId)
            }
        }
    }
```

- [ ] **Step 2: Build to verify compilation**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeds

- [ ] **Step 3: Commit**

```bash
git add Sources/AppLib/Notifications/NotificationManager.swift
git commit -m "feat(update): add update notification with tap-to-open handler"
```

---

### Task 3: Gear menu badge + "Update Available" menu item

**Files:**
- Modify: `Sources/AppLib/SimulatedNotch/SimulatedNotchFullView.swift`
- Modify: `Sources/AppLib/SimulatedNotch/GearMenuTarget.swift`

- [ ] **Step 1: Add `releaseURL` and `updateClicked` to GearMenuTarget**

In `Sources/AppLib/SimulatedNotch/GearMenuTarget.swift`, add after `weak var modeStore` (line 13):

```swift
    var releaseURL: URL?
```

Add after `hotkeyClicked` method:

```swift
    @objc func updateClicked(_ sender: Any?) {
        modeStore?.isMenuOpen = false
        guard let url = releaseURL else { return }
        NSWorkspace.shared.open(url)
    }
```

- [ ] **Step 2: Add `updateChecker` property to SimulatedNotchFullView**

In `Sources/AppLib/SimulatedNotch/SimulatedNotchFullView.swift`, add after the `modeStore` property (line 11):

```swift
    @ObservedObject var updateChecker: UpdateChecker
```

- [ ] **Step 3: Add red badge overlay to gear icon**

Replace the `gearMenu` computed property (lines 159-172):

Old:
```swift
    private var gearMenu: some View {
        Button {
            modeStore.markMenuOpen()
            popGearMenu()
        } label: {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white.opacity(0.85))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(HostViewProbe(box: gearHost))
    }
```

New:
```swift
    private var gearMenu: some View {
        Button {
            modeStore.markMenuOpen()
            popGearMenu()
        } label: {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white.opacity(0.85))
                .frame(width: 22, height: 22)
                .overlay(alignment: .topTrailing) {
                    if updateChecker.availableVersion != nil {
                        Circle()
                            .fill(.red)
                            .frame(width: 6, height: 6)
                            .offset(x: 2, y: -2)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(HostViewProbe(box: gearHost))
    }
```

- [ ] **Step 4: Add "Update Available" menu item to popGearMenu()**

In `popGearMenu()`, add at the TOP of the method body (after `let menu = NSMenu()`, before the "About" item):

```swift
        if let version = updateChecker.availableVersion {
            let update = NSMenuItem(
                title: "Update Available (v\(version))",
                action: #selector(GearMenuTarget.updateClicked(_:)),
                keyEquivalent: ""
            )
            update.target = GearMenuTarget.shared
            menu.addItem(update)
            menu.addItem(.separator())
        }
```

Also add before the existing `GearMenuTarget.shared.modeStore = modeStore` line:

```swift
        GearMenuTarget.shared.releaseURL = updateChecker.releaseURL
```

- [ ] **Step 5: Build — will fail because callers don't pass updateChecker yet**

Run: `swift build 2>&1 | tail -10`
Expected: Build FAILS — missing `updateChecker` argument at call sites

- [ ] **Step 6: Update SimulatedNotchRoot to pass updateChecker**

In `Sources/AppLib/SimulatedNotch/SimulatedNotchRoot.swift`, add to `SimulatedNotchRoot` struct after `modeStore`:

```swift
    @ObservedObject var updateChecker: UpdateChecker
```

Update the `SimulatedNotchFullView` instantiation inside the `.overlay(alignment: .top)` block. Find:

```swift
            SimulatedNotchFullView(
                viewModel: viewModel,
                usageTracker: usageTracker,
                modeStore: modeStore,
                cornerRadius: 22
            )
```

Replace with:

```swift
            SimulatedNotchFullView(
                viewModel: viewModel,
                usageTracker: usageTracker,
                modeStore: modeStore,
                updateChecker: updateChecker,
                cornerRadius: 22
            )
```

- [ ] **Step 7: Update SimulatedNotchController to create and pass UpdateChecker**

In `Sources/AppLib/SimulatedNotch/SimulatedNotchController.swift`, add a stored property after `usageTracker` (around line 17):

```swift
    private let updateChecker: UpdateChecker
```

Update the initializer. Current:

```swift
    public init(viewModel: NotchViewModel, usageTracker: UsageTracker) {
        self.viewModel = viewModel
        self.usageTracker = usageTracker
    }
```

New:

```swift
    public init(viewModel: NotchViewModel, usageTracker: UsageTracker, updateChecker: UpdateChecker) {
        self.viewModel = viewModel
        self.usageTracker = usageTracker
        self.updateChecker = updateChecker
    }
```

In `createPanel()`, update the `SimulatedNotchRoot` construction. Find:

```swift
        let root = SimulatedNotchRoot(
            viewModel: viewModel,
            usageTracker: usageTracker,
            modeStore: modeStore,
            compactWidth: compactWidth,
            fullWidth: fullWidth,
            notchHeight: notchHeight,
            fullHeight: fullHeight,
            onTap: { [weak self] in self?.toggleFull() }
        )
```

Replace with:

```swift
        let root = SimulatedNotchRoot(
            viewModel: viewModel,
            usageTracker: usageTracker,
            modeStore: modeStore,
            updateChecker: updateChecker,
            compactWidth: compactWidth,
            fullWidth: fullWidth,
            notchHeight: notchHeight,
            fullHeight: fullHeight,
            onTap: { [weak self] in self?.toggleFull() }
        )
```

- [ ] **Step 8: Build to verify compilation**

Run: `swift build 2>&1 | tail -10`
Expected: Build FAILS — `AppDelegate` doesn't pass `updateChecker` to `SimulatedNotchController` yet (handled in Task 4)

- [ ] **Step 9: Commit (partial — will fix AppDelegate in Task 4)**

```bash
git add Sources/AppLib/SimulatedNotch/SimulatedNotchFullView.swift \
       Sources/AppLib/SimulatedNotch/GearMenuTarget.swift \
       Sources/AppLib/SimulatedNotch/SimulatedNotchRoot.swift \
       Sources/AppLib/SimulatedNotch/SimulatedNotchController.swift
git commit -m "feat(update): gear menu badge + Update Available menu item

WIP: AppDelegate wiring in next commit"
```

---

### Task 4: Wire UpdateChecker into AppDelegate

**Files:**
- Modify: `Sources/ZackEyes/AppDelegate.swift`

- [ ] **Step 1: Add updateChecker property and wire everything**

In `Sources/ZackEyes/AppDelegate.swift`, add after `hotKeyManager` property (line 14):

```swift
    private var updateChecker: UpdateChecker?
```

In `applicationDidFinishLaunching`, update the `SimulatedNotchController` creation (around line 69). Find:

```swift
            let sn = SimulatedNotchController(
                viewModel: viewModel,
                usageTracker: usageTracker
            )
```

Replace with:

```swift
            let uc = UpdateChecker()
            let sn = SimulatedNotchController(
                viewModel: viewModel,
                usageTracker: usageTracker,
                updateChecker: uc
            )
```

After `simulatedNotch = sn` (around line 76), add:

```swift
            updateChecker = uc
```

After the hook installer section (after the `Task { ... }` block around line 112), add:

```swift
        // 6.5 Update checker — polls GitHub Releases every 6h
        if let uc = updateChecker {
            uc.start()
            // Send system notification on first detection of a new version
            uc.$availableVersion
                .compactMap { $0 }
                .removeDuplicates()
                .sink { [weak uc] version in
                    guard let url = uc?.releaseURL else { return }
                    NotificationManager.shared.notifyUpdateAvailable(version: version, releaseURL: url)
                }
                // Store the cancellable — but we need Combine for sink.
                // Actually, avoid Combine (zero third-party spirit). Use observation instead:
        }
```

Wait — `sink` requires `import Combine`. Let me use a simpler approach. Instead of reactive observation, have `UpdateChecker.check()` post the notification directly after finding a new version. This avoids introducing Combine.

Replace the entire wiring approach. In `UpdateChecker.check()` (in Task 1's implementation), add a notification callback. Update the `UpdateChecker` class to accept an `onNewVersion` closure:

Add to `UpdateChecker` after the `releaseURL` property:

```swift
    /// Called once per new version detected. Used to trigger system notification.
    public var onNewVersion: ((String, URL) -> Void)?
```

In the `check()` method, after setting `availableVersion` and `releaseURL`, add:

```swift
                onNewVersion?(remoteVersion, release.htmlURL)
```

Now the AppDelegate wiring becomes simple. After `uc.start()`:

```swift
            uc.onNewVersion = { version, url in
                NotificationManager.shared.notifyUpdateAvailable(version: version, releaseURL: url)
            }
```

And add the update tap handler after the existing `NotificationManager.shared.onSessionTap` block (around line 27):

```swift
        NotificationManager.shared.onUpdateTap = { url in
            NSWorkspace.shared.open(url)
        }
```

Full changes to AppDelegate — add property at line 14:

```swift
    private var updateChecker: UpdateChecker?
```

Add notification tap handler after `onSessionTap` block (after line 27):

```swift
        NotificationManager.shared.onUpdateTap = { url in
            NSWorkspace.shared.open(url)
        }
```

Update SimulatedNotchController creation (around line 69):

```swift
            let uc = UpdateChecker()
            let sn = SimulatedNotchController(
                viewModel: viewModel,
                usageTracker: usageTracker,
                updateChecker: uc
            )
            sn.setup()
            simulatedNotch = sn
            updateChecker = uc
```

After the hook installer section, start the checker and wire the notification:

```swift
        // 6.5 Update checker — polls GitHub Releases every 6h
        updateChecker?.onNewVersion = { version, url in
            NotificationManager.shared.notifyUpdateAvailable(version: version, releaseURL: url)
        }
        updateChecker?.start()
```

- [ ] **Step 2: Update UpdateChecker.swift to add onNewVersion callback**

In `Sources/AppLib/Update/UpdateChecker.swift`, add after `releaseURL` property:

```swift
    /// Called once when a new version is first detected.
    public var onNewVersion: ((String, URL) -> Void)?
```

In the `check()` method, after `releaseURL = release.htmlURL`, add:

```swift
                onNewVersion?(remoteVersion, release.htmlURL)
```

But only call it once — not on every timer tick. Add a guard:

```swift
    private var notifiedVersion: String?
```

And wrap the callback:

```swift
                if remoteVersion != notifiedVersion {
                    notifiedVersion = remoteVersion
                    onNewVersion?(remoteVersion, release.htmlURL)
                }
```

- [ ] **Step 3: Build and verify**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeds

- [ ] **Step 4: Run all tests**

Run: `swift test 2>&1 | tail -20`
Expected: All tests PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/ZackEyes/AppDelegate.swift Sources/AppLib/Update/UpdateChecker.swift
git commit -m "feat(update): wire UpdateChecker into AppDelegate with notifications"
```

---

### Task 5: Build + docs update

- [ ] **Step 1: Full build**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeds

- [ ] **Step 2: Run all tests**

Run: `swift test 2>&1 | tail -20`
Expected: All tests PASS

- [ ] **Step 3: Build .app bundle**

Run: `make app 2>&1 | tail -5`
Expected: `.build/ZackEyes.app` created

- [ ] **Step 4: Update ARCHITECTURE.md**

Add to the 全局功能 module table:

```
| `UpdateChecker` | `Sources/AppLib/Update/UpdateChecker.swift` | GitHub Releases API 轮询（6h），语义版本比较，`@Published` 状态驱动齿轮红点 + 系统通知 |
```

Add `Update/` to the project structure tree under `AppLib/`:

```
│   │   ├── Update/             # UpdateChecker (GitHub 版本检测)
```

- [ ] **Step 5: Commit docs**

```bash
git add ARCHITECTURE.md
git commit -m "docs: add UpdateChecker to ARCHITECTURE.md"
```
