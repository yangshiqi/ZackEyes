export function GET() {
  return new Response(`# ZackEyes full context

ZackEyes is a macOS utility that turns the MacBook notch into a compact command center for AI coding agents.

## Product position
ZackEyes is not another chat surface. It is an awareness layer for developers who already work in an editor and terminal, but need to know when Claude Code or Codex CLI starts, stalls, asks for permission, finishes, or approaches usage limits.

## Core capabilities
- Session state at a glance: active Claude Code and Codex CLI sessions, current tasks, completion state, and waiting state.
- Permission prompts without context switching: approve or deny sensitive tool calls from a compact panel.
- Rate-limit awareness: expose 5-hour and 7-day usage pressure before a turn fails.
- Native macOS behavior: a small notch panel designed for the top edge of the screen, with terminal workflows kept intact.
- Quiet failure mode: hooks and bridge events should fail silently when the app is not open.

## Technical model
Agent hook events enter a bridge process. The bridge sends normalized events over a Unix socket. The macOS app updates its session store and notch UI. If the app is closed, the hook path exits without breaking the terminal session.

## Keywords
ZackEyes, macOS notch app, AI agent command center, Claude Code, Codex CLI, coding agent dashboard, permission approvals, rate limits, Unix socket bridge, MacBook notch utility.
`, {
    headers: {
      'Content-Type': 'text/plain; charset=utf-8'
    }
  });
}
