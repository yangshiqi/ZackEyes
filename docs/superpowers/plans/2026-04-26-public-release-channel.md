# Public Release Channel Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move DMG release artifacts to a public repo (`yangshiqi/ZackEyes-release`) so the in-app update checker can detect and download new versions without requiring a GitHub token, while keeping source code in the existing private repo.

**Architecture:** Two-part change. (1) `make release` now also builds a DMG and uploads it to the public repo via `gh release create --repo`. (2) `UpdateChecker` switches to the public repo and parses the DMG asset URL; a new `UpdateDownloader` does the actual `URLSession.download` + `NSWorkspace.open` to mount the DMG in Finder. Both menu surfaces (status-bar right-click menu and simulated-notch gear menu) and the system notification route their click action through the downloader.

**Tech Stack:** Swift 6 / AppKit / SwiftUI / `URLSession`, GNU Make, `gh` CLI, `hdiutil` (already used by existing `dmg` target).

**Spec:** [`docs/superpowers/specs/2026-04-26-public-release-channel-design.md`](../specs/2026-04-26-public-release-channel-design.md)

---

## Pre-flight

Before starting, run these one-time checks:

- [ ] **Verify public repo exists and is writable**

```bash
gh repo view yangshiqi/ZackEyes-release --json name,visibility,defaultBranchRef
```

Expected: JSON with `"visibility": "PUBLIC"` and a `defaultBranchRef` (e.g. `"main"`). If the repo has no default branch (no commits), create a placeholder commit:

```bash
gh repo clone yangshiqi/ZackEyes-release /tmp/zackeyes-release && \
cd /tmp/zackeyes-release && \
echo "# ZackEyes — Public Release Channel" > README.md && \
echo "" >> README.md && \
echo "DMG downloads for [ZackEyes](https://github.com/yangshiqi/ZackEyes). See the [Releases](https://github.com/yangshiqi/ZackEyes-release/releases) tab." >> README.md && \
git add README.md && git commit -m "chore: initial readme" && git push -u origin main && \
cd - && rm -rf /tmp/zackeyes-release
```

- [ ] **Verify `gh` auth has cross-repo write**

```bash
gh auth status
```

Expected: token scopes include `repo` (full control). If not: `gh auth refresh -s repo`.

---

## Task 1: Sanity-check + DMG-build scaffolding for `make release`

**Files:**
- Modify: `Makefile` (release target)

The current `release` target only bumps version, commits, tags, pushes, and creates an empty release. We're inserting a sanity check at the top and a DMG build before the commit so a build failure leaves no half-bumped state.

- [ ] **Step 1: Read the current `release` target**

Run: `sed -n '88,106p' Makefile` and confirm the existing 7-line recipe matches the spec's "before" picture.

- [ ] **Step 2: Replace the `release` target with the sanity-checked, DMG-aware version**

Replace the block from `release:` through the closing `@echo` line with:

```makefile
# Release workflow: bump version in Info.plist, build DMG, commit, tag,
# push to source repo, then publish DMG to the public release repo.
# Usage:  make release VERSION=0.3.0
# Optional: NOTES="changelog text" (defaults to "Release vVERSION")
release:
ifndef VERSION
	$(error VERSION is required. Usage: make release VERSION=0.3.0)
endif
	@echo "=== Sanity check ==="
	@branch=$$(git rev-parse --abbrev-ref HEAD); \
	  if [ "$$branch" != "master" ]; then \
	    echo "ERROR: must release from master, currently on $$branch"; exit 1; \
	  fi
	@if [ -n "$$(git status --porcelain)" ]; then \
	  echo "ERROR: working tree not clean"; git status --short; exit 1; \
	fi
	@echo "=== Bumping version to $(VERSION) ==="
	/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(VERSION)" Resources/Info.plist
	/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(VERSION)" Resources/Info.plist
	@echo "=== Building DMG (before commit so failures are recoverable) ==="
	$(MAKE) dmg
	@echo "=== Committing + tagging ==="
	git add Resources/Info.plist
	git commit -m "chore: bump version to $(VERSION)"
	git tag v$(VERSION)
	git push && git push origin v$(VERSION)
	@echo "=== Creating release on source repo (empty, internal record) ==="
	gh release create v$(VERSION) --title "v$(VERSION)" --notes "$${NOTES:-Release v$(VERSION)}"
	@echo "=== Publishing DMG to public release repo ==="
	gh release create v$(VERSION) .build/ZackEyes-$(VERSION).dmg \
	  --repo yangshiqi/ZackEyes-release \
	  --target main \
	  --title "v$(VERSION)" \
	  --notes "$${NOTES:-Release v$(VERSION)}"
	@echo ""
	@echo "✅ Released v$(VERSION)"
	@echo "   source:   https://github.com/yangshiqi/ZackEyes/releases/tag/v$(VERSION)"
	@echo "   download: https://github.com/yangshiqi/ZackEyes-release/releases/tag/v$(VERSION)"
```

- [ ] **Step 3: Dry-run the recipe (no actual release)**

Run: `make -n release VERSION=0.0.0-test`
Expected: prints all the commands above but doesn't execute. Verify the DMG path interpolates as `.build/ZackEyes-0.0.0-test.dmg` and the `--repo yangshiqi/ZackEyes-release --target main` flags are present.

