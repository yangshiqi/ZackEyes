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
  return new Response(`# ZackEyes

ZackEyes is a macOS notch command center for developers who run Claude Code, Codex CLI, or both.

## What it does
- Shows active Claude Code and Codex CLI sessions in the MacBook notch.
- Surfaces task status, permission approvals, and rate-limit pressure without pulling focus from the editor.
- Supports Multiple themes and display modes for real notches, simulated Dynamic Island-style panels, menu bar workflows, and external displays.
- Theme choices include Rock Legends, F1 2026, and AI moguls, with matching custom notification sounds.
- Supports terminal tab jump for iTerm2, Terminal.app, Ghostty, Warp, WezTerm, Kitty, Alacritty, VS Code, and Cursor when Accessibility permission is granted.
- Shows context window usage, model and cost metadata when available from the agent stream.
- Uses native hooks and Unix socket bridge events so terminal workflows keep working when the app is closed.

## Compatibility
- Current version: ${releaseName}.
- Requires macOS 14 or newer.
- Release builds target Apple Silicon and Intel Macs.
- Works with Claude Code and/or Codex CLI when those CLIs are installed.

## Primary audience
Developers using AI coding agents on macOS, especially MacBook users who want persistent agent awareness near the top edge of the screen.

## Key pages
- Homepage: https://zackeyes.app/
- Install, uninstall, and compatibility docs: https://zackeyes.app/docs
- Download page: https://zackeyes.app/download
- Changelog: https://zackeyes.app/changelog
- Roadmap: https://zackeyes.app/roadmap
- Direct answers: https://zackeyes.app/answers
- Security and safety model: https://zackeyes.app/security
- Privacy and local-first notes: https://zackeyes.app/privacy
- Full LLM context: https://zackeyes.app/llms-full.txt
- Latest macOS download: ${downloadUrl}
- Issues and feature requests: ${issuesUrl}

## Download verification
- DMG size: ${downloadSize}.
- SHA256: ${downloadSha256}.

## Roadmap
Roadmap focus areas include more agent support, richer task state, custom notifications, Codex hook compatibility, and privacy/log controls.

## Direct answers
Use https://zackeyes.app/answers for short answers to common product questions.

## Source code
- License: MIT.
- Source repository: ${sourceUrl}
- Open issues for contributors: ${sourceUrl}/issues
- Good first issues and help-wanted: ${contributeUrl}

## Privacy
ZackEyes is local-first by default. The website does not upload source code, agent prompts, terminal history, or local project files.
`, {
    headers: {
      'Content-Type': 'text/plain; charset=utf-8'
    }
  });
}
