# Public Release Channel Design

## Goal

Move release artifacts (DMG) to a separate **public** GitHub repo so the in-app update checker can detect and **download** new versions without requiring users to configure a GitHub token. Source code stays in the existing private repo `yangshiqi/ZackEyes`.

## Scope

Two-part change:

1. **Release pipeline**: `make release VERSION=x.y.z` builds a DMG and publishes it to `yangshiqi/ZackEyes-release` (public). The source repo still gets a tag + empty release for internal bookkeeping.
2. **Client**: `UpdateChecker` polls the public repo (no auth), parses the DMG asset URL. New `UpdateDownloader` downloads the DMG to tmp and hands it to `NSWorkspace.open` so Finder mounts it for the user to drag into Applications.

**Out of scope**: auto-replace running .app, code signing changes, progress UI, Sparkle integration.

## Repo Topology

| Repo | Visibility | Contents |
|------|-----------|----------|
| `yangshiqi/ZackEyes` | private | Source code, commits, tags, empty releases (internal record) |
| `yangshiqi/ZackEyes-release` | public | Releases with DMG assets only. `main` has a minimal README. Tags created by `gh release create --target main`. |

The public repo already exists.

## Release Pipeline

### Updated `make release` flow

Replace the current `release` target in `Makefile`. Ordered steps:

```
1. Sanity check         — current branch == master, worktree clean (no uncommitted changes)
2. Bump Info.plist      — CFBundleShortVersionString + CFBundleVersion
3. make dmg             — build the DMG before any commit, so a build failure leaves no half-bumped state
4. git commit           — "chore: bump version to X.Y.Z"
5. git tag vX.Y.Z + push origin master + push origin vX.Y.Z
6. gh release create vX.Y.Z (source repo) — empty, --notes "$NOTES"
7. gh release create vX.Y.Z .build/ZackEyes-X.Y.Z.dmg
       --repo yangshiqi/ZackEyes-release
       --target main
       --title "vX.Y.Z"
       --notes "$NOTES"
```

### Decisions

- **DMG built before commit** — most likely failure point goes first; failure is recoverable with `git checkout Resources/Info.plist`.
- **Same notes for both releases** — `NOTES=...` env var, defaults to `"Release vX.Y.Z"`.
- **`--target main` on public repo** — `gh` creates the tag in the public repo automatically against its `main` branch; no local clone needed.
- **No transactional rollback** between steps 4–7. Single-user MVP. If step 7 fails, user fixes (e.g. `gh auth refresh`) and re-runs `gh release create` manually.
- **Asset name unchanged** — `ZackEyes-X.Y.Z.dmg` from existing `dmg` target.

### Failure modes

| Step | Failure | Recovery |
|------|---------|----------|
| 1 | Dirty tree / wrong branch | Make aborts before any change |
| 3 | DMG build fails | `git checkout Resources/Info.plist` to undo bump |
| 5 | Push fails (network) | Fix network, re-run `git push && git push origin vX.Y.Z` manually |
| 6/7 | `gh` auth / quota / repo not found | Manual `gh release create ...` retry |

## Client: Update Detection

### `UpdateChecker` changes (`Sources/AppLib/Update/UpdateChecker.swift`)

Minimal diff:

```swift
private let repoName = "ZackEyes-release"   // was "ZackEyes"
```

Drop the `Authorization: Bearer <token>` header and the `ConfigStore().loadGitHubToken()` call. Public repo + 4 requests/day per user is well under GitHub's 60/hr anonymous limit.

**Note**: `ConfigStore.loadGitHubToken()` has no other callers (verified via grep at spec time — only `UpdateChecker.swift:64` references it), so the method itself is also deleted.

### Parse DMG asset

Extend the response model:

```swift
public struct GitHubAsset: Codable, Sendable {
    public let name: String
    public let browserDownloadURL: URL
    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
    }
}

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

Add to `UpdateChecker`:

```swift
@Published public var dmgURL: URL?   // first asset whose name ends in ".dmg"
```

Populated alongside `availableVersion` / `releaseURL` when a newer release is found. If no DMG asset is present (release in flight, manual upload pending), `dmgURL` stays nil and the menu item falls back to opening `releaseURL` in browser.

## Client: Download + Open

### New component `UpdateDownloader` (`Sources/AppLib/Update/UpdateDownloader.swift`)

```swift
@MainActor
public final class UpdateDownloader: ObservableObject {
    public enum State: Equatable {
        case idle
        case downloading
        case ready(URL)
        case failed(String)
    }

    @Published public var state: State = .idle