- [ ] **Step 4: Verify sanity check trips on a dirty tree**

```bash
touch /tmp/dirty-test && cp /tmp/dirty-test Resources/__dirty_test
make release VERSION=0.0.0-test 2>&1 | head -3
rm -f Resources/__dirty_test /tmp/dirty-test
```

Expected: `ERROR: working tree not clean` followed by `git status --short` output. Then exit non-zero (no commits, no DMG built).

- [ ] **Step 5: Commit the Makefile change**

```bash
git add Makefile
git commit -m "build(release): build DMG + publish to public repo

Adds branch + clean-tree sanity check, builds the DMG before the
version-bump commit so build failures leave no half-bumped state,
then publishes the DMG asset to yangshiqi/ZackEyes-release via
gh release create --repo --target main."
```

---

## Task 2: Extend `GitHubRelease` with assets + add `dmgURL` to `UpdateChecker`

**Files:**
- Modify: `Sources/AppLib/Update/UpdateChecker.swift`
- Test: `Tests/AppLibTests/UpdateCheckerTests.swift`

We add `assets[]` to the JSON model, a `@Published dmgURL`, and switch the polled repo to `ZackEyes-release`. Drop the `Bearer <token>` header — public repo, no auth needed.

- [ ] **Step 1: Write the failing test for assets decoding**

Append to `Tests/AppLibTests/UpdateCheckerTests.swift`, immediately after the closing `}` of the last test:

```swift
    // MARK: - Assets decoding

    func testDecodesAssetsArray() throws {
        let json = """
        {
          "tag_name": "v0.3.0",
          "html_url": "https://github.com/yangshiqi/ZackEyes-release/releases/tag/v0.3.0",
          "assets": [
            {
              "name": "ZackEyes-0.3.0.dmg",
              "browser_download_url": "https://github.com/yangshiqi/ZackEyes-release/releases/download/v0.3.0/ZackEyes-0.3.0.dmg"
            }
          ]
        }
        """.data(using: .utf8)!

        let release = try JSONDecoder().decode(GitHubRelease.self, from: json)
        XCTAssertEqual(release.tagName, "v0.3.0")
        XCTAssertEqual(release.assets.count, 1)
        XCTAssertEqual(release.assets[0].name, "ZackEyes-0.3.0.dmg")
        XCTAssertEqual(
            release.assets[0].browserDownloadURL.absoluteString,
            "https://github.com/yangshiqi/ZackEyes-release/releases/download/v0.3.0/ZackEyes-0.3.0.dmg"
        )
    }

    func testDecodesEmptyAssetsArray() throws {
        let json = """
        {
          "tag_name": "v0.3.0",
          "html_url": "https://example.com",
          "assets": []
        }
        """.data(using: .utf8)!

        let release = try JSONDecoder().decode(GitHubRelease.self, from: json)
        XCTAssertTrue(release.assets.isEmpty)
    }
```

- [ ] **Step 2: Run the test, confirm it fails**

Run: `swift test --filter UpdateCheckerTests.testDecodesAssetsArray`
Expected: FAIL with a Codable error like `keyNotFound(CodingKeys(stringValue: "assets"…))` because the current `GitHubRelease` struct has no `assets` field.

- [ ] **Step 3: Add the `GitHubAsset` type and extend `GitHubRelease`**

In `Sources/AppLib/Update/UpdateChecker.swift`, replace the existing `GitHubRelease` definition (lines 3–12) with:

```swift
/// A downloadable asset attached to a GitHub release.
public struct GitHubAsset: Codable, Sendable {
    public let name: String
    public let browserDownloadURL: URL

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
    }
}

/// Minimal model for GitHub's /releases/latest response.
public struct GitHubRelease: Codable, Sendable {
    public let tagName: String
    public let htmlURL: URL
    public let assets: [GitHubAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case assets
    }
}
```

- [ ] **Step 4: Run the assets tests, confirm they pass**

Run: `swift test --filter UpdateCheckerTests.testDecodesAssetsArray UpdateCheckerTests.testDecodesEmptyAssetsArray`
Expected: both PASS.

- [ ] **Step 5: Switch the polled repo, drop the token header, publish `dmgURL`**

In the same file, change the `repoName` constant (currently `"ZackEyes"`) and the `check()` body:

Replace line 32:
```swift
    private let repoName = "ZackEyes-release"
```

Add a new `@Published` property next to the existing two (after line 22):
```swift
    @Published public var dmgURL: URL?
```

In `check()`, remove the four lines that load + attach the GitHub token (lines 64–66 currently), so the request setup is just:

```swift
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
```

Then in the success branch (where `availableVersion` and `releaseURL` are set), add `dmgURL` selection. Replace the existing block:

```swift
            if Self.isNewer(remote: remoteVersion, thanLocal: localVersion) {
                availableVersion = remoteVersion
                releaseURL = release.htmlURL
                if remoteVersion != notifiedVersion {
                    notifiedVersion = remoteVersion
                    onNewVersion?(remoteVersion, release.htmlURL)
                }
            }
```

with:

