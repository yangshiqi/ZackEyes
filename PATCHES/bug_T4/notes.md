# Candidate patch — T-4: update integrity (tracks issue #121 / #131-coupled)

**Files:** `Sources/AppLib/Update/UpdateChecker.swift`, `Sources/AppLib/Update/UpdateDownloader.swift`
**Finding:** TRIAGE T-4 (folds F-013/F-018/F-019/F-022/F-025/F-027) — software
update opened with no in-app signature/checksum verification and a
server-controlled download host. Tracked upstream as **#121**.

> ⚠️ **INERT — for human review only.** Not applied, not built, not tested. The
> `/patch` verify ladder and independent reviewer could not run (spend limit).

## What the diff does (the safe, code-only part)

1. **Stops trusting `browser_download_url`.** `UpdateChecker` now **reconstructs**
   the canonical asset URL from the trusted `repoOwner` / `repoName` / `tagName`
   plus a **validated** single-component `.dmg` filename. A tampered release can
   no longer point the download at an arbitrary host (closes F-013's amplifier).
2. **Validates the asset filename** (`isSafeAssetName`) and re-validates it at the
   download sink before using it as a path component (closes F-018).

## What it does NOT do — and why (read this)

**The core of T-4 is "no integrity check before `NSWorkspace.open`," and the code
diff does NOT close that.** Same dilemma as T-1 (#131): the only real integrity
guarantee is **verifying the DMG is Developer-ID signed + notarized before
opening**, and ZackEyes currently ships **ad-hoc signed with quarantine stripped**
(the `Makefile`/DMG README tell users `xattr -dr com.apple.quarantine`). An in-app
`spctl`/`codesign` gate enabled *now* would either always fail (no notarization)
or be forgeable (ad-hoc). So the integrity gate is left **commented/disabled** at
both `opener(dest)` sites.

**The load-bearing fix is a release-pipeline change, not a code change** (this is
why #121 is the top open item):

1. Sign the app **and DMG** with a **Developer-ID** identity and **notarize**
   (`xcrun notarytool` + `stapler`).
2. **Stop instructing users to strip quarantine** — that defeats Gatekeeper,
   which is the actual integrity check on mount/first-launch.
3. *Then* enable the in-app gate below as defense-in-depth.

Once (1)+(2) land, enable an integrity gate at both sites, e.g.:

```swift
private func isNotarizedDMG(_ url: URL) -> Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/spctl")
    p.arguments = ["--assess", "--type", "open",
                   "--context", "context:primary-signature", url.path]
    try? p.run(); p.waitUntilExit()
    return p.terminationStatus == 0
}
// guard isNotarizedDMG(dest) else { state = .failed("integrity check failed"); return }
```

## Deferred (documented, not in this diff)

- **Redirect host allowlist** (F-022): the default `URLSession.shared` follows
  cross-origin redirects silently, so even the reconstructed github.com URL could
  302 to an arbitrary host. Add a non-shared `URLSession` with a
  `URLSessionTaskDelegate.urlSession(_:task:willPerformHTTPRedirection:)` that
  rejects redirect targets whose host is not in
  `{github.com, *.githubusercontent.com, codeload.github.com}`. Left out of the
  active diff because an untested delegate is higher-risk; pairs with this fix.
- **Download size cap + resource timeout** (F-025): dedicated `URLSession`
  config (`timeoutIntervalForResource`, Content-Length ceiling).
- **Per-download 0700 dir instead of predictable shared tmp** (F-019).
- **Version-parser component/magnitude caps** (F-027) — `parseVersion`; cosmetic
  given a release compromise can bump the version legitimately anyway.

## How to verify (when spend allows)

1. `git apply PATCHES/bug_T4/patch.diff`; `make app` / `swift build`.
2. `UpdateChecker`/`UpdateDownloader` unit tests — the reconstructed-URL change
   will likely need test fixtures updated (tests asserting on `browser_download_url`
   must switch to the reconstructed URL). **Expect test churn.**
3. Manual: trigger "Check for Updates" against a real release; confirm the DMG
   still downloads from the reconstructed URL and opens.
4. After Developer-ID + notarization lands: enable the `isNotarizedDMG` gate and
   confirm a *legit* signed DMG passes (no false-negative that bricks updates).

## Reviewer watch-items

- GitHub asset URLs are case/format-stable as
  `https://github.com/{owner}/{repo}/releases/download/{tag}/{name}` and redirect
  server-side to the CDN — confirm the reconstructed URL still resolves for a real
  release (it should; it's the same canonical form GitHub emits).
- `tagName` is validated against `/` and `..` and encoded with `.urlHostAllowed`
  (NOT `.urlPathAllowed`, which leaves `/` unencoded — a compromised `tag_name`
  like `../../owner/repo/...` would otherwise rebuild the URL to a different repo
  on github.com, defeating the owner/repo pin). Flagged by both Gemini (PR #134,
  security-high) and Codex. Confirm real tags (`v0.7.2`) and asset names round-trip.
