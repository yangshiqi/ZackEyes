<!--
Draft release notes for v0.8.0. NOT the changelog — the live changelog lives at
website/src/pages/changelog.astro and is written automatically at release time.

To cut the release (when ready, from a clean master):
  make release VERSION=0.8.0 NOTES="$(cat RELEASE-NOTES-v0.8.0.md | sed -n '/^ZackEyes 0.8.0/,$p')"
(or paste the body below into NOTES). NOTES must be English — `make release`
rejects CJK. Delete this file after the release lands.
-->

ZackEyes 0.8.0 — security-hardening release on top of the new real Dynamic Island.

Added:
- Real Dynamic Island — on MacBooks with a notch, the live panel now merges into the physical Dynamic Island instead of a separate simulated pill, and falls back to the screen's safe-area inset when the menu bar is auto-hidden.

Fixed:
- Token usage no longer freezes and then jumps during long deep-research and workflow runs: the 5-hour percentage is interpolated from transcript token growth between updates, so it moves smoothly and feeds a steadier burn-rate estimate.
- Codex usage now handles the per-model rate limits that recent Codex versions report, so a freshly-reset per-model limit at 0% no longer hides your higher account-level usage.
- The 5-hour reset countdown stays visible alongside the burn-rate ETA badge instead of being replaced by it.

Security (hardens the local attack surface against other users on the same Mac and untrusted project files):
- The local control socket that gates tool-permission prompts now authenticates its peer, lives in an owner-only directory instead of world-connectable /tmp, and times out cleanly; the bridge verifies it is talking to the real ZackEyes.
- The offline event spool is written owner-only, replays only a fixed allowlist of event types, and no longer trusts attacker-writable on-disk data.
- Terminal titles and notifications are sanitized at the escape-sequence boundary, and session identifiers are validated before use as cache filenames, preventing path traversal.
- The diagnostics export redacts third-party status-line commands, the username (any case), and the hostname.
- "Allow Always" no longer remembers high-risk tools such as Bash — those still ask every time.
- Read caps and overflow/growth guards were added across the Codex token scan, task extraction, token counting, and the file tailer to prevent runaway resource use.
- The updater reconstructs the download URL from trusted components, rejects downgrades, downloads into a private owner-only directory, and verifies the file is a real disk image before opening it.

Note: distributed as an ad-hoc-signed build — on first launch, right-click the app and choose Open (Gatekeeper "unidentified developer"). Developer-ID signing and notarization are planned for a later release.