```swift
            if Self.isNewer(remote: remoteVersion, thanLocal: localVersion) {
                availableVersion = remoteVersion
                releaseURL = release.htmlURL
                dmgURL = release.assets.first(where: { $0.name.hasSuffix(".dmg") })?.browserDownloadURL
                if remoteVersion != notifiedVersion {
                    notifiedVersion = remoteVersion
                    onNewVersion?(remoteVersion, release.htmlURL)
                }
            }
```

- [ ] **Step 6: Run all UpdateChecker tests**

Run: `swift test --filter UpdateCheckerTests`
Expected: all PASS (existing version-comparison tests + the two new assets tests).

- [ ] **Step 7: Commit**

```bash
git add Sources/AppLib/Update/UpdateChecker.swift Tests/AppLibTests/UpdateCheckerTests.swift
git commit -m "feat(update): poll public release repo, parse DMG asset

Switches UpdateChecker to yangshiqi/ZackEyes-release (public),
drops the GitHub token header, parses release assets, publishes
the first .dmg asset URL via @Published dmgURL."
```

---

## Task 3: Remove `ConfigStore.loadGitHubToken()` (now unused)

**Files:**
- Modify: `Sources/AppLib/Config/ConfigStore.swift`
- Test: `Tests/AppLibTests/ConfigStoreTests.swift`

Verified at spec time that `UpdateChecker` was the only caller. Now that we've stripped that call, the method (and the `githubToken` JSON field) are dead code.

- [ ] **Step 1: Confirm no callers remain**

Run: `grep -rn "loadGitHubToken\|githubToken" Sources/ Tests/`
Expected: zero matches in `Sources/` (the previous matches in `UpdateChecker.swift:64` are gone after Task 2). The `ConfigStore.swift` matches and any test references are the only things left.

- [ ] **Step 2: Delete the method from `ConfigStore.swift`**

Remove lines 33–40 (the `/// Load the GitHub token` doc + `loadGitHubToken()` method) from `Sources/AppLib/Config/ConfigStore.swift`.

Also remove the `var githubToken: String?` field from the `ConfigWrapper` private struct at the bottom (currently line 161). Codable will simply ignore that key in any existing config.json — backward compat is fine.

- [ ] **Step 3: Check ConfigStoreTests for references**

Run: `grep -n "loadGitHubToken\|githubToken" Tests/AppLibTests/ConfigStoreTests.swift`
- If matches: delete the corresponding tests.
- If no matches: nothing to do here.

- [ ] **Step 4: Run all ConfigStore tests**

Run: `swift test --filter ConfigStoreTests`
Expected: all PASS.

- [ ] **Step 5: Build the whole package to catch any other reference**

Run: `swift build`
Expected: succeeds. If a stray reference shows up (e.g. in a test fixture), delete it.

- [ ] **Step 6: Commit**

```bash
git add Sources/AppLib/Config/ConfigStore.swift Tests/AppLibTests/ConfigStoreTests.swift
git commit -m "refactor(config): remove unused loadGitHubToken

UpdateChecker no longer reads a GitHub token (public release
repo doesn't need auth), and nothing else called this method."
```

---

## Task 4: Create `UpdateDownloader`

**Files:**
- Create: `Sources/AppLib/Update/UpdateDownloader.swift`
- Test: `Tests/AppLibTests/UpdateDownloaderTests.swift` (new)

A small `@MainActor` `ObservableObject` with a 4-state enum that drives menu UI. Cache hit (file already exists in tmp) skips the network entirely.

- [ ] **Step 1: Write the failing test for state transitions on cache-hit**

Create `Tests/AppLibTests/UpdateDownloaderTests.swift`:

```swift
import XCTest
@testable import AppLib

@MainActor
final class UpdateDownloaderTests: XCTestCase {

    func testInitialStateIsIdle() {
        let d = UpdateDownloader()
        XCTAssertEqual(d.state, .idle)
    }

    func testResetReturnsToIdle() {
        let d = UpdateDownloader()
        // Force state by simulating a failure first, then reset.
        d.simulateFailure(message: "test")
        XCTAssertEqual(d.state, .failed("test"))
        d.reset()
        XCTAssertEqual(d.state, .idle)
    }

    func testCacheHitTransitionsToReadyWithoutNetwork() async throws {
        // Pre-place a fake DMG in tmp so download() takes the cache-hit path.
        let url = URL(string: "https://example.com/path/ZackEyes-test-cache.dmg")!
        let cached = FileManager.default.temporaryDirectory
            .appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.removeItem(at: cached)
        try Data("fake dmg".utf8).write(to: cached)
        defer { try? FileManager.default.removeItem(at: cached) }

        let d = UpdateDownloader(opener: { _ in /* swallow open */ })
        await d.download(from: url)

        if case .ready(let path) = d.state {
            XCTAssertEqual(path, cached)
        } else {
            XCTFail("expected .ready, got \(d.state)")
        }
    }
}
```

- [ ] **Step 2: Run the test to confirm it fails**

Run: `swift test --filter UpdateDownloaderTests`
Expected: FAIL with `cannot find 'UpdateDownloader' in scope` — file doesn't exist yet.

- [ ] **Step 3: Create the `UpdateDownloader` file**

Create `Sources/AppLib/Update/UpdateDownloader.swift`:

