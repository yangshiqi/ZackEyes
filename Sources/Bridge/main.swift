import Foundation
import BridgeLib
import Shared

// MARK: - Step 1: Read stdin

let inputData = FileHandle.standardInput.availableData
guard !inputData.isEmpty else {
    exit(1)
}

// MARK: - Step 2: Parse --event argument

// Expected: ["bridge", "--event", "EventName"]
let args = CommandLine.arguments
guard args.count == 3, args[1] == "--event" else {
    exit(1)
}
let eventName = args[2]

// MARK: - Step 3: Inject _bridge_event into JSON payload

guard var jsonObject = try? JSONSerialization.jsonObject(with: inputData) as? [String: Any] else {
    exit(1)
}
jsonObject["_bridge_event"] = eventName
// Pass parent PID (claude process) so the app can locate the terminal
jsonObject["_bridge_ppid"] = Int(getppid())

guard let enrichedData = try? JSONSerialization.data(withJSONObject: jsonObject) else {
    exit(1)
}

// Ensure trailing newline (newline-delimited JSON)
var payloadData = enrichedData
if payloadData.last != UInt8(ascii: "\n") {
    payloadData.append(UInt8(ascii: "\n"))
}

// MARK: - Step 4 & 5: Create client and route by event

let client = BridgeSocketClient(path: "/tmp/zackeyes.sock")

switch eventName {
case "PermissionRequest":
    // Blocking: send and wait for a response from the app
    guard let responseData = client.sendAndWaitForResponse(data: payloadData, timeoutSeconds: 15) else {
        // Timeout or connection error — non-blocking failure
        exit(1)
    }
    FileHandle.standardOutput.write(responseData)
    exit(0)

case "StatusLine":
    // Claude Code statusLine command: receives rich metadata (including rate_limits)
    // via stdin, expects status text on stdout. We forward to the app and return
    // an empty status line (or could return a tiny indicator).
    let _ = client.sendFireAndForget(data: payloadData)
    // Return nothing so the user's status line stays clean
    exit(0)

default:
    // Fire-and-forget: exit 0 on success, 1 on failure
    let ok = client.sendFireAndForget(data: payloadData)
    exit(ok ? 0 : 1)
}