    public func download(from url: URL) async {
        // If already downloaded this version, skip the network call.
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent(url.lastPathComponent)
        if FileManager.default.fileExists(atPath: dest.path) {
            state = .ready(dest)
            NSWorkspace.shared.open(dest)
            return
        }

        state = .downloading
        do {
            let (tmpURL, _) = try await URLSession.shared.download(from: url)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tmpURL, to: dest)
            state = .ready(dest)
            NSWorkspace.shared.open(dest)   // Finder mounts the DMG window
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    public func reset() { state = .idle }
}
```

**Cache rule**: keyed on the DMG filename (`ZackEyes-X.Y.Z.dmg`). If the same version is re-clicked after download, no re-download. tmp directory is wiped by macOS on reboot — fine.

### Menu wiring (`Sources/AppLib/MenuBar/StatusBarMenu.swift`)

Add a `UpdateDownloader` injected alongside `UpdateChecker`. The menu item rewrites by `downloader.state`:

| `state` | Menu item title | Action |
|---------|-----------------|--------|
| `.idle` (with `availableVersion`) | `Update Available (vX.Y.Z)` | start download |
| `.downloading` | `Downloading vX.Y.Z…` | disabled |
| `.ready` | (item hides — DMG is open in Finder) | n/a |
| `.failed(msg)` | `Update Failed — Click to retry` | re-trigger download |

Click handler:

```swift
@objc private func updateClicked(_ sender: Any?) {
    guard let dmgURL = updateChecker.dmgURL else {
        // No asset yet — fall back to opening the release page
        if let url = updateChecker.releaseURL { NSWorkspace.shared.open(url) }
        return
    }
    Task { await downloader.download(from: dmgURL) }
}
```

**No NSAlert on failure** — menu item title carries the error state; user can click again.

### Notification behavior

Existing system notification on first detection (`UpdateChecker.onNewVersion`) keeps current behavior: title + body link. The notification's click action also routes through `downloader.download(...)` rather than opening the browser, when `dmgURL` is non-nil.

## Data Flow

```
Release time (developer machine):
  make release VERSION=0.3.0
    → bump Info.plist
    → make dmg                              → .build/ZackEyes-0.3.0.dmg
    → git commit + tag + push to ZackEyes (private)
    → gh release create v0.3.0 (private, no asset)
    → gh release create v0.3.0 (public ZackEyes-release, with DMG asset)

Detection (every 6h on user's machine):
  UpdateChecker
    → GET https://api.github.com/repos/yangshiqi/ZackEyes-release/releases/latest
    → parse tag_name + assets[*.dmg]
    → semantic compare
      → newer:
          set availableVersion, releaseURL, dmgURL
          fire onNewVersion → NotificationManager (once per version)

User clicks "Update Available":
  StatusBarMenu.updateClicked
    → UpdateDownloader.download(dmgURL)
      → check cache (tmp/<name>.dmg exists?)
        yes → NSWorkspace.open → Finder mounts DMG
        no  → URLSession.download
              → move to tmp/<name>.dmg
              → NSWorkspace.open → Finder mounts DMG
      → on error: state = .failed → menu item shows "Update Failed — Click to retry"
```

## Files Changed

| File | Change |
|------|--------|
| **Mod** `Makefile` | Rewrite `release` target: add sanity check, run `make dmg`, second `gh release create --repo ZackEyes-release` |
| **Mod** `Sources/AppLib/Update/UpdateChecker.swift` | Switch repo, drop token, parse `assets[]`, publish `dmgURL` |
| **New** `Sources/AppLib/Update/UpdateDownloader.swift` | Download + cache + open DMG |
| **Mod** `Sources/AppLib/MenuBar/StatusBarMenu.swift` | State-driven menu item title, route click to downloader |
| **Mod** `Sources/AppLib/Config/ConfigStore.swift` | Remove `loadGitHubToken()` (verified no other callers) |
| **Mod** `Sources/ZackEyes/AppDelegate.swift` | Construct `UpdateDownloader`, inject into `StatusBarMenu`, route notification tap to downloader |
| **New** `Tests/AppLibTests/UpdateCheckerAssetsTests.swift` | JSON decode test for `assets[]` parsing, DMG selection logic |
| **Mod** `ARCHITECTURE.md` | Document the two-repo split + download flow (1 short section) |
| **Mod** `CHANGELOG.md` | Entry for next release |

## Edge Cases

- **Release has no DMG asset yet** (in-flight upload, or manual `gh release` without asset) → `dmgURL` nil, menu click falls back to `NSWorkspace.open(releaseURL)` (current behavior).
- **DMG download interrupted** (laptop sleep, network drop) → URLSession throws → `state = .failed` → menu shows retry. Partial file in tmp not promoted (move only happens on success).
- **User clicks twice during download** → Task is in-flight; second click hits the disabled menu item, no-op.
- **Same version downloaded earlier this session, user re-clicked** → cache hit, immediate `NSWorkspace.open`.
- **Anonymous rate-limited** (60/hr/IP) → 403 from GitHub, current code already treats as silent failure, retry next timer.
- **DMG asset name doesn't end in `.dmg`** → asset filter returns nil, falls back to release page.
- **Multiple `.dmg` assets** (won't happen with current `make dmg`, but defensively) → take first.

## Testing

**Unit (CI)**:
- `UpdateChecker` JSON decode includes `assets[]`
- DMG asset selection picks first `.dmg`-suffixed asset, returns nil otherwise
- `UpdateChecker.isNewer` tests unchanged

**Manual (developer machine, end-to-end)**:
- Bump local `Resources/Info.plist` to a fake low version (e.g. `0.0.1`)
- Run app → menu shows `Update Available (vX.Y.Z)` where X.Y.Z is the latest public release
- Click → DMG downloads → Finder mounts the disk image with the drag-to-Applications layout
- Restore Info.plist before committing

**Release smoke test**:
- First real run of new `make release` should be a patch bump (e.g. 0.2.8 → 0.2.9) so a failure has minimal blast radius. Verify both private and public release pages render correctly and the DMG is downloadable from the public asset URL.
