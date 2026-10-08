# Codex App Server interaction boundary (#250)

Official documentation checked on 2026-10-08: [Codex App Server](https://learn.chatgpt.com/docs/app-server).

The protocol provides thread/turn identity, steering, interruption, and user-input requests. `turn/steer` requires an active turn and its `expectedTurnId`; it does not start another turn. `thread/read` reads persisted history without subscribing, and `thread/resume` loads a thread into the connected server. These are distinct from attaching to another CLI process's in-flight work.

## ZackEyes decision

ZackEyes currently observes independently started CLIs through hooks and rollouts. The published protocol does not establish that starting a new app-server transfers an existing CLI's active turn or its outstanding approvals. Therefore, a second process must not be presented as controlling the user's current terminal session. This is a documentation-based boundary, not a claim that all future attachment mechanisms are impossible; no live session takeover experiment was performed.

Future implementation requires either an explicitly exposed endpoint for the original runtime or a deliberate ZackEyes-owned runtime launch path. It must preserve request identity, approval ownership and disconnect cleanup. Existing-session steering and native Codex questions remain outside this observer compatibility patch. Hook-based approval continues to work through the original hook socket.

## Acceptance

The documented protocol capabilities and ownership boundary are recorded. No agent process, inference request, or user configuration change is needed for this conclusion. An interaction implementation should be scoped as a separate architecture feature once an original-runtime connection mechanism is verified.