```swift
import AppKit
import Foundation

/// Downloads the DMG asset for a new release into the user's tmp directory
/// and hands it to `NSWorkspace` so Finder mounts the disk image and shows
/// the drag-to-Applications layout.
///
/// Cache rule: if the same DMG filename already exists in tmp from an earlier
/// click in this session (or before reboot), skip the network and just open
/// it. macOS wipes tmp on reboot — fine.
///
/// `opener` is injectable so tests can avoid bouncing the user's actual
/// Finder. Production callers use the default (`NSWorkspace.shared.open`).
@MainActor
public final class UpdateDownloader: ObservableObject {
    public enum State: Equatable {
        case idle
        case downloading
        case ready(URL)
        case failed(String)
    }

    @Published public private(set) var state: State = .idle

    private let opener: (URL) -> Void

    public init(opener: @escaping (URL) -> Void = { url in
        NSWorkspace.shared.open(url)
    }) {
        self.opener = opener
    }

    /// Download the DMG at `url` to tmp/<filename>, then open it with Finder.
    /// On cache hit, skips the URLSession call entirely.
    public func download(from url: URL) async {
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent(url.lastPathComponent)

        if FileManager.default.fileExists(atPath: dest.path) {
            state = .ready(dest)
            opener(dest)
            return
        }

        state = .downloading
        do {
            let (tmpURL, _) = try await URLSession.shared.download(from: url)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tmpURL, to: dest)
            state = .ready(dest)
            opener(dest)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Reset to `.idle` so a failed item's menu title goes back to the
    /// "Update Available" affordance.
    public func reset() {
        state = .idle
    }

    // MARK: - Test helpers

    /// Test-only seam: lets unit tests assert state transitions without
    /// running the URLSession path.
    internal func simulateFailure(message: String) {
        state = .failed(message)
    }
}
```

- [ ] **Step 4: Run the tests, confirm pass**

Run: `swift test --filter UpdateDownloaderTests`
Expected: all 3 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/AppLib/Update/UpdateDownloader.swift Tests/AppLibTests/UpdateDownloaderTests.swift
git commit -m "feat(update): add UpdateDownloader for in-app DMG fetch

URLSession download to tmp + NSWorkspace open. State machine
drives menu UI. Cache-hit path skips network. Opener is
injected for test seams."
```

---

## Task 5: Wire `UpdateDownloader` through `AppDelegate`

**Files:**
- Modify: `Sources/ZackEyes/AppDelegate.swift`

Construct the downloader once, hand it to both menu surfaces (`StatusBarMenu` and `SimulatedNotchController` → `GearMenuTarget`), and rewire the notification tap so it goes through the downloader instead of opening the browser.

- [ ] **Step 1: Add a stored property and construct the downloader**

In `Sources/ZackEyes/AppDelegate.swift`, add a property next to the existing `updateChecker`:

```swift
    private var updateChecker: UpdateChecker?
    private var updateDownloader: UpdateDownloader?
```

In `applicationDidFinishLaunching`, just below the existing `let uc = UpdateChecker(); updateChecker = uc` lines, add:

```swift
        let dl = UpdateDownloader()
        updateDownloader = dl
```

- [ ] **Step 2: Inject into `StatusBarMenu`**

Locate the line `let statusMenu = StatusBarMenu(updateChecker: uc)` and change it to:

```swift
        let statusMenu = StatusBarMenu(updateChecker: uc, downloader: dl)
```

(The `StatusBarMenu` initializer signature change happens in Task 6 — this line will fail to compile until that task lands. The order assumes Task 6 runs immediately after; if you're committing each task separately, do Task 6 before this rebuild.)

- [ ] **Step 3: Inject into `SimulatedNotchController`**

Locate the existing `SimulatedNotchController(...)` call and add `downloader: dl,` to the argument list:

```swift
            let sn = SimulatedNotchController(
                viewModel: viewModel,
                usageTracker: usageTracker,
                updateChecker: uc,
                downloader: dl,
                initialVisibility: initialVisibility
            )
```

(Same caveat: signature change happens in Task 8.)

- [ ] **Step 4: Rewire the notification tap**

Find the existing block:

```swift
        NotificationManager.shared.onUpdateTap = { url in
            NSWorkspace.shared.open(url)
        }
```

Replace with:

```swift
        NotificationManager.shared.onUpdateTap = { [weak self] _ in
            guard let self,
                  let dmgURL = self.updateChecker?.dmgURL,
                  let dl = self.updateDownloader else { return }
            Task { @MainActor in await dl.download(from: dmgURL) }
        }
```

The `_` discards the legacy releaseURL argument — the downloader needs the DMG URL from `updateChecker.dmgURL`, not the html_url that the notification carried. If `dmgURL` is nil (e.g. release without an asset), the tap is a no-op. We accept that quietly; the menu item still falls back to opening the release page.

- [ ] **Step 5: Don't build yet**

This task intentionally leaves the project in a non-compiling state. Tasks 6 and 8 supply the matching initializer signatures. Build will be exercised at the end of Task 8.

- [ ] **Step 6: Commit**

```bash
git add Sources/ZackEyes/AppDelegate.swift
git commit -m "feat(app): construct UpdateDownloader, route taps through it

