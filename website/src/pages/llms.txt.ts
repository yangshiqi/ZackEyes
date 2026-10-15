import { candidateVersion, journalVersion } from '../lib/product-plans.mjs';
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
  return new Response(`# ZackEyes

ZackEyes is a macOS notch command center for developers who run Claude Code, Codex CLI, or both.

## What it does
- Shows active Claude Code and Codex CLI sessions in the MacBook notch.
- Surfaces task status, permission approvals, and rate-limit pressure without pulling focus from the editor.
- Supports Multiple themes and display modes for real notches, simulated Dynamic Island-style panels, menu bar workflows, and external displays.
- Theme choices include Rock Legends, F1 2026, AI Moguls, and Crayon Shin-chan, with matching custom notification sounds.
- Supports terminal tab jump for iTerm2, Terminal.app, Ghostty, Warp, WezTerm, Kitty, Alacritty, VS Code, and Cursor when Accessibility permission is granted.
- Shows context window usage, model and cost metadata when available from the agent stream.
- Shows per-session LISTEN ports, git branch, and uncommitted file count on the session card; ports are read from kernel syscalls rather than lsof, so no subprocess is spawned.
- Shows what a dispatched Claude subagent is working on, and marks context compaction while it runs and shortly after it finishes.
- Tracks daily token spend and USD cost across Claude and Codex in a Today row with a 7-day sparkline; model pricing is bundled and computed locally, so no API key or cloud upload is needed.
- Uses native hooks and Unix socket bridge events so terminal workflows keep working when the app is closed.

## Compatibility
- The DMG app is ad-hoc signed, not Developer ID signed or notarized. Verify the official checksum, install into Applications, and follow the installer README for first launch.
- Current version: ${releaseName}.
- Requires macOS 14 or newer.
- Release builds target Apple Silicon and Intel Macs.
- Works with Claude Code and/or Codex CLI when those CLIs are installed.

## Primary audience
Developers using AI coding agents on macOS, especially MacBook users who want persistent agent awareness near the top edge of the screen.

## Key pages
- Homepage: https://zackeyes.vercel.app/
- Install, uninstall, and compatibility docs: https://zackeyes.vercel.app/docs
- Download page: https://zackeyes.vercel.app/download
- Changelog: https://zackeyes.vercel.app/changelog
- Roadmap: https://zackeyes.vercel.app/roadmap
- Direct answers: https://zackeyes.vercel.app/answers
- ZackEyes vs Vibe Island comparison: https://zackeyes.vercel.app/vs-vibe-island
- ZackEyes vs Hallmonitor comparison: https://zackeyes.vercel.app/vs-hallmonitor
- ZackEyes vs open-vibe-island comparison: https://zackeyes.vercel.app/vs-open-vibe-island
- Security and safety model: https://zackeyes.vercel.app/security
- Privacy and local-first notes: https://zackeyes.vercel.app/privacy
- Full LLM context: https://zackeyes.vercel.app/llms-full.txt
- Latest macOS download: ${downloadUrl}
- Issues and feature requests: ${issuesUrl}

## Download verification
- DMG size: ${downloadSize}.
- SHA256: ${downloadSha256}.

## Model compatibility (v0.9.7)
Included in v0.9.7: Codex GPT-6.1 Sol / GPT-6 Astra compatibility (PR #252) and Claude Fable 5/5.1, Opus 5/5.5 and Sonnet 5/5.5 compatibility (PR #258). They add observed effort, current pricing and lifecycle handling. Effort requires live CLI metadata; daily costs are API list-price estimates, not subscription invoices. Details: https://zackeyes.vercel.app/docs#model-compatibility

## Development builds (merged, not yet released)
The published download remains v${appVersion}. Master/source builds also include opt-in supported Claude question answers with timeout/terminal fallback, read-only SSH remote observation for up to eight hosts, a synthetic demo fleet, private local usage history (7/30/90 days) and per-agent stale quota hints. They form the v${candidateVersion} release candidate and are not yet in the published download. Remote questions stay in the remote terminal; SSH transmits session metadata, not prompts/replies/tool arguments. Usage charts cover complete local days through yesterday, with full dates on hover. Background daily settlement runs after 03:00 with startup catch-up; older history requires explicit import with pause/resume. Settings reads saved daily archives without rescanning transcripts. Local history stores counts, bounded names, hashed identities and timing metadata, not conversation text.

## Roadmap
- v${journalVersion} planned: finish setup, scheduling and delivery for the daily work journal. Its local pipeline exists in development, but the public generation menu is hidden and it is excluded from v${candidateVersion}.
- Explore more agent support and local logs controls.
- Completed development work and future plans: https://zackeyes.vercel.app/roadmap

## Direct answers
Use https://zackeyes.vercel.app/answers for short answers to common product questions.

## Source code
- License: MIT.
- Source repository: ${sourceUrl}
- Open issues for contributors: ${sourceUrl}/issues
- Good first issues and help-wanted: ${contributeUrl}

## Privacy
The app fetches public GitHub update metadata and refreshes bundled model prices online at startup and every 24 hours. Cost conversion stays local; prompts and replies are not uploaded by these requests.
ZackEyes is local-first by default. The website does not upload source code, agent prompts, terminal history, or local project files.
`, {
    headers: {
      'Content-Type': 'text/plain; charset=utf-8'
    }
  });
}
