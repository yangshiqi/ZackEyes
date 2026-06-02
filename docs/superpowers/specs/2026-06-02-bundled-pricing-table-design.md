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
- One thin `PricingStore` shell (`@MainActor ObservableObject`) mirroring
  `UpdateChecker`: bundled load → disk-cache overlay → 24h `URLSession` refresh,
  silent on failure.
- One bundled `Resources/pricing.json` (trimmed, curated) + Makefile copy step.
- `AppDelegate` wires `PricingStore.start()` alongside the existing services.
- XCTest (`Testing` framework) for parse / lookup / fallback paths.

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
    public init(data: Data) throws            // parse curated pricing.json
    public func price(for model: String) -> ModelPrice?
    public static let empty: PricingTable     // no models → every lookup nil
}
```

- No `Bundle`, no `URLSession`. This is the unit-tested core; tests feed inline
  JSON `Data`.
- `init(data:)` throws on malformed JSON so the shell can keep its prior table
  rather than swapping in garbage.
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
- `version` is informational (date string), surfaced in logs/cache only.
- The example numbers above are **placeholders** — real values are filled from
  the current LiteLLM snapshot at implementation time. They are not load-bearing
  for the design.

### `PricingStore` — thin shell (mirrors `UpdateChecker`)

```swift
@MainActor public final class PricingStore: ObservableObject {
    @Published public private(set) var table: PricingTable
    public func price(for model: String) -> ModelPrice? { table.price(for: model) }
    public init(checkInterval: TimeInterval = 24 * 3600,
                bundledData: @Sendable () -> Data? = { /* Bundle.main pricing.json */ })
    public func start()
    public func stop()
}
```

- **Load order on `start()`:** disk cache (`~/.zackeyes/pricing-cache.json`, if
  present and parseable) → bundled `pricing.json` via the injected `bundledData`
  closure → `PricingTable.empty`. The disk cache is the last *successful* remote
  fetch, so it is preferred over the (older) bundled snapshot whenever it parses.
  Age is **not** a load gate — `start()` also fires a refresh immediately, so any
  staleness self-heals within one fetch; the 24h interval governs only the
  *recurring* refresh, not loading.
- **Refresh** (`Timer`, every `checkInterval`, plus once on `start()`): `URLSession`
  GET the curated raw URL. On HTTP 200 **and** successful `PricingTable(data:)`:
  write the bytes to the disk cache (atomic) and swap `@Published table`. On **any**
  failure (network error, non-200, parse failure): do nothing — keep the current
  table, retry on the next tick. Identical control flow to `UpdateChecker.check()`.
- The `bundledData` closure is injected so `PricingStore` is unit-testable without
  an assembled `.app` bundle (the same pattern `WelcomeTrigger` uses to stay
  Bundle-free in tests).
- Network failure cannot pollute the UI because #82 renders nothing; #84 reads
  only the in-memory `table`.

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
  → load disk cache (present & parseable?) ──yes──> table = cached
        │ no
        └──> load bundled pricing.json ──ok──> table = bundled
                  │ missing/corrupt
                  └──> table = .empty
  → schedule 24h timer + fire once now
        → URLSession GET raw URL
            → 200 + PricingTable(data:) ok → write disk cache + swap table
            → any failure → keep table, retry next tick (silent)

#84 (later): pricingStore.price(for: model) → ModelPrice? → cost math
```

## Files touched

| File | Change |
|------|--------|
| `Sources/AppLib/Usage/ModelPrice.swift` (new) | `ModelPrice` struct |
| `Sources/AppLib/Usage/PricingTable.swift` (new) | pure parse + lookup |
| `Sources/AppLib/Usage/PricingStore.swift` (new) | bundled/cache/remote shell |
| `Resources/pricing.json` (new) | curated trimmed snapshot |
| `Makefile` | `cp Resources/pricing.json $(RESOURCES)/` in `app` + release targets |
| `Sources/ZackEyes/AppDelegate.swift` | construct + `start()`/`stop()` `PricingStore` |
| `Tests/AppLibTests/PricingTableTests.swift` (new) | parse/lookup/fallback tests |
| `ARCHITECTURE.md` | add `PricingStore`/`PricingTable` to the module table + a pricing-data-flow note |

New code lives in `Sources/AppLib/Usage/` next to `UsageTracker`/`UsageBarsView`,
since pricing is conceptually part of the usage subsystem.

## Tests (`Testing` framework, `Tests/AppLibTests/`)

`PricingTable` (pure, the bulk of coverage):
- Parse a canonical `pricing.json` fixture → known models return the expected
  `ModelPrice` (all four fields).
- Exact-match lookup.
- Date-suffix-strip lookup (`claude-haiku-4-5-20251001` → `claude-haiku-4-5`).
- Alias lookup.
- Missing model → `nil`.
- Malformed JSON → `init(data:)` throws.
- Empty/`{"models":{}}` JSON → every lookup `nil` (no crash).

`PricingStore` (shell, injected `bundledData`, no real network):
- A parseable disk cache is preferred over bundled.
- Corrupt disk cache falls back to bundled.
- Missing bundled + missing cache → `.empty` table, `price(for:)` returns `nil`.

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
- **Disk-cache freshness:** not gated on load — the cache (last good remote
  fetch) is always preferred over bundled when it parses; a refresh fires on
  `start()` to correct any staleness. The 24h interval is the recurring-refresh
  cadence only.

## Known risks

- **Model-name drift:** if an agent reports a model string not in `pricing.json`
  and not reachable by date-strip/alias, `price(for:)` returns `nil` and #84 shows
  no `$` for it. Mitigation: the curated keys match observed strings exactly, the
  alias map is the escape hatch, and remote refresh ships new models without an app
  update.
- **Codex model identification depends on `turn_context.payload.model`** being
  present in the rollout. This is #84's concern (it extracts the model); #82 only
  needs to price whatever string it's handed.