Builds the downloader once, injects into StatusBarMenu and
SimulatedNotchController, rewires the system-notification tap
to fetch via downloader.download(dmgURL) instead of opening
the browser. Project will not compile until Task 6 and Task 8."
```

---

## Task 6: State-driven menu in `StatusBarMenu`

**Files:**
- Modify: `Sources/AppLib/MenuBar/StatusBarMenu.swift`

The right-click menu rebuilds on every open, so it can simply read `downloader.state` each time and pick the right title. No need to push updates while a menu is open.

- [ ] **Step 1: Add the `downloader` parameter and store it**

In `Sources/AppLib/MenuBar/StatusBarMenu.swift`, change the property block (line 16) and initializer (lines 20–23) to:

```swift
    private let updateChecker: UpdateChecker
    private let downloader: UpdateDownloader
    private var hotkeyWindow: HotkeyRecorderWindow?
    private var aboutWindow: AboutWindow?

    public init(updateChecker: UpdateChecker, downloader: UpdateDownloader) {
        self.updateChecker = updateChecker
        self.downloader = downloader
        super.init()
    }
```

- [ ] **Step 2: Replace the update menu-item block in `build()`**

Locate the block (lines 32–41) that adds the "Update Available" item. Replace with:

```swift
        if let version = updateChecker.availableVersion {
            let (title, enabled) = Self.updateMenuLabel(
                version: version,
                state: downloader.state
            )
            let item = NSMenuItem(
                title: title,
                action: enabled ? #selector(updateClicked(_:)) : nil,
                keyEquivalent: ""
            )
            item.target = enabled ? self : nil
            item.isEnabled = enabled
            menu.addItem(item)
            menu.addItem(.separator())
        }
```

- [ ] **Step 3: Add the static label helper at the bottom of the class (just before the closing `}` of the class body)**

```swift
    /// Map (availableVersion, downloader.state) → menu item title + enabled flag.
    /// Pure function so it's trivially testable and shared with the simulated-notch
    /// gear menu in Task 8.
    public static func updateMenuLabel(
        version: String,
        state: UpdateDownloader.State
    ) -> (title: String, enabled: Bool) {
        switch state {
        case .idle:
            return ("Update Available (v\(version))", true)
        case .downloading:
            return ("Downloading v\(version)…", false)
        case .ready:
            // After a successful download Finder is already showing the DMG.
            // Keep the menu offering a re-open in case the user dismissed it.
            return ("Update Ready (v\(version)) — Click to Open", true)
        case .failed:
            return ("Update Failed — Click to Retry", true)
        }
    }
```

- [ ] **Step 4: Replace the `updateClicked` action**

Replace the existing 4-line `updateClicked` (lines 85–88 in the original file, before the edits in this task):

```swift
    @objc private func updateClicked(_ sender: Any?) {
        if let dmgURL = updateChecker.dmgURL {
            Task { @MainActor in await downloader.download(from: dmgURL) }
        } else if let url = updateChecker.releaseURL {
            // No DMG asset attached (in-flight release, or manual gh release
            // without --asset) — fall back to opening the release page.
            NSWorkspace.shared.open(url)
        }
    }
```

- [ ] **Step 5: Add a unit test for `updateMenuLabel`**

Append to `Tests/AppLibTests/UpdateDownloaderTests.swift` (inside the existing class body):

```swift
    func testMenuLabelIdle() {
        let (t, e) = StatusBarMenu.updateMenuLabel(version: "0.3.0", state: .idle)
        XCTAssertEqual(t, "Update Available (v0.3.0)")
        XCTAssertTrue(e)
    }

    func testMenuLabelDownloading() {
        let (t, e) = StatusBarMenu.updateMenuLabel(version: "0.3.0", state: .downloading)
        XCTAssertEqual(t, "Downloading v0.3.0…")
        XCTAssertFalse(e)
    }

    func testMenuLabelReady() {
        let (t, e) = StatusBarMenu.updateMenuLabel(
            version: "0.3.0",
            state: .ready(URL(fileURLWithPath: "/tmp/x.dmg"))
        )
        XCTAssertEqual(t, "Update Ready (v0.3.0) — Click to Open")
        XCTAssertTrue(e)
    }

    func testMenuLabelFailed() {
        let (t, e) = StatusBarMenu.updateMenuLabel(
            version: "0.3.0",
            state: .failed("network error")
        )
        XCTAssertEqual(t, "Update Failed — Click to Retry")
        XCTAssertTrue(e)
    }
```

- [ ] **Step 6: Run StatusBarMenu + UpdateDownloader tests**

Run: `swift test --filter UpdateDownloaderTests`
Expected: all PASS (3 from Task 4 + 4 new label tests).

- [ ] **Step 7: Build the whole package**

Run: `swift build`
Expected: succeeds. (`StatusBarMenu` initializer change matches the call site in `AppDelegate.swift` from Task 5.)

- [ ] **Step 8: Commit**

```bash
git add Sources/AppLib/MenuBar/StatusBarMenu.swift Tests/AppLibTests/UpdateDownloaderTests.swift
git commit -m "feat(menu): state-driven update item, trigger downloader

