import {
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
- Multiple themes: adapt the notch panel to different desktop styles while keeping agent state readable. Theme choices include Rock Legends, F1 2026, and AI moguls, each with custom notification sounds.
- Display modes: support the physical MacBook notch, simulated Dynamic Island-style panels on Macs without a notch, menu bar workflows, and external display setups.
- terminal tab jump: click a session card to activate matching sessions in iTerm2, Terminal.app, Ghostty, Warp, WezTerm, Kitty, Alacritty, VS Code, and Cursor when Accessibility permission is granted.
- Context window usage: session cards can show context window usage, model and cost metadata, and per-agent usage pressure.
- Daily token and cost tracking: a Today row totals token spend and USD cost across Claude and Codex with a 7-day sparkline; model pricing is bundled and computed locally, so no API key or cloud upload is required.
- Controls: a unified Settings window (opened from the notch gear or the menu-bar icon) collects the custom global hotkey, Dynamic Island visibility, quota presentation, and a Preferred quota source that picks whether the compact pill favors Claude or Codex; in-app DMG download handles updates.
- Native macOS behavior: a small notch panel designed for the top edge of the screen, with terminal workflows kept intact.
- Quiet failure mode: hooks and bridge events should fail silently when the app is not open.

## Version and changelog
- Current version: ${releaseName}.
- Full release notes and dates live on the changelog, kept current every release: https://zackeyes.app/changelog
- GitHub Releases: https://github.com/yangshiqi/ZackEyes-release/releases

## Install
1. Download the current DMG from GitHub Releases.
2. Open the DMG and drag ZackEyes into Applications.
3. Launch ZackEyes and keep Claude Code or Codex CLI running in the normal terminal workflow.
4. If macOS blocks first launch, approve ZackEyes in System Settings and reopen it.

## Download verification
- Download page: https://zackeyes.app/download
- DMG size: ${downloadSize}.
- SHA256: ${downloadSha256}.

## Uninstall
1. Quit ZackEyes.
2. Delete ZackEyes from Applications.
3. Review ~/.claude/settings.json and ~/.codex/hooks.json for hook commands containing "zackeyes".
4. Remove ~/.zackeyes only if you want to clear local ZackEyes settings.

## Compatibility
- macOS requirement: macOS 14 or newer.
- CPU architecture: Apple Silicon and Intel Macs.
- Agents: Claude Code and/or Codex CLI. ZackEyes installs hooks for whichever CLI it finds and skips missing agents.
- Codex caveat: Codex sessions launched before hooks are installed may still be detected through JSONL tailing, but full hook-driven behavior applies to new Codex threads.

## Troubleshooting
- If macOS says ZackEyes cannot be opened, approve the app from System Settings and reopen it.
- If Claude or Codex sessions do not appear, confirm the CLI is installed and start a fresh agent session.
- If permission requests do not show in the notch, confirm ZackEyes is running and the relevant hook file contains a zackeyes-managed command.
- To reinstall hooks, remove stale hook entries containing zackeyes and reopen ZackEyes.

## Roadmap
- Process and session insight.
- More agent support.
- Local logs controls.
- Roadmap page: https://zackeyes.app/roadmap

## Direct answers
- What is ZackEyes? A macOS notch command center for Claude Code and Codex CLI.
- Is ZackEyes local-first? Yes, it is local-first by default and the website does not upload source code or prompts.
- Does ZackEyes support Codex CLI? Yes.
- Does ZackEyes support multiple themes? Yes, including display modes for real notches, simulated islands, menu bar workflows, and external displays.
- How do I install ZackEyes? Download the DMG, drag the app into Applications, and launch it.
- Where do I report issues? Use GitHub Issues on the public release repository.
- Direct answers page: https://zackeyes.app/answers

## Technical model
Agent hook events enter a bridge process. The bridge sends normalized events over a Unix socket. The macOS app updates its session store and notch UI. If the app is closed, the hook path exits without breaking the terminal session.

## Security and safety model
- Security and safety model: https://zackeyes.app/security
- Hook writes are local and identifiable with the string zackeyes.
- ZackEyes backs up ~/.claude/settings.json and ~/.codex/hooks.json before writing managed entries.
- ZackEyes should never read or write ~/.codex/config.toml.
- Controlled bridge failures fail quietly, write nothing to stdout, exits 0, and leave the agent terminal workflow in control.

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
- Analytics: the current website does not add a third-party analytics script.
- Public feedback: bugs, install issues, compatibility reports, and feature requests go through GitHub Issues.
- Privacy page: https://zackeyes.app/privacy
- Docs page: https://zackeyes.app/docs

## Keywords
ZackEyes, macOS notch app, AI agent command center, Claude Code, Codex CLI, coding agent dashboard, permission approvals, rate limits, Unix socket bridge, MacBook notch utility, local-first macOS app, AI coding agent FAQ, install ZackEyes, uninstall ZackEyes, ZackEyes changelog.
`, {
    headers: {
      'Content-Type': 'text/plain; charset=utf-8'
    }
  });
}
