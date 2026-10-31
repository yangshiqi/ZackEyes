# Codex paginated usage compatibility

## Confirmed failure and scope

The October 27 local-day Today row reproduces exactly at 43,888,524 non-cache tokens, 3,378,448,000 cache reads and priced estimate $607.1045202. A paginated continuation inherits >1B cumulative input/cache counters; legacy per-file parsing starts from zero and clamps cumulative fields at1B. The archive rejects those observations. Correct counters after resolving the referenced history boundary give42,726,966 non-cache tokens,2,668,686,848 cache reads,$517.5169494 with the existing price table. The archive's unaffected records plus the two restored sources independently match those totals.

Fix both existing local pipelines. Keep source logs/config read-only, preserve per-message limits, date attribution, pricing tiers, cache display semantics, deduplication, resumability and private persisted allowlist.

## Design

- Distinguish wide bounded cumulative counters (up to1T) from per-message counts (existing1B cap). Validate finite integral nonnegative values; retain overflow defenses when deriving/folding request-sized deltas.
- Resolve `session_meta.history_base` via a validated UUID file index and pinned byte boundary. Follow empty intermediate pages with bounded cycle/depth checks. Read only regular non-linked source files, cap line/memory/read work, never follow arbitrary metadata paths. Return the preceding counter and its timestamp; missing/inconsistent lineage must not mint inherited tokens.
- Today parser accepts a resolved initial baseline; difference wide cumulative fields before applying request-scale billing. Genuine counter resets open a fresh segment. Existing file cache remains the steady-state fast path.
- Archive parser accepts wide cumulative observations. Importer injects a non-billable counter baseline for inherited history, with hashed identities only. Summary merges/deduplicates counters across files before differencing and never charges the baseline itself.
- Version parser checkpoints. Upgrade previously rejected or paginated Codex sources once, including already tracked older files; do not import previously unseen old history. Valid unchanged sources can adopt the version without full rereads. Re-materialize affected existing daily archives through normal invalidation; no raw text/paths/IDs enter persisted records.

## Verification and local repair

Write failing fixtures first: cumulative crossing1B, paginated inherited totals, empty intermediary page and pinned boundary, missing/cyclic/linked lineage, across-day counters/reset, archive baseline dedup, checkpoint upgrade and subsequent zero-byte unchanged import. Run related and full serialized Swift tests/build/app/signature checks. Use actual local files only in a temporary audit harness with numeric-only output, reproduce corrected October27 counts/cost. Before touching real archives, stop the owned client and create a consistent SQLite backup. Exercise repair on backup clone first, validate totals and idempotence, then repair live database and launch a local integration build including the reset-reminder fix. No external merge/release is part of this task.

## Startup follow-up

Local client validation exposed two overlapping cold scans (periodic start plus panel refresh) and no quota/daily publication until they finish. Coalesce concurrent refresh requests; publish the latest quota before the daily scan, then merge daily data into the current snapshot so concurrent hook changes survive. Replace generic Unicode/byte collection splitting with bounded header parsing and native LF boundary search over contiguous UTF-8. Preserve model, pricing, date and counter results, including Unicode/CRLF logs. Validate cold-scan timing and the same numeric golden against real logs before relaunch.