StatusBarMenu now reads downloader.state to build its title
(idle/downloading/ready/failed). Click triggers download with
fallback to release page when no DMG asset is attached."
```

---

## Task 7: Add `dmgURL` + `downloader` to `GearMenuTarget`

**Files:**
- Modify: `Sources/AppLib/SimulatedNotch/GearMenuTarget.swift`

The simulated-notch gear menu uses the singleton `GearMenuTarget` for action targets. We extend it with a downloader handle and a dmgURL field, mirroring the existing `releaseURL` plumbing.

- [ ] **Step 1: Add the new fields**

In `Sources/AppLib/SimulatedNotch/GearMenuTarget.swift`, change the field block (lines 12–15) to:

```swift
    static let shared = GearMenuTarget()
    weak var modeStore: NotchModeStore?
    var releaseURL: URL?
    var dmgURL: URL?
    var downloader: UpdateDownloader?
    private var previewSound: NSSound?
```

- [ ] **Step 2: Replace the `updateClicked` body**

Replace lines 27–31 (the existing `updateClicked`) with:

```swift
    @objc func updateClicked(_ sender: Any?) {
        modeStore?.isMenuOpen = false
        if let dmgURL, let downloader {
            Task { @MainActor in await downloader.download(from: dmgURL) }
        } else if let releaseURL {
            // No DMG yet — fall back to opening the release page.
            NSWorkspace.shared.open(releaseURL)
        }
    }
```

- [ ] **Step 3: Build to make sure nothing else broke**

Run: `swift build`
Expected: succeeds. (The `downloader` field is optional, so existing call sites that don't set it still work.)

- [ ] **Step 4: Commit**

```bash
git add Sources/AppLib/SimulatedNotch/GearMenuTarget.swift
git commit -m "feat(gear-menu): trigger downloader with DMG URL

Adds dmgURL + downloader handles to the singleton. updateClicked
now routes through the downloader, falling back to opening the
release page in browser when no DMG asset is attached."
```

---

## Task 8: Pipe downloader through `SimulatedNotchController` → `SimulatedNotchRoot` → `SimulatedNotchFullView`

**Files:**
- Modify: `Sources/AppLib/SimulatedNotch/SimulatedNotchController.swift`
- Modify: `Sources/AppLib/SimulatedNotch/SimulatedNotchRoot.swift`
- Modify: `Sources/AppLib/SimulatedNotch/SimulatedNotchFullView.swift`

The simulated-notch tree threads `updateChecker` from `AppDelegate` down to the SwiftUI view that builds the gear menu. We thread `downloader` along the same path and have the view stamp `GearMenuTarget.shared.dmgURL` + `.downloader` right before popping the menu (mirroring the existing `releaseURL` handoff).

- [ ] **Step 1: Add `downloader` parameter to `SimulatedNotchController.init`**

In `Sources/AppLib/SimulatedNotch/SimulatedNotchController.swift`:

- Add a stored property next to `private let updateChecker: UpdateChecker`:

```swift
    private let downloader: UpdateDownloader
```

- Add `downloader: UpdateDownloader,` to the initializer signature (next to the existing `updateChecker:` parameter) and assign `self.downloader = downloader` in the body.

- In whatever `setup()` / view construction code currently passes `updateChecker: updateChecker` into `SimulatedNotchRoot`, add `downloader: downloader,` next to it.

- [ ] **Step 2: Add `downloader` to `SimulatedNotchRoot`**

In `Sources/AppLib/SimulatedNotch/SimulatedNotchRoot.swift`, add an `@ObservedObject` next to the existing `updateChecker`:

```swift
    @ObservedObject var downloader: UpdateDownloader
```

Pass it through to `SimulatedNotchFullView` wherever that view is constructed (around line 109 in the existing file):

```swift
                downloader: downloader,
```

- [ ] **Step 3: Add `downloader` to `SimulatedNotchFullView`**

In `Sources/AppLib/SimulatedNotch/SimulatedNotchFullView.swift`, add next to the existing `@ObservedObject var updateChecker`:

```swift
    @ObservedObject var downloader: UpdateDownloader
```

- [ ] **Step 4: Stamp `downloader` + `dmgURL` on `GearMenuTarget` before popping the menu**

Find the existing line (currently around line 290):

```swift
        GearMenuTarget.shared.releaseURL = updateChecker.releaseURL
```

Add two lines right above it, so the singleton gets all three handles before the menu opens:

```swift
        GearMenuTarget.shared.downloader = downloader
        GearMenuTarget.shared.dmgURL = updateChecker.dmgURL
        GearMenuTarget.shared.releaseURL = updateChecker.releaseURL
```

- [ ] **Step 5: Replace the gear-menu update-item block to use the same label helper**

In `popGearMenu()`, find the update item block (currently around lines 208–217):

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

Replace with:

```swift
        if let version = updateChecker.availableVersion {
            let (title, enabled) = StatusBarMenu.updateMenuLabel(
                version: version,
                state: downloader.state
            )
            let update = NSMenuItem(
                title: title,
                action: enabled ? #selector(GearMenuTarget.updateClicked(_:)) : nil,
                keyEquivalent: ""
            )
            update.target = enabled ? GearMenuTarget.shared : nil
            update.isEnabled = enabled
            menu.addItem(update)
            menu.addItem(.separator())
        }
