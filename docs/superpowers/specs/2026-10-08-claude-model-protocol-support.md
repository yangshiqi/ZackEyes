# Claude model and protocol support (#254)

Verified 2026-10-08 against official documentation and local Claude Code 2.1.295. Separate branch/stacked PR above Codex #252; no Claude changes in that PR.

## Evidence and implementation scope

| Source | Verified behavior | Support |
| --- | --- | --- |
| [StatusLine](https://code.claude.com/docs/en/statusline) | effort.level is live effective effort; missing on unsupported models | Display observed level beside model; full snapshots clear missing fields |
| [Hooks](https://code.claude.com/docs/en/hooks) | effort on tool-context hooks; agent_id identifies child; only SessionStart model, PostModelSwitch to_model | Preserve absent patch fields; isolate child metadata; observe model changes without blocking |
| [Pricing](https://platform.claude.com/docs/en/about-claude/pricing) | Current model IDs and distinct cache read/5m/1h rates | Add exact Fable 5/5.1, Opus 5/5.5, Sonnet 5/5.5; correct Opus 4.7/4.8 |
| [Caching](https://platform.claude.com/docs/en/build-with-claude/prompt-caching) | cache_creation has two TTL buckets; sum equals cache_creation_input_tokens | Keep raw counts; bill reported 1h writes independently |
| [Fast mode](https://platform.claude.com/docs/en/build-with-claude/fast-mode) | usage.speed reports actual speed; supported Opus variants cost twice standard | Per-request weighting survives mixed speeds and daily aggregation |
| Hooks | PostToolUseFailure ends a tool; StopFailure ends a turn with structured API error | Track concurrent call IDs; distinguish nonfatal tool failure from fatal turn error |

Real local transcript metadata (no conversation content copied): Fable 5.1, Opus 5.5 and Sonnet 5.5 exact IDs; usage.speed standard; cache_creation includes nonzero ephemeral_1h_input_tokens. Existing scanner ignores TTL and speed. Existing price table omits these models and prices Opus 4.7/4.8 at historical Opus 4 rates (three times current standard rates).

## Boundaries

Session card cost remains Claude Code's authoritative total_cost_usd; daily price calculations are API list-price estimates, not subscription invoices. No Claude long-context surcharge for these models. Missing cache TTL uses legacy 5m estimate. Never infer active effort from model defaults or global configuration. Malformed optional metadata must not discard approvals. SubagentStop must not finish or overwrite the parent session.

Haiku 5.5 variable prompt-length pricing, restricted Mythos models, provider/regional/custom billing and API server tool charges are outside this fix; leave unknown prices unpriced. Account/model quota limits remain their measured independent windows; existing #194/#240 own presentation changes. No new model-specific subscription quota is inferred. Workflow/subagent UI remains #154. ConfigChange is not used to read global effort. TaskCreated/Completed do not replace existing transcript extraction until task lifecycle correlation is proven. CwdChanged can be evaluated separately from these model fixes. Existing scanners discover running sessions; runtime effort requires a new live hook/status snapshot because transcript messages do not reliably contain effective effort.

## Verification

Meaningful regression fixtures before implementation. Compile both targets, relevant then complete tests, assemble app, restart local build, observe actual Claude cards and exercise observation-only new events without opening fake approvals. Hook installer tests use temporary settings and preserve unrelated keys; failed parse never writes. Bridge remains silent exit(0) on controlled failures. Never read or write Codex config.toml. Existing panel focus behavior stays intact.
