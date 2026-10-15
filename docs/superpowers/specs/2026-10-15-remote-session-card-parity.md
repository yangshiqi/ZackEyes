# Remote session card parity

## User intent and evidence

After the contrast fix a572971, the user's Apple Silicon screenshot shows readable remote Codex metadata, but a YOLO session lacks its risk badge and the remote card still differs substantially from the local card. Continue the user's existing request for consistent local/remote cards.

`RemoteSessionSnapshot` currently carries only identity, state, cwd, model, tool and last activity. `RemoteTranscriptScanner` drops approval policy, sandbox type and reasoning effort. `NotchExpandedView.sessionCard` routes remote sessions to a separate `RemoteSessionCard` instead of its local card content.

## Scope

Use the same card content implementation for local and remote sessions: buddy/avatar, project heading, agent/risk badges, activity age, model/effort and tool typography/layout. Add a host/observed label and remote-terminal attention text for remote sessions. Keep remote cards read-only: no local terminal jump, local process or git scan, permission responders, notification, usage or journal ingestion. Never read the local Bridge prompt cache for a remote ID.

Extend protocol-v1 snapshots with bounded optional approval policy, sandbox type, Claude permission mode and reasoning effort metadata. An old helper's missing fields remain absent and must not invent YOLO. Map Codex policies using the same `PermissionRiskLevel` rules as local sessions. A newer helper's optional fields remain ignorable by older clients. No agent configuration reads/writes.

Carry effort only when observed; retain missing fields within the same model, clear explicit null/empty values and stale effort after model changes. Retain bounded parsing/caching and reset uncertain inferred activity plus mutable policy/effort across omitted transcript regions.

The user asked whether full parity would be too complex; the recommendation is necessary metadata with consistent presentation. Keep prompt/reply transport excluded. Remote questions/options/approval were discussed as a possible future bidirectional feature; the present SSH observer cannot answer them and this task does not add an interaction channel. Do not infer process liveness or an actively running tool merely from a recently observed working state.

## Verification

First reproduce missing metadata with scanner/codec and adapter tests using synthetic YOLO turn_context records. Cover defaults, policy changes, old snapshots, oversized fields, effort clearing and model changes. Render actual remote cards through the shared presentation in both color schemes; verify readable metadata and semantic badge colors. Run full Swift tests, build/package a local app, and check the portable helper with Linux fixtures. Do not publish a version automatically. The existing arm64 test DMG contains only a572971 and must not be represented as containing this follow-up until rebuilt.