```

- [ ] **Step 6: Build the whole package**

Run: `swift build`
Expected: succeeds. (All initializer signatures now match: `AppDelegate` from Task 5, `SimulatedNotchController`, `SimulatedNotchRoot`, `SimulatedNotchFullView`, `StatusBarMenu`, `GearMenuTarget`.)

- [ ] **Step 7: Run the full test suite**

Run: `swift test`
Expected: all tests PASS. If any unrelated tests fail, investigate before continuing.

- [ ] **Step 8: Commit**

```bash
git add Sources/AppLib/SimulatedNotch/SimulatedNotchController.swift \
        Sources/AppLib/SimulatedNotch/SimulatedNotchRoot.swift \
        Sources/AppLib/SimulatedNotch/SimulatedNotchFullView.swift
git commit -m "feat(notch): thread downloader through gear menu

Plumbs UpdateDownloader from AppDelegate through the simulated-notch
view tree so the gear menu uses the same state-driven label helper
as StatusBarMenu and stamps GearMenuTarget.shared.dmgURL +
.downloader before popping."
```

---

## Task 9: Manual smoke test (non-blocking, but required before the next real release)

**Files:** none (verification only)

End-to-end check that the new client behaviour works against the real public repo. This is a one-shot verification, not automation.

- [ ] **Step 1: Build a fresh `.app`**

Run: `make app`
Expected: `.build/ZackEyes.app` built successfully.

- [ ] **Step 2: Temporarily downgrade local version**

Edit `Resources/Info.plist` and set `CFBundleShortVersionString` and `CFBundleVersion` to `0.0.1` (a value lower than the latest public release tag). **Do not commit this change.**

- [ ] **Step 3: Re-build the .app and run it**

Run: `make app && open .build/ZackEyes.app`
Expected: app launches.

- [ ] **Step 4: Wait for first update check (or trigger it)**

The first `UpdateChecker.check()` runs immediately on `start()`. Within ~1 second, the system notification "ZackEyes Update Available" should appear (assuming the public repo has at least one tagged release with a `.dmg` asset).

If there is no real release yet, skip this step until after Task 11 has shipped a real release.

- [ ] **Step 5: Right-click the menu-bar icon**

Expected menu: `Update Available (vX.Y.Z)` as the first item.

- [ ] **Step 6: Click the update item**

Expected sequence:
1. Menu closes.
2. Within a few seconds (DMG is small), Finder mounts a disk image and shows the drag-to-Applications window.
3. The DMG file is in `$TMPDIR` (run `ls $TMPDIR/ZackEyes-*.dmg` to confirm).

- [ ] **Step 7: Re-open the menu while the DMG is still mounted**

Expected: the menu item now reads `Update Ready (vX.Y.Z) — Click to Open`. Clicking it re-opens (cache hit path, no network).

- [ ] **Step 8: Restore Info.plist and clean tmp**

```bash
git checkout Resources/Info.plist
rm -f $TMPDIR/ZackEyes-*.dmg
```

(Tmp cleanup is optional — macOS does it on reboot. Restoring Info.plist is mandatory before any commit.)

---

## Task 10: ARCHITECTURE.md + CHANGELOG.md updates

**Files:**
- Modify: `ARCHITECTURE.md`
- Modify: `CHANGELOG.md`

Document the two-repo split and the in-app download path so the next contributor doesn't have to re-derive it from the spec.

- [ ] **Step 1: Locate the existing update-checker section in ARCHITECTURE.md**

Run: `grep -n "UpdateChecker\|GitHub Releases\|version check" ARCHITECTURE.md`
Expected: at least one section that describes the existing checker. Note its line range.

- [ ] **Step 2: Update or add a "Release distribution" subsection**

Inside the existing update-related section, add (or update) text like:

```markdown
### Release distribution

Source code lives in **`yangshiqi/ZackEyes` (private)**; release artifacts (DMG)
are published to **`yangshiqi/ZackEyes-release` (public)** so the in-app update
checker can poll and download without requiring the user to configure a GitHub
token.

`make release VERSION=x.y.z` runs both: it tags + creates an empty release on
the source repo (internal record), then `gh release create --repo
yangshiqi/ZackEyes-release --target main` uploads the DMG to the public repo.

`UpdateChecker` polls `/repos/yangshiqi/ZackEyes-release/releases/latest`
every 6 hours, parses `assets[]` for the first `.dmg`, and publishes its
`browser_download_url` via `@Published dmgURL`. `UpdateDownloader` runs
`URLSession.download` to `$TMPDIR/ZackEyes-x.y.z.dmg`, then
`NSWorkspace.open` so Finder mounts the disk image and shows the drag-to-
Applications layout. Both menu surfaces (status-bar right-click + simulated-
notch gear menu) and the system notification tap route through the
downloader.
```

Adapt the wording to fit the existing tone — the specifics above are the points that must be conveyed.

- [ ] **Step 3: Add a CHANGELOG.md entry under `## Unreleased`**

Open `CHANGELOG.md` and add (under the `## Unreleased` section, creating it if absent):

```markdown
### Added

- In-app DMG download for new versions. Releases now publish the DMG to a
  public companion repo (`yangshiqi/ZackEyes-release`); clicking "Update
  Available" downloads the installer and opens it in Finder. No GitHub
  token required.

### Changed

- `make release` now builds a DMG before committing the version bump and
  uploads it to the public release repo in addition to tagging the source
  repo.

### Removed

- `ConfigStore.loadGitHubToken()` and the `githubToken` field — no longer
  needed now that update checks hit a public repo.
```

