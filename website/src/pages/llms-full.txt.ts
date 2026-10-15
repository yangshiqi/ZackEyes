import { featureVersion, journalVersion } from '../lib/product-plans.mjs';
import {
  appVersion,
  releaseName,
  downloadUrl,
  issuesUrl,
  downloadSize,
  downloadSha256,
  sourceUrl,
  contributeUrl
} from '../lib/release.mjs';

export function GET() {
  return new Response(`# ZackEyes full context

ZackEyes is a macOS utility that turns the MacBook notch into a compact command center for AI coding agents.

## Product position
ZackEyes is not another chat surface. It is an awareness layer for developers who already work in an editor and terminal, but need to know when Claude Code or Codex CLI starts, stalls, asks for permission, finishes, or approaches usage limits.

## Core capabilities
- Session state at a glance: active Claude Code and Codex CLI sessions, current tasks, completion state, and waiting state.
- Permission prompts without context switching: approve or deny sensitive tool calls from a compact panel.
- Rate-limit awareness: expose 5-hour and 7-day usage pressure before a turn fails.
- Multiple themes: adapt the notch panel to different desktop styles while keeping agent state readable. Theme choices include Rock Legends, F1 2026, AI Moguls, and Crayon Shin-chan, each with custom notification sounds.
- Display modes: support the physical MacBook notch, simulated Dynamic Island-style panels on Macs without a notch, menu bar workflows, and external display setups.
- terminal tab jump: click a session card to activate matching sessions in iTerm2, Terminal.app, Ghostty, Warp, WezTerm, Kitty, Alacritty, VS Code, and Cursor when Accessibility permission is granted.
- Context window usage: session cards can show context window usage, model and cost metadata, and per-agent usage pressure.
- Working-tree and port signals: each session card shows the lowest LISTEN port opened anywhere in that agent's process subtree, the git branch, and the uncommitted file count. Ports come from kernel syscalls (sysctl and proc_pidfdinfo) rather than lsof, so no subprocess is spawned.
- Subagent and compaction visibility: the card shows what a dispatched Claude subagent is working on rather than only that one is running, and marks context compaction while it runs and for a short window after it completes.
- Daily token and cost tracking: a Today row totals token spend and USD cost across Claude and Codex with a 7-day sparkline; model pricing is bundled and computed locally, so no API key or cloud upload is required.
- Controls: a unified Settings window (opened from the notch gear or the menu-bar icon) collects the custom global hotkey, Dynamic Island visibility, quota presentation, and a Preferred quota source that picks whether the compact pill favors Claude or Codex; in-app DMG download handles updates.
- Native macOS behavior: a small notch panel designed for the top edge of the screen, with terminal workflows kept intact.
- Quiet failure mode: hooks and bridge events should fail silently when the app is not open.

## Version and changelog
- Current version: ${releaseName}.
- Full release notes and dates live on the changelog, kept current every release: https://zackeyes.vercel.app/changelog
- GitHub Releases: https://github.com/yangshiqi/ZackEyes-release/releases

## Install
1. Download the current DMG from GitHub Releases.
2. Open the DMG and drag ZackEyes into Applications.
3. Verify the official checksum before first launch. The app is ad-hoc signed and not notarized. After verifying the checksum and trusting the official download, follow the installer README: xattr -dr com.apple.quarantine /Applications/ZackEyes.app. Then open it and start a fresh Claude Code or Codex CLI session.

## Download verification
- Download page: https://zackeyes.vercel.app/download
- DMG size: ${downloadSize}.
- SHA256: ${downloadSha256}.

## Uninstall
First use Settings → Integrations → Uninstall Integrations… while the app is installed, then quit and delete the app. Keep ~/.zackeyes or copy it before deletion: removing it erases Usage history, SSH host configuration, settings and existing journal files.
1. While ZackEyes is installed, use Settings → Integrations → Uninstall Integrations… .
2. Quit ZackEyes and delete it from Applications.
3. Keep ~/.zackeyes to retain data, or copy it before deletion; it includes Usage history and SSH host configuration.

## Compatibility
- The DMG app is ad-hoc signed, not Developer ID signed or notarized. Verify the official checksum, install into Applications, and follow the installer README for first launch.
- macOS requirement: macOS 14 or newer.
- CPU architecture: Apple Silicon and Intel Macs.
- Agents: Claude Code and/or Codex CLI. ZackEyes installs hooks for whichever CLI it finds and skips missing agents.
- Codex caveat: Codex sessions launched before hooks are installed may still be detected through JSONL tailing, but full hook-driven behavior applies to new Codex threads.

## Troubleshooting
- If macOS says ZackEyes cannot be opened, verify the official installer checksum and follow the first-launch instructions in its README.
- If Claude or Codex sessions do not appear, confirm the CLI is installed and start a fresh agent session.
- If permission requests do not show in the notch, confirm ZackEyes is running and the relevant hook file contains a zackeyes-managed command.
- To reinstall hooks, use Settings → Integrations → Repair Hooks, then start a fresh agent session.

## Model compatibility (v0.9.7)
- Included in v0.9.7: Codex GPT-6.1 Sol / GPT-6 Astra compatibility, PR #252: https://github.com/yangshiqi/ZackEyes/pull/252. Observed effort, request-aware service-tier/long-request estimates, concurrent tools, interruptions, subagents and compaction events. No native steering or second runtime; ZackEyes never reads or modifies Codex config.toml.
- Included in v0.9.7: Claude Fable 5/5.1, Opus 5/5.5 and Sonnet 5/5.5 compatibility, PR #258: https://github.com/yangshiqi/ZackEyes/pull/258. Observed effort/model changes, actual fast-response pricing, 5-minute/1-hour cache writes, and separate tool/API failure handling. Child completion does not notify parent completion.
- Effort requires live CLI metadata; a Claude Code 2.1.295 probe supplied it on Stop after the reply. Startup model recovery does not invent effort. Daily totals use API list-price estimates, not subscription invoices; unknown pricing remains unpriced. Codex estimates may lack request metadata or earlier history; Claude session-card cost uses the CLI-reported total. Compatibility notes: https://zackeyes.vercel.app/docs#model-compatibility

## Features added in v${featureVersion}
The published v${appVersion} download includes opt-in supported Claude question answers with timeout/terminal fallback, read-only SSH remote observation for up to eight hosts, a synthetic demo fleet, private local usage history (7/30/90 days) and per-agent stale quota hints. These features shipped in v${featureVersion}. Prebuilt SSH helpers for Linux/macOS x86_64/arm64 ship with the release. The version-matched installer selects the platform and verifies SHA256; no remote Swift toolchain is required. Remote questions stay in the remote terminal; SSH transmits session metadata, not prompts/replies/tool arguments. Usage charts cover complete local days through yesterday, with full dates on hover. Background daily settlement runs after 03:00 with startup catch-up; older history requires explicit import with pause/resume. Settings reads saved daily archives without rescanning transcripts. Local history stores counts, bounded names, hashed identities and timing metadata, not conversation text.

## Roadmap
- v${journalVersion} planned: finish setup, scheduling and delivery for the daily work journal. Its local pipeline exists in development, but the public generation menu is hidden and it is excluded from v${featureVersion}.
- Explore more agent support and local logs controls.
- Completed development work and future plans: https://zackeyes.vercel.app/roadmap

## Direct answers
- What is ZackEyes? A macOS notch command center for Claude Code and Codex CLI.
- Is ZackEyes local-first? Yes, it is local-first by default and the website does not upload source code or prompts.
- Does ZackEyes support Codex CLI? Yes.
- Does ZackEyes support multiple themes? Yes, including display modes for real notches, simulated islands, menu bar workflows, and external displays.
- How do I install ZackEyes? Download the DMG, drag the app into Applications, and launch it.
- Where do I report issues? Use GitHub Issues on the public release repository.
- Direct answers page: https://zackeyes.vercel.app/answers

## Technical model
Agent hook events enter a bridge process. The bridge sends normalized events over a Unix socket. The macOS app updates its session store and notch UI. If the app is closed, the hook path exits without breaking the terminal session.

## Security and safety model
- Security and safety model: https://zackeyes.vercel.app/security
- Hook writes are local and identifiable with the string zackeyes.
- ZackEyes backs up ~/.claude/settings.json and ~/.codex/hooks.json before writing managed entries.
- ZackEyes should never read or write ~/.codex/config.toml.
- Controlled bridge failures fail quietly, write nothing to stdout, exit 0, and leave the agent terminal workflow in control.

## Release and feedback
- Latest macOS download: ${downloadUrl}
- Issues and feature requests (user-facing): ${issuesUrl}

## Source code
- License: MIT.
- ZackEyes is open source. The source code, including the macOS app, the bridge CLI, and this website, lives in a single monorepo.
- Source repository: ${sourceUrl}
- Developer issues and pull requests: ${sourceUrl}/issues
- Good first issues and help-wanted: ${contributeUrl}
- The user-facing download/issues channel (above) intentionally stays separate from the source repo: end users file install/compatibility reports without needing to interact with the codebase.

## FAQ and privacy
- Compatibility: ZackEyes is for modern macOS desktop workflows and is distributed as a DMG installer.
- Data posture: ZackEyes is local-first by default. It does not require an account to show local agent status.
- Website privacy: the website does not upload source code, agent prompts, terminal history, or local project files.
- Local files and settings: ZackEyes may use local configuration and agent hook files such as ~/.zackeyes, ~/.claude/settings.json, and ~/.codex/hooks.json.
- Public price refresh: bundled prices work offline; the app fetches GitHub pricing.json at startup and every 24 hours without uploading conversation content.
- Analytics: the current website does not add a third-party analytics script.
- Public feedback: bugs, install issues, compatibility reports, and feature requests go through GitHub Issues.
- Privacy page: https://zackeyes.vercel.app/privacy
- Docs page: https://zackeyes.vercel.app/docs

## Keywords
ZackEyes, macOS notch app, AI agent command center, Claude Code, Codex CLI, coding agent dashboard, permission approvals, rate limits, Unix socket bridge, MacBook notch utility, local-first macOS app, AI coding agent FAQ, install ZackEyes, uninstall ZackEyes, ZackEyes changelog.
`, {
    headers: {
      'Content-Type': 'text/plain; charset=utf-8'
    }
  });
}
