# Bundled Pricing Table Design

## Goal

Provide a `price(for: model) → ModelPrice?` lookup so other features can turn
raw token counts into a USD cost, **without importing any third-party pricing
library** (CLAUDE.md invariant #6, zero deps). Prices ship bundled with the app
(offline-safe), refresh periodically from a curated remote snapshot, and degrade
silently on any failure.

Closes [#82](https://github.com/yangshiqi/ZackEyes/issues/82).

This is the hard prerequisite for [#84](https://github.com/yangshiqi/ZackEyes/issues/84)
(daily token consumption — the `$` half). #82 has **no UI**; it is purely a data
service consumed later by #84.

## Scope

- One pure value type `ModelPrice` (four per-token unit prices).
- One pure, testable `PricingTable` (parse + lookup; no Bundle, no network).
- One thin `PricingStore` shell (`@MainActor ObservableObject`): version-gated
  load (bundled vs disk cache) → 24h `URLSession` refresh that only replaces on a
  strictly newer `version`, silent on failure. Cache path / bundle bytes / fetcher
  are all injected for testability.
- One bundled `Resources/pricing.json` (trimmed, curated) + Makefile copy step
  (both assembly paths).
- `AppDelegate` wires `PricingStore.start()` alongside the existing services.
- XCTest (`Testing` framework): `PricingTable` parse/lookup/contract, `PricingStore`
  version-gated load + monotonic refresh.

**Out of scope:**

- Any UI, any `$` display — that is #84.
- Codex/Claude token *bucketing* and the actual cost math — that is #84.
- An auto-regeneration script that pulls + trims LiteLLM. Curation is manual for
  now; an optional `make pricing` target can come later if it becomes a chore.
- A long-term price-history store. Prices are a current snapshot only.

## Why bundled + curated remote (not LiteLLM directly)

`ccusage` / TokenTracker depend on LiteLLM's `model_prices_and_context_window.json`.
We can't import LiteLLM (zero-deps invariant), and pulling its raw file directly
has two problems: it's ~1.5 MB of mostly-irrelevant models, and a third party owns
its format (a schema change silently breaks our parser). Instead we **borrow the
mechanism, not the dependency**: a small curated `pricing.json` that we own,
bundled for offline use and refreshed from the repo `UpdateChecker` already polls.

## Component design

### `ModelPrice`

```swift
public struct ModelPrice: Sendable, Equatable, Codable {
    public let inputPerToken: Double
    public let outputPerToken: Double
    public let cacheReadPerToken: Double     // cached-input read
    public let cacheCreatePerToken: Double   // cache write/creation; 0 for codex
}
```

Per-token USD unit prices (LiteLLM convention, e.g. `1.5e-5`). The four fields are
dictated by how #84 will bill the two agents:

- **Claude** (`message.usage`): `input_tokens`, `output_tokens`,
  `cache_read_input_tokens`, `cache_creation_input_tokens` — all four fields used.
- **Codex** (`token_count.info.last_token_usage`): `input_tokens` *includes*
  `cached_input_tokens`, and `output_tokens` *includes* `reasoning_output_tokens`.
  So #84 will compute `uncachedInput = input − cached`, then bill
  `uncachedInput·inputPerToken + cached·cacheReadPerToken + output·outputPerToken`.
  Codex has no cache-creation concept, so `cacheCreatePerToken` is `0` for those
  models. (This billing math lives in #84; documented here only to justify the
  struct shape.)

### `PricingTable` — pure, testable core

```swift
public struct PricingTable: Sendable {
    public let version: String                // pricing.json `version`; "" if absent
    public init(data: Data) throws            // parse curated pricing.json
    public func price(for model: String) -> ModelPrice?
    public static let empty: PricingTable      // version "", no models → every lookup nil
}
```

- No `Bundle`, no `URLSession`. This is the unit-tested core; tests feed inline
  JSON `Data`.
- `init(data:)` throws on malformed JSON so the shell can keep its prior table
  rather than swapping in garbage.
- `version` is parsed out and exposed so `PricingStore` can do monotonic
  version-gated selection (see below). An absent/empty `version` sorts lowest.
- **Lookup order in `price(for:)`:**
  1. Exact key match.
  2. Date-suffix stripped: drop a trailing `-YYYYMMDD` or `-YYYY-MM-DD` and retry
     exact (handles `claude-haiku-4-5-20251001` → `claude-haiku-4-5`).
  3. Alias map: `aliases[model] → canonical key` (escape hatch for any name that
     normalization can't reach).
  4. `nil`.
- **No broad prefix/fuzzy matching.** Returning the *wrong* price silently is
  worse than returning `nil` (which #84 renders as "no `$`", never `$0`). Matching
  stays explicit and curated.

#### Model-ID contract (hard requirement — Codex review #2/#3)

`price(for:)` accepts a **raw provider model identifier only**, exactly as the
agent emits it in its own logs:

- **Claude:** the `model` field on each assistant line in
  `~/.claude/projects/**/*.jsonl` — e.g. `claude-opus-4-8`.
- **Codex:** `turn_context.payload.model` in the rollout jsonl — e.g. `gpt-5.5`.

A **display name must never be passed in.** The app's existing
`SessionInfo.modelDisplayName` comes from the statusLine `model.display_name`
field (`SessionStore.swift:690`, e.g. "Opus 4.8") and is **not** a valid key —
feeding it yields `nil` (correct: "no `$`", never a wrong `$`). Because the
matching is exact-only, a display name can't accidentally collide with a price.

**Consequence for #84 (flagged here, built there):** today nothing stores the raw
Claude model ID — `UsageTracker.parseFile` reads only `usage`
(`UsageTracker.swift:438`), and `SessionStore` keeps only the display name. So
#84's per-day scan must additionally capture the raw `message.model` (Claude) and
`turn_context.payload.model` (Codex) alongside token counts. #82 only defines and
enforces this contract; the extraction is #84 scope.

### `pricing.json` — curated, trimmed, compact schema

Our own compact schema (only the four fields we use), not LiteLLM's verbose field
names, because we hand-curate the file:

```json
{
  "version": "2026-06-02",
  "models": {
    "claude-opus-4-8": { "input": 1.5e-5, "output": 7.5e-5, "cache_read": 1.5e-6, "cache_creation": 1.875e-5 },
    "gpt-5.5":         { "input": 1.25e-6, "output": 1.0e-5, "cache_read": 1.25e-7, "cache_creation": 0 }
  },
  "aliases": {}
}
```

- Keys are the **exact strings the agents report** — Claude `message.model`
  (e.g. `claude-opus-4-8`), Codex `turn_context.payload.model` (e.g. `gpt-5.5`).
  This makes exact-match the common path.
- Trimmed to the `claude-*` and `gpt-5*`/codex families plus a little headroom.
  A few KB.
- `version` is **load-bearing** (Codex review #1/#8/#11): an ISO date string
  (`YYYY-MM-DD`) compared lexicographically to decide which of bundled / cache /
  remote tables wins. Every price change MUST bump it. A correction that keeps
  the same `version` will be ignored by the monotonic refresh below — by design.
- The example numbers above are **placeholders** — real values are filled from
  the current LiteLLM snapshot at implementation time. They are not load-bearing
  for the design.

### `PricingStore` — thin shell

Borrows the **timer + silent-`URLSession`-failure** shape from `UpdateChecker`,
and the **atomic disk-write + defensive-read** shape from `ConfigStore` /
`UsageTracker`. It is *not* a clone of `UpdateChecker` (which has no cache, no
atomic write, no bundled fallback — Codex review #7).

```swift
@MainActor public final class PricingStore: ObservableObject {
    @Published public private(set) var table: PricingTable

    public func price(for model: String) -> ModelPrice? { table.price(for: model) }

    public init(
        checkInterval: TimeInterval = 24 * 3600,
        cacheURL: URL = /* ~/.zackeyes/pricing-cache.json */,
        bundledData: @Sendable () -> Data? = { /* Bundle.main pricing.json */ },
        fetch: @Sendable () async -> Data? = { /* URLSession GET of the raw URL */ }
    )
    public func start()
    public func stop()
}
```

All three external seams — `cacheURL`, `bundledData`, `fetch` — are injected, so
every path is unit-testable with a temp cache dir, inline bundle bytes, and a stub
fetcher, with **no real network and no writes to the real `~/.zackeyes`**
(Codex review #4/#5; `cacheURL` mirrors `ConfigStore.init(directory:)`).

- **Version-gated load on `start()`** (Codex review #1/#8): parse *both* the disk
  cache (`cacheURL`) and the bundled snapshot, then pick the one with the higher
  `version` that parses. If only one parses, use it; if neither, `PricingTable.empty`.
  This fixes the "stale cache shadows a fresher bundled snapshot forever when
  offline" bug — after an app update ships newer bundled prices, they win until the
  network confirms something newer still.
- **Monotonic refresh** (`Timer`, every `checkInterval`, plus once on `start()`):
  `await fetch()` → parse → **replace only if `fetched.version > table.version`**.
  On success, atomically write the bytes to `cacheURL` and swap `@Published table`.
  On any failure (nil data, parse error, or non-newer version): keep the current
  table, retry next tick (Codex review #11 — parse-success alone must not let an
  older or rolled-back remote file overwrite good data).
- **Concurrency** (Codex review #6): `await fetch()` suspends the main actor
  without blocking it (`URLSession` work runs off-main); the JSON parse and atomic
  write are a few KB, bounded, and run on the main actor after the await — no
  `Task.detached` needed at this size. `PricingTable`/`ModelPrice` are value types,
  trivially `Sendable`; the injected closures are `@Sendable`.
- Network failure can't pollute #82 (no UI). The honest risk is **downstream**:
  #84 will read this table, so a *stale-but-parseable* cache could surface a wrong
  cost. Version-gated load + monotonic refresh is what bounds that risk (Codex
  review #8).

### Remote source & bundling

- **Remote URL:** `https://raw.githubusercontent.com/yangshiqi/ZackEyes-release/main/pricing.json`
  — raw file on `main` of the public release repo that `UpdateChecker` already
  targets. Prices are updated by committing a new `pricing.json` to that repo; no
  GitHub release is required to push a price change.
- **Bundle:** add `Resources/pricing.json`; the Makefile copies it into
  `Contents/Resources/` in **both** the `app` and the universal release targets
  (`cp Resources/pricing.json $(RESOURCES)/`), consistent with how `*.mp3` and
  `AppIcon.icns` are bundled. SPM `resources:` is intentionally not used — the app
  bundle is assembled by the Makefile, matching existing resources.
- **Disk cache:** `~/.zackeyes/pricing-cache.json`, mirroring the existing
  `usage-cache.json` location and atomic-write pattern.

### Wiring

`AppDelegate` constructs a `PricingStore` and calls `start()` next to the existing
`UpdateChecker` / `UsageTracker` startup, and `stop()` on teardown. No view binds
to it in #82; #84 will inject it where the cost math runs.

## Data flow

```
start()
  → parse cache (cacheURL) and parse bundled → table = higher-version of the two
        that parse; if neither parses → table = .empty
  → schedule 24h timer + fire once now
        → await fetch() → parse → fetched.version > table.version ?
              yes → atomic-write cacheURL + swap @Published table
              no / nil / parse-fail → keep table, retry next tick (silent)

#84 (later): pricingStore.price(for: rawModelID) → ModelPrice? → cost math
              (rawModelID = message.model | turn_context.payload.model, NOT display name)
```

## Files touched

| File | Change |
|------|--------|
| `Sources/AppLib/Usage/ModelPrice.swift` (new) | `ModelPrice` struct |
| `Sources/AppLib/Usage/PricingTable.swift` (new) | pure parse + lookup |
| `Sources/AppLib/Usage/PricingStore.swift` (new) | shell: injected cache/bundle/fetch seams, version-gated load + monotonic refresh |
| `Resources/pricing.json` (new) | curated trimmed snapshot |
| `Makefile` | add `cp Resources/pricing.json $(RESOURCES)/` to **both** copy blocks — `app` (`Makefile:21-23`) **and** the universal release target (`Makefile:34-36`); missing either silently ships no table (Codex review #10) |
| `Sources/ZackEyes/AppDelegate.swift` | construct + `start()`/`stop()` `PricingStore` |
| `Tests/AppLibTests/PricingTableTests.swift` (new) | parse / lookup / fallback tests |
| `Tests/AppLibTests/PricingStoreTests.swift` (new) | version-gated load + monotonic refresh, via injected cache/bundle/fetch |
| `ARCHITECTURE.md` | add `PricingStore`/`PricingTable` to the module table + a pricing-data-flow note |

New code lives in `Sources/AppLib/Usage/` next to `UsageTracker`/`UsageBarsView`,
since pricing is conceptually part of the usage subsystem.

## Tests (`Testing` framework, `Tests/AppLibTests/`)

`PricingTable` (pure, the bulk of coverage):
- Parse a canonical `pricing.json` fixture → known models return the expected
  `ModelPrice` (all four fields); `version` parsed.
- Exact-match lookup.
- Date-suffix-strip lookup (`claude-haiku-4-5-20251001` → `claude-haiku-4-5`).
- Alias lookup.
- Missing model → `nil`.
- **Display name → `nil`** (the model-ID contract: e.g. `"Opus 4.8"` must not
  resolve to a price).
- Malformed JSON → `init(data:)` throws.
- Empty/`{"models":{}}` JSON → every lookup `nil` (no crash); absent `version` → `""`.

`PricingStore` (shell — injected `cacheURL` (temp dir), `bundledData`, `fetch`; no
real network, no real `~/.zackeyes`):
- **Version-gated load:** newer-version cache beats older bundled; newer-version
  bundled beats older cache (the post-app-update case); equal version → either is
  fine (no wrong price either way).
- Corrupt cache → falls back to bundled; corrupt bundled + valid cache → cache.
- Missing bundled + missing cache → `.empty`, `price(for:)` returns `nil`.
- **Monotonic refresh:** injected `fetch` returning a newer-version table → swaps
  `table` and writes `cacheURL`; older-or-equal version → no swap, no write;
  nil / unparseable fetch → no swap, prior table retained.

## Invariant & constraint checklist

- **Zero deps (#6):** pure Foundation `JSONDecoder`/`URLSession`. No SPM packages.
- **Network failure doesn't pollute UI:** #82 has no UI; refresh failures are
  silent and keep the prior table.
- **No `~/.codex/config.toml` access (#1/#7):** not touched.
- **Bridge / NotchPanel invariants:** unaffected — this is an App-side service.
- **Idle CPU ~0%:** a 24h `Timer` plus a single `URLSession` GET; negligible.

## Sub-decisions (resolved)

- **Schema:** compact custom (four fields + aliases), not mirrored LiteLLM field
  names — we curate the file, so the cleaner schema wins.
- **Remote URL form:** raw file on `main` of `ZackEyes-release`, not a release
  asset — lets a price change be a single commit.
- **Matching:** exact → date-strip → alias → `nil`; no fuzzy prefix matching.
  `price(for:)` takes raw provider model IDs only; display names → `nil`.
- **Cache vs bundled vs remote:** **version-gated** — always load/keep the
  higher-`version` table that parses; refresh replaces only on a strictly newer
  `version` (revised from the earlier "cache always wins", which shadowed a fresher
  bundled snapshot after an app update — Codex review #1/#8/#11). The 24h interval
  is the recurring-refresh cadence; `start()` also fires once.

## Known risks

- **Model-name drift:** if an agent reports a model string not in `pricing.json`
  and not reachable by date-strip/alias, `price(for:)` returns `nil` and #84 shows
  no `$` for it. Mitigation: the curated keys match observed strings exactly, the
  alias map is the escape hatch, and remote refresh ships new models without an app
  update.
- **Raw model IDs aren't captured yet.** Pricing needs the raw ID, but the app
  currently stores only `modelDisplayName` and `UsageTracker.parseFile` reads only
  `usage`. #84 must extend its scan to capture `message.model` (Claude) and
  `turn_context.payload.model` (Codex). #82 enforces the contract (`price(for:)`
  rejects display names → `nil`); #84 owns the extraction. Flagged so #84 isn't
  surprised (Codex review #2).
- **`version` hygiene is operational, not enforced by code.** A price change that
  forgets to bump `version` is silently ignored by the monotonic refresh. Mitigation:
  document it at the curation point; an optional `make pricing` regen step (deferred)
  would stamp the date automatically.