- [ ] **Step 4: Commit**

```bash
git add ARCHITECTURE.md CHANGELOG.md
git commit -m "docs: public release channel + in-app DMG download

Documents the source-private / releases-public split and the
download flow. Notes the loadGitHubToken removal."
```

---

## Task 11: First real release using the new pipeline

**Files:** none (release operation)

Treat this like a deployment, not a test. Pick a small version bump so failure has minimal blast radius. Current version is `0.2.8`, so bump to `0.2.9`.

- [ ] **Step 1: Confirm clean tree on master**

Run: `git status && git rev-parse --abbrev-ref HEAD`
Expected: clean, on `master`. Otherwise abort.

- [ ] **Step 2: Run the new release recipe**

```bash
make release VERSION=0.2.9 NOTES="Public release channel: in-app DMG download. No GitHub token required."
```

Expected output sequence:
- Sanity check passes
- Version bumped in `Resources/Info.plist`
- DMG built (`✅ .build/ZackEyes-0.2.9.dmg`)
- Commit + tag + push succeeds
- Source-repo `gh release create` succeeds
- Public-repo `gh release create --repo yangshiqi/ZackEyes-release` succeeds, asset uploaded
- Final `✅ Released v0.2.9` line with both URLs

- [ ] **Step 3: Verify the public release page**

```bash
gh release view v0.2.9 --repo yangshiqi/ZackEyes-release --json assets
```

Expected: JSON with one asset whose `name` is `ZackEyes-0.2.9.dmg` and a non-zero `size`.

- [ ] **Step 4: Verify anonymous download works**

```bash
curl -sI -L "https://github.com/yangshiqi/ZackEyes-release/releases/download/v0.2.9/ZackEyes-0.2.9.dmg" | head -1
```

Expected: `HTTP/2 200` after the redirects resolve. (Tests that the asset is publicly downloadable without auth — the entire point of this work.)

- [ ] **Step 5: Run the manual smoke test from Task 9 against this release**

If you skipped Task 9 because no real release existed yet, run it now end-to-end. This is the proof that the in-app flow works.

- [ ] **Step 6: If anything failed**

Recovery notes from the spec:

| Failed step | Recovery |
|------|---------|
| DMG build fails | `git checkout Resources/Info.plist`, fix build, retry |
| Push fails | Network issue. `git push && git push origin v0.2.9` manually, then re-run the two `gh release create` commands by hand |
| Source `gh release create` fails | Manual: `gh release create v0.2.9 --title "v0.2.9" --notes "..."` |
| Public `gh release create` fails | Manual: `gh release create v0.2.9 .build/ZackEyes-0.2.9.dmg --repo yangshiqi/ZackEyes-release --target main --title "v0.2.9" --notes "..."` |

---

## Self-Review Checklist

Run through after the plan is written, fix issues inline.

**Spec coverage** — every spec section is implemented somewhere:

| Spec section | Implementing task(s) |
|---|---|
| Repo Topology | Pre-flight (verify exists), Task 1 (uses public repo) |
| Release Pipeline (sanity check, DMG-before-commit, dual gh release create) | Task 1 |
| `UpdateChecker` repo switch | Task 2 step 5 |
| `UpdateChecker` token drop | Task 2 step 5 |
| `GitHubAsset` + `assets[]` model | Task 2 steps 1–4 |
| `@Published dmgURL` | Task 2 step 5 |
| Remove `loadGitHubToken()` | Task 3 |
| `UpdateDownloader` (state, cache, download, open) | Task 4 |
| Menu rewriting by `downloader.state` | Task 6 (StatusBarMenu) + Task 8 (GearMenu) |
| `dmgURL` nil → fallback to release page | Task 6 step 4, Task 7 step 2 |
| Notification tap → downloader | Task 5 step 4 |
| Edge case: no DMG asset | covered in Task 6/7 fallback paths |
| Edge case: download fail → retry | Task 6 (label helper covers `.failed` state) |
| Tests: assets decode | Task 2 steps 1–4 |
| Tests: DMG selection | implicit in Task 2 step 5 (first `.dmg` suffix); selector test optional, covered by integration via real release |
| Manual smoke test | Task 9 |
| ARCHITECTURE + CHANGELOG | Task 10 |
| First real release | Task 11 |

**Placeholder scan** — no "TBD", "implement later", or "add error handling" — verified.

**Type consistency**:
- `UpdateDownloader.State` — `idle / downloading / ready(URL) / failed(String)` used identically in Tasks 4, 6 (helper), 7 (gear), 8 (notch view). ✓
- `UpdateChecker.dmgURL: URL?` introduced in Task 2, read in Tasks 5, 6, 7, 8. ✓
- `StatusBarMenu.updateMenuLabel(version:state:)` defined in Task 6, called in Task 8. ✓
- `GearMenuTarget.dmgURL` and `.downloader` defined in Task 7, written in Task 8 step 4, read in Task 7 step 2. ✓

**Scope check** — single feature, no decomposition needed.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-04-26-public-release-channel.md`. Two execution options:

1. **Subagent-Driven (recommended)** — fresh subagent per task, review between tasks, fast iteration.
2. **Inline Execution** — execute tasks in this session using executing-plans, batch execution with checkpoints.

Which approach?
