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

// MARK: - Step 2: Parse --event argument

// Expected: ["bridge", "--event", "EventName"]
let args = CommandLine.arguments
guard args.count == 3, args[1] == "--event" else {
    exit(0)
}
let eventName = args[2]

// MARK: - Step 3: Inject _bridge_event into JSON payload

guard var jsonObject = try? JSONSerialization.jsonObject(with: inputData) as? [String: Any] else {
    exit(0)
}
jsonObject["_bridge_event"] = eventName
// Pass parent PID (claude process) so the app can locate the terminal
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
    // Only AskUserQuestion blocks. Everything else stays fire-and-forget
    // so we don't slow down the hot path of every tool call.
    if jsonObject["tool_name"] as? String == "AskUserQuestion" {
        // 60-second internal soft timeout. CC's hook timeout is 600s
        // by default — well above ours, so we always exit before CC
        // kills us. On socket failure / POLLHUP / soft timeout, fall
        // through to CC's own terminal AskUQ UI.
        guard let responseData = client.sendAndWaitForResponse(
            data: payloadData, timeoutSeconds: 60
        ) else {
            // Spike #2A decision: f-empty wins. Empty stdout makes CC
            // fall through to its native AskUQ terminal UI — same
            // pattern as the PermissionRequest socket-fail path.
            exit(0)
        }
        FileHandle.standardOutput.write(responseData)
        exit(0)
    }
    _ = client.sendFireAndForget(data: payloadData)
    exit(0)

default:
    // Fire-and-forget observation-only hook. Always exit 0 — if the
    // socket isn't reachable we simply drop this event. The app will
    // catch up on its own via the periodic SessionScanner sweep.
    _ = client.sendFireAndForget(data: payloadData)
    exit(0)
}
