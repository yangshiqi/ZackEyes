import Foundation
import BridgeLib
import Shared

// MARK: - Bridge invariant
//
// The bridge must NEVER leave a user-visible footprint on Claude Code,
// regardless of what goes wrong. Every failure path exits 0 with no
// stdout/stderr. Claude Code's newer builds display any non-zero hook
// exit as a terminal error message, which we don't want — socket
// unreachable (the app isn't running) is an expected state, not a bug
// to surface.
//
// The only path that writes to stdout is PermissionRequest success,
// where Claude Code expects a JSON response. If that socket round-trip
// fails, we still exit 0 with empty stdout — Claude Code treats the
// missing response as "no hook preference" and falls back to its own
// default permission prompt.

// MARK: - Step 1: Read stdin

let inputData = FileHandle.standardInput.availableData
guard !inputData.isEmpty else {
    exit(0)
}

// MARK: - Step 2: Parse --event and optional --agent

// Accepted shapes:
//   ["bridge", "--event", "<EventName>"]                        (legacy — agent defaults to "claude")
//   ["bridge", "--event", "<EventName>", "--agent", "<Agent>"]  (current)
//   ["bridge", "--agent", "<Agent>", "--event", "<EventName>"]  (flag order tolerated)
//
// Anything else: exit 0 silently (per the bridge invariant).
let args = CommandLine.arguments
var eventName: String? = nil
var agentName: String = "claude"  // legacy default
var idx = 1
while idx < args.count {
    let flag = args[idx]
    let next = idx + 1 < args.count ? args[idx + 1] : nil
    switch flag {
    case "--event":
        guard let value = next else { exit(0) }
        eventName = value
        idx += 2
    case "--agent":
        guard let value = next else { exit(0) }
        agentName = value
        idx += 2
    default:
        exit(0)
    }
}
guard let eventName, !eventName.isEmpty else { exit(0) }
// Coerce unknown agent strings to "claude" — keeps the invariant of never
// blocking on bad input. If a future build adds --agent values we don't know
// about yet, it falls through to the Claude code path rather than dying.
if agentName != "claude" && agentName != "codex" {
    agentName = "claude"
}

// MARK: - Step 3: Inject _bridge_event + _bridge_agent into JSON payload

guard var jsonObject = try? JSONSerialization.jsonObject(with: inputData) as? [String: Any] else {
    exit(0)
}
jsonObject["_bridge_event"] = eventName
jsonObject["_bridge_agent"] = agentName
// Pass parent PID (claude/codex process) so the app can locate the terminal
jsonObject["_bridge_ppid"] = Int(getppid())

guard let enrichedData = try? JSONSerialization.data(withJSONObject: jsonObject) else {
    exit(0)
}

// Ensure trailing newline (newline-delimited JSON)
var payloadData = enrichedData
if payloadData.last != UInt8(ascii: "\n") {
    payloadData.append(UInt8(ascii: "\n"))
}

// MARK: - Step 3.5: Refresh terminal tab title (OSC 2)
// Best-effort; any failure is silent and does not affect the socket path.
TerminalTitleWriter.writeIfPossible(
    sessionId: jsonObject["session_id"] as? String,
    cwd: jsonObject["cwd"] as? String,
    prompt: jsonObject["prompt"] as? String,
    ppid: getppid()
)

// MARK: - Step 4 & 5: Create client and route by event

let client = BridgeSocketClient(path: "/tmp/zackeyes.sock")

switch eventName {
case "PermissionRequest":
    // AskUserQuestion is dual-surface (popup + CC's native terminal UI).
    // We MUST NOT block-and-respond here — sending an "allow" decision
    // tells CC to skip its terminal UI and treat the tool as auto-handled,
    // which causes CC to immediately return an empty answer and fire
    // PostToolUse, clearing the popup before the user can interact.
    // Fire-and-forget instead so CC falls back to its native flow; the
    // app still gets the event for awareness via the same socket write.
    if (jsonObject["tool_name"] as? String) == "AskUserQuestion" {
        _ = client.sendFireAndForget(data: payloadData)
        exit(0)
    }
    // Blocking: send and wait for a response from the app. Pass 0 so the
    // read has no timeout — the user may take as long as they want to
    // answer the question, and we shouldn't abandon the prompt out from
    // under them. If the user kills Claude Code (SIGINT), the bridge dies
    // with it and the socket closes cleanly on the app side.
    //
    // On socket failure: exit 0 with empty stdout. Claude Code treats
    // the missing response as "no hook preference" and falls back to
    // its own default permission prompt — which is the right outcome
    // when our app isn't running.
    guard let responseData = client.sendAndWaitForResponse(data: payloadData, timeoutSeconds: 0) else {
        exit(0)
    }
    FileHandle.standardOutput.write(responseData)
    exit(0)

case "StatusLine":
    // Claude Code statusLine: stdin carries rich metadata (rate_limits etc.),
    // stdout is the status-line text. We forward fire-and-forget to the
    // app and always exit with empty stdout (stays clean regardless of
    // socket state).
    _ = client.sendFireAndForget(data: payloadData)
    exit(0)

case "PreToolUse":
    // Always fire-and-forget. Earlier builds blocked on AskUserQuestion
    // and answered via the popup, which silenced CC's native terminal
    // UI — issue user feedback (Path 2): both surfaces should show, and
    // operating either side dismisses the other. The popup now drives
    // CC's own AskUQ UI by injecting keystrokes (see KeystrokeInjector
    // in AppLib), so the bridge no longer needs to block here.
    _ = client.sendFireAndForget(data: payloadData)
    exit(0)

default:
    // Fire-and-forget observation-only hook. Always exit 0. If the socket
    // isn't reachable (app not running), spool replayable lifecycle events
    // to ~/.zackeyes/pending/ for startup replay (#89); everything else is
    // dropped and recovered by the periodic SessionScanner sweep. The spool
    // itself is best-effort and silent — invariant #2 holds either way.
    if !client.sendFireAndForget(data: payloadData) {
        PendingEventQueue().enqueueIfEligible(event: eventName, payload: payloadData)
    }
    exit(0)
}
