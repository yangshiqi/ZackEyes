# Local usage ledger (#263)

Status: approved by the user on 2026-10-14. Part of #265; #260, #262 and #264 are merged. This feature is separate from quota freshness and SSH observation.

## Intent and approach

Add a local history of agent work and a Settings → Usage page. It must show daily agent-hours, tokens, cache hit rate, top projects/models/tools, and an active-hours heatmap. It must retain useful history after an agent transcript is removed, without storing prompt or response text.

Two approaches were considered:

1. Extend `UsageTracker`'s rolling quota cache. It already scans transcripts, but its seven-day aggregation discards project/tool identity, and replacement of a quota cache cannot provide append-only history.
2. **Recommended: an independent counts-only ledger.** Reuse existing token normalization conventions, keep collection/persistence off the main actor, and expose a small observable summary to Settings. Quota collection and session controls continue independently.

## Collection and privacy boundary

Read only `~/.claude/projects/**/*.jsonl` and `~/.codex/sessions/**/*.jsonl`, including nested subagent transcripts. Never read Codex config.toml. Walk regular files with the existing symlink and size protections, cache unchanged files by identity/mtime/size, serialize scans, and cancel on shutdown. Start an initial background scan, then refresh at a modest interval (60 seconds) and on opening Usage. Show loading, last successful scan, and collection errors rather than silently claiming complete history.

Extract timestamp, agent, working-directory project name, model identifier, tool name/call identity, and numeric token components. Project names come from transcript cwd, using the existing worktree-to-owner convention; keep no full project/transcript path. Missing metadata is labeled Unknown. Bound display-name lengths and strip control characters; extract tool names only from schema tool-name fields, never from command arguments. No prompts, responses, tool arguments/results, command strings, or model calls enter persisted records. Synthetic demo sessions are never a source. There is no upload or telemetry.

Deduplicate Claude message IDs across files and repeated streaming messages, using the latest complete token observation for a message. Codex cumulative observations are merged across files before differencing per session, including repeated/no-op rows and counter resets. Raw cumulative evidence is retained so partial copied prefixes cannot create duplicate deltas. Tool call IDs and session metadata disambiguate repeated delivery and copied rollouts. Natural source/event identities are hashed before persistence; records without IDs use a stable file/record identity. Changes to an existing observation append a newer revision, and the aggregate uses the latest revision rather than summing both.

## Statistical definitions

- **Tokens:** match the existing Today row: uncached input + output + cache writes. Cache reads are shown separately; Codex cached input is a subset of its input and must not be counted twice.
- **Cache hit rate:** cache-read tokens / (uncached input + cache writes + cache reads). No eligible input means no rate, not 0%.
- **Agent-hours:** estimated active intervals, not event-bearing minute counts or the lifetime of an open terminal. Prefer explicit task/turn start→completion and matching tool-call→result timestamps; a ten-minute tool with just a start and result must contribute ten minutes, independent of event frequency. Union overlapping intervals within a session before summing; concurrent sessions may add more than one agent-hour per wall-clock hour. Exclude explicit user-question waits. Without reliable pairing, infer only gaps between successive genuine work events, capped at five minutes per gap (unpaired gaps longer than 30 minutes have insufficient evidence and are left unknown); leave isolated/unclosed activity unquantified rather than stretching it to scan time. Metadata, repeated quota samples and scan time do not create activity. Do not join separate turns or interpolate overnight idle gaps. Label hours as estimated elapsed work, including the limitation that unobserved approval/wait time cannot always be separated from work.
- **Heatmap:** the same merged work intervals split into local day/hour cells; cell intensity is active agent-minutes. Persist UTC interval boundaries and apply Calendar on display, preserving midnight, daylight-saving and timezone behavior.
- **Top projects/models:** tokens in the selected period; **top tools:** calls. No fabricated costs when price/history is unavailable.

## Storage and recovery

Use a versioned append-only JSONL file under `~/.zackeyes/usage/`, owner-only directory/file permissions. Append serialized count observations and revisions; persist successfully before marking them recorded. Repeating scans and restarting must not add duplicate counts. Serialize writes and flush completed batches. Preserve previously recorded history when transcripts disappear.

A partial final line after interruption must not prevent future valid records from loading. Ignore and report malformed records; preserve the original file and do not silently truncate history. Reject unsupported schema versions and invalid/nonfinite/negative/oversized numeric values. Errors are visible in Usage and do not stop the app or its quota/session paths.

## Settings experience

Add Usage to the existing Settings sidebar, following the existing dark surfaces and agent colors. Offer 7/30/90-day ranges with zero-filled local-day buckets, daily token and estimated agent-hour charts, a cache-hit summary, top projects/models/tools, and a day/hour heatmap. Distinguish Claude/Codex in charts and totals; include an honest empty state and a note that only available local transcripts can be backfilled. The stored ledger keeps older observations independently of the selected range.

## Verification and completion

Use fixture-driven Swift Testing coverage for both agents, duplicate messages/copied files, Codex cumulative deltas/resets, nested files, no-prompt persistence, cache-rate denominator, a ten-minute start/result pair versus dense intermediate events, capped unpaired gaps, overlapping/concurrent intervals, explicit question waits, midnight/DST, missing metadata, unchanged/restarted collection, history after source deletion, partial JSONL tails and filesystem errors. Verify no fake demo data enters the collector.

Run full `swift build`, `swift test`, `make app`, signing verification and native Settings UI checks with an isolated home. Review implementation independently against this spec and repository standards, fix findings, create and merge one PR closing #263, then update #265. After #261 is also complete, reconcile #92, README, architecture and website roadmap/LLM pages, keeping development-only features distinct from the published release.
