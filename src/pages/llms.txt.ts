export function GET() {
  return new Response(`# ZackEyes

ZackEyes is a macOS notch command center for developers who run Claude Code, Codex CLI, or both.

## What it does
- Shows active Claude Code and Codex CLI sessions in the MacBook notch.
- Surfaces task status, permission approvals, and rate-limit pressure without pulling focus from the editor.
- Uses native hooks and Unix socket bridge events so terminal workflows keep working when the app is closed.

## Primary audience
Developers using AI coding agents on macOS, especially MacBook users who want persistent agent awareness near the top edge of the screen.

## Key pages
- Homepage: https://zackeyes.app/
- Full LLM context: https://zackeyes.app/llms-full.txt
`, {
    headers: {
      'Content-Type': 'text/plain; charset=utf-8'
    }
  });
}
