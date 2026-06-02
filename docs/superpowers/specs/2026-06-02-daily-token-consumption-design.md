# Daily Token Consumption Design

## Goal

Add a glanceable **"Today"** line to the full-view header: today's combined
(Claude + Codex) token consumption + cost, a 7-day daily-token sparkline, and a
per-agent split subline. Plus an optional toggle to append today's cost to the
compact pill. Reuses the existing transcript scan and the merged `PricingStore`
(#82) for cost.

Closes [#84](https://github.com/yangshiqi/ZackEyes/issues/84).

This is the **consumption axis** ("已经烧了多少" — absolute tokens / spend), kept
visually separate from the existing 5h/7d **quota axis** ("还剩多少配额"). It does
NOT touch the 5h/7d bars or the pill's default 5h/7d display.

## Scope

- Per-calendar-day token + cost buckets (last 7 local days) for **both** agents,
  added to `UsageTracker.Snapshot`.
- Claude: extend the existing transcript scan to bucket per day × model.
- Codex: a **new** full-rollout daily-token scan (the existing tail-only
  rate_limits scan is left untouched).
- Cost via `PricingStore` (computed on `@MainActor` after the off-main scan).
- A shared `TodayConsumptionRow` view embedded in both notch surfaces.
- An optional `ConfigStore` flag + gear-menu toggle for the pill cost suffix.
- Tests for bucketing (midnight/timezone), Codex delta summation, cost math,
  humanizer, sparkline.

**Out of scope:**

- Activity heatmap, model pie chart, web dashboard, long-term (>7d) SQLite
  history — explicitly the ccusage/TokenTracker track, not this.
- Touching the 5h/7d quota bars or the default pill content.
- Changing the existing Codex rate_limits scan or its 15-min active window.

## Concept boundary (design premise)

Two different axes, kept apart in the UI:
- **Quota axis (existing):** 5h/7d *remaining %* — how far from a rate limit.
- **Consumption axis (this issue):** Today's *absolute* tokens / $ — how much was
  burned. Lives on its own row below a hairline, never mixed into the 5h/7d bars.

Per-session `$` (the context bar's `session.totalCostUSD`) is a separate, already
-shipped concept: single-session cumulative cost. The Today row is cross-session
*today* totals. Different scopes; both can coexist.

## Data model

Added to `UsageTracker.Snapshot`:

```swift
public struct DayUsage: Sendable, Codable, Equatable {
    public var dayStart: Date           // local startOfDay for this bucket
    public var claudeTokens: Int
    public var codexTokens: Int
    public var claudeCostUSD: Double?   // nil = no priced Claude data this day
    public var codexCostUSD: Double?    // nil = no priced Codex data this day
    public var anyUnpriced: Bool        // some tokens had no price → combined cost is a floor (≥)
    public var totalTokens: Int { claudeTokens + codexTokens }
}

public var dailyUsage: [DayUsage]       // exactly 7 entries, oldest → today (last = today)
```

- `dailyUsage` always has 7 entries (today + 6 prior local days); days with no
  activity are zero-filled so the sparkline is fixed-width.
- **Today** = `dailyUsage.last`. **Sparkline** = `dailyUsage.map(\.totalTokens)`.
- **Combined today cost** = sum of non-nil `claudeCostUSD` + `codexCostUSD` for
  the last entry; rendered with a `≥` floor marker iff `anyUnpriced`.
- Existing `tokens5h/7d`, `messages5h/7d`, and all rate_limits fields are
  unchanged. **`dailyUsage` is NOT trusted from the cache** (Codex review #4): an
  always-visible header must never show yesterday's "today" after midnight. So
  `loadFromCache()` resets `snapshot.dailyUsage = []` after decoding, and the
  refresh that fires immediately on `start()` rebuilds it. (`dailyUsage` may still
  be `Codable` for convenience, but a restored value is discarded on load — there
  is briefly no Today row at launch until the first scan completes, which is
  correct rather than wrong.)

### Token-total convention (cross-agent)

The "tokens" number is "tokens processed", summed per agent then combined:
- **Claude:** `input + output + cache_read + cache_creation` (matches the existing
  `computeSnapshot` convention — cache tokens counted additively).
- **Codex:** `input_tokens + output_tokens` (Codex's `cached_input_tokens` is a
  *subset* of `input_tokens`, not additive; `reasoning_output_tokens` is a subset
  of `output_tokens`).

These are approximate across providers but correct within each, and fine for a
glance metric. Cost (below) uses the precise per-component breakdown.

## Scan + cost (off-main scan, on-main pricing)

The token scan stays on the existing detached `.utility` task in
`UsageTracker.refresh()` (preserves the ~0% idle-CPU / background-queue
constraint). **Pricing is applied afterward on `@MainActor`**, because
`PricingStore` is main-actor-isolated and `price(for:)` is a cheap in-memory
lookup.

### Per-agent token tally (Sendable scan output)

```swift
struct ModelTokenTally: Sendable, Equatable {   // per (day, agent, model id)
    var input = 0, output = 0, cacheRead = 0, cacheCreate = 0
}
// scan returns, per agent: [Date /*local startOfDay*/ : [String /*raw model id*/ : ModelTokenTally]]
```

- **Claude:** extend `parseFile` to additionally accumulate a
  `[Date: [String: ModelTokenTally]]` keyed by the local-day of each assistant
  line's `timestamp`, reading the raw model id from `message.model` (e.g.
  `claude-opus-4-8`) and the four `usage` components. The existing 5h/7d sums are
  kept as-is in the same pass.
- **Codex (new `scanCodexDailyTokens(rootDir:calendar:now:)`):** a scan of every
  rollout whose mtime is within the 7d window (mtime-prefiltered; resumes can
  append to old date dirs, so all date dirs are still walked — same as the
  existing scanner). Within each file, track the running `total_token_usage`
  and derive each turn's delta as `max(0, total[i] − total[i−1])` (robust by
  construction; cross-checked against `last_token_usage`), attributed to the
  local-day of that `event_msg` line and the **current model** (the most recent
  `turn_context.payload.model` seen earlier in the file, default `"unknown"`).
  Codex components map as: `input = input_tokens`, `cacheRead =
  cached_input_tokens`, `output = output_tokens`, `cacheCreate = 0`.
  **Schema assumption:** that `total_token_usage` is monotonic-per-file and
  `last_token_usage` is a clean per-turn delta was *observed* on real rollouts
  (2026-06-02) but is **not** otherwise relied on by the codebase — it MUST be
  locked by fixture tests built from real rollout samples before shipping.
- **This is a separate scan from the existing `scanLatestCodexRateLimits`**, which
  stays exactly as-is (tail-only, 15-min active window). We do NOT fold them
  together — the rate_limits scan's 15-min semantics and the daily scan's 7d
  window are different concerns, and leaving rate_limits untouched is lower-risk.
- **Not a LivenessFilter interaction** (CLAUDE.md invariant #7): this is a
  read-only token aggregator, unrelated to the cwd→process liveness detection.

### Pure cost fold (`nonisolated`, testable — called *from* `@MainActor`)

`buildDailyUsage` is a `nonisolated static` pure function. It takes a
`PricingTable` value (which is `Sendable`) and never touches actor state or calls
`PricingStore.price(for:)` itself, so it is not main-actor-isolated; `refresh()`
(which *is* `@MainActor`) calls it with `pricingStore?.table ?? .empty`.

```swift
nonisolated static func buildDailyUsage(
    claude: [Date: [String: ModelTokenTally]],
    codex:  [Date: [String: ModelTokenTally]],
    pricing: PricingTable,
    calendar: Calendar,
    now: Date
) -> [DayUsage]
```

Pure function (injected `pricing`/`calendar`/`now` — no clock, no files, no
`PricingStore`). For each of the 7 local days ending today:
- `claudeTokens` = Σ over models of `input+output+cacheRead+cacheCreate`.
- `codexTokens` = Σ over models of `input+output`.
- `claudeCostUSD` per model `m` with `pricing.price(for: m)` =
  `input·inP + output·outP + cacheRead·crP + cacheCreate·ccP`; nil if no priced
  model that day.
- `codexCostUSD` per model `m`: `uncached = max(0, input − cacheRead)`;
  `uncached·inP + cacheRead·crP + output·outP`.
- A model with `pricing.price(for:) == nil` contributes tokens but no cost, and
  sets `anyUnpriced = true` (its day's cost is a floor).

`UsageTracker.refresh()` (already `@MainActor`) runs the two detached scans, then
reads `pricingStore?.table ?? .empty` and calls `buildDailyUsage(...)`, storing
the result on `snapshot.dailyUsage`. `UsageTracker` gains `weak var pricingStore:
PricingStore?` (both are `@MainActor`, so this read is actor-safe).

**Concurrency constraint:** the detached `.utility` scan closures capture only
`Sendable` inputs (the dir URLs, `Calendar`, `now`) and return `Sendable` tally
dictionaries — they must NOT capture `pricingStore`, `snapshot`, or any actor
state. Pricing is applied only after the scans return, on the main actor.

**Cost nil/0 invariant:** `claudeCostUSD`/`codexCostUSD` is `nil` **iff that agent
had no priced tokens that day at all** (cost unknown); a day with ≥1 priced model
yields a numeric cost (possibly `~0`). `anyUnpriced` is set whenever *some* tokens
that day lacked a price. The combined today cost = sum of the non-nil agent costs;
it renders with a `≥` floor marker iff `anyUnpriced`, and is omitted entirely only
when both agent costs are `nil` (no price basis at all).

### Performance — per-file parse cache (required, not optional)

A full 7-day Codex rollout rescan every 30s would walk all date dirs and read
whole files — materially heavier than the existing deliberately-bounded tail-only
scan, and a real threat to the `~0% idle CPU` constraint (Codex review #1). So the
daily scan keeps an in-memory **per-file parse cache** keyed by `(path, mtime,
size)`: on each scan, an unchanged rollout returns its previously-parsed per-day
tallies for free; only changed/new files are re-read. Steady-state cost is then
≈ the one active rollout being appended to, not the whole 7d window. The Claude
daily buckets piggyback on the scan that already runs (nearly free), and the same
cache applies to Claude transcripts. Scans stay on the `.utility` detached task at
the existing 30s cadence; the cache is what makes 30s affordable. A coarser daily
cadence remains a fallback if measurement still shows pain.

## UI — shared `TodayConsumptionRow`

New view `Sources/AppLib/Usage/TodayConsumptionRow.swift`:

```
Today  1.4M tok · ≥$4.20      ▁▂▅▃▇▆█      ← main row
C 1.1M · X 0.3M                            ← per-agent subline (omit a zero agent)
```

- **Main row:** humanized today tokens (`1.4M` / `340K` / `1234`), `·`, today
  cost (with `≥` prefix iff `anyUnpriced`; omitted entirely if combined cost is
  nil), and a 7-bar sparkline (heights normalized to the 7-day max; rightmost =
  today).
- **Subline:** `C <claudeTokens> · X <codexTokens>` (humanized; omit an agent
  whose today tokens are 0; omit the whole subline if both 0).
- **Token humanizer** + **sparkline** are small pure helpers (unit-tested).
- Embedded in **both** surfaces, below the 5h/7d bars, separated by a **hairline**
  (`Color.white.opacity(0.08)`, distinct from the heavier header `Divider`):
  - `UsageBarsView` (real notch) — append after the 5h/7d `VStack`.
  - `SimulatedNotchFullView.usageHeader` (simulated) — append after the 5h/7d rows.
- **Full-view height (Codex review #10):** the Today row + subline + hairline add
  vertical content to the header. The simulated full panel's height estimation
  must account for the Today row when `hasConsumption` is true (it's debounced /
  recomputed on content change), and both surfaces need manual/screenshot
  validation that the panel grows correctly and nothing clips.
- **Hidden only when the entire 7-day window is zero** (fresh install / no
  transcripts) — the whole Today row + subline disappear. A zero *today* with
  nonzero history still shows (`Today 0 tok` + the week's sparkline), an
  informative "idle today" glance. Visibility is driven by a `hasConsumption`
  flag (7-day total > 0).

## Pill cost toggle

- `ConfigStore`: add `showTodayCostInPill: Bool?` to `ConfigWrapper` (nil ⇒ false)
  with `loadShowTodayCostInPill()` / `saveShowTodayCostInPill(_:)`, using the same
  defensive contract as `saveCompactAgent` (bail rather than clobber a corrupt
  file).
- Gear menu (`SimulatedNotchFullView.popGearMenu`): add a checkable item
  **"Show today's cost in pill"** (`GearMenuTarget.toggleTodayCostInPill`), state
  reflecting the flag.
- `SimulatedNotchView.compactContent`: when the flag is on **and** today's combined
  cost is non-nil, append `· ≥$4.20` (floor marker as applicable) after the
  existing 5h/7d chips. Default (off) leaves the pill exactly as today.
- **Pill width (Codex review #9):** the compact pill is fixed-width and already
  carries two chips + separator, so an appended cost suffix risks overflow/clipping.
  The pill must **size-to-fit** the extra suffix when the toggle is on (grow
  `compactWidth` to its content), and the cost uses a compact format (`$4.2`,
  `≥$4`) to stay narrow. This needs explicit manual/screenshot layout validation
  before the toggle is exposed; if width can't be made to behave, the toggle ships
  disabled rather than clipping the pill.
- Live update: store the flag on `NotchModeStore` (`@Published`) seeded from
  `ConfigStore` at launch (mirrors how `compactAgent` is handled), so toggling
  re-renders without a relaunch.

## Tests (`Testing` framework, `Tests/AppLibTests/`)

Pure helpers are tested with injected `now` / `Calendar` / `PricingTable` — no real
clock, files, or network:

- **Bucketing:** two assistant entries straddling **local midnight** land in
  different `DayUsage` days; a non-UTC `Calendar.timeZone` shifts the boundary
  correctly (local day, not UTC).
- **7 fixed buckets:** a day with no activity is present as a zero entry; result is
  always length 7, last = today.
- **Codex delta summation (real-rollout fixtures):** built from captured real
  rollout samples (Codex review #2), asserting the per-turn delta derived from
  `total_token_usage` diffs (cross-checked vs `last_token_usage`), model attributed
  from the preceding `turn_context.payload.model`, and `cached_input_tokens`
  treated as a subset of `input_tokens`. Include a resumed/multi-`turn_context`
  fixture and a non-monotonic edge (`max(0, …)` guard).
- **Parse cache:** a rollout whose `(mtime, size)` is unchanged is served from the
  cache (not re-parsed); a changed file is re-parsed and its day buckets update.
- **Cost math:** priced model → exact expected `$`; an unpriced model → tokens
  counted, cost from priced messages only, `anyUnpriced == true`.
- **Combined totals:** Claude + Codex sum into `totalTokens` and combined cost.
- **Humanizer:** `1_400_000 → "1.4M"`, `340_000 → "340K"`, `1234 → "1234"`.
- **Sparkline normalization:** heights scale to the max; all-zero handled.
- **Hidden when empty:** `hasConsumption` (7-day total > 0) is false when all 7
  days are zero and true when only history is nonzero (drives row visibility).

## Files touched

| File | Change |
|------|--------|
| `Sources/AppLib/Usage/UsageTracker.swift` | `DayUsage` + `Snapshot.dailyUsage`; `ModelTokenTally`; Claude per-day buckets in `parseFile`/`computeSnapshot`; new `scanCodexDailyTokens`; pure `buildDailyUsage`; `weak var pricingStore`; fold in `refresh()` |
| `Sources/AppLib/Usage/TodayConsumptionRow.swift` (new) | shared view + token humanizer + sparkline |
| `Sources/AppLib/Usage/UsageBarsView.swift` | embed Today row + hairline (real notch) |
| `Sources/AppLib/SimulatedNotch/SimulatedNotchFullView.swift` | embed Today row + hairline in `usageHeader`; add pill-cost gear item to `popGearMenu` |
| `Sources/AppLib/SimulatedNotch/SimulatedNotchView.swift` | pill cost suffix in `compactContent` when toggled |
| `Sources/AppLib/SimulatedNotch/SimulatedNotchRoot.swift` (`NotchModeStore`) | `@Published showTodayCostInPill`, seeded at launch |
| `Sources/AppLib/SimulatedNotch/GearMenuTarget.swift` | `toggleTodayCostInPill` action |
| `Sources/AppLib/Config/ConfigStore.swift` | `showTodayCostInPill` flag (load/save) |
| `Sources/ZackEyes/AppDelegate.swift` | **reorder** so `PricingStore` is created + `start()`ed and `usageTracker.pricingStore = ps` is set **before** `usageTracker.start()` (Codex review #3 — so the first refresh prices against the loaded bundled/cache table, no cached→nil→cost flip). The `SimulatedNotchController` re-`start()` is then safe (pricing already wired). Seed `NotchModeStore` pill-cost flag |
| `Tests/AppLibTests/UsageTrackerDailyTests.swift` (new) | bucketing / codex / cost / combined |
| `Tests/AppLibTests/TodayConsumptionRowTests.swift` (new) | humanizer / sparkline / hidden-when-empty |
| `ARCHITECTURE.md` | document the consumption axis + Today data flow |

## Invariants & constraints

- **Zero deps:** Foundation/SwiftUI only.
- **LivenessFilter:** the new daily scan does not call any liveness code — it's a
  read-only token aggregator over rollout files, independent of the cwd→process
  liveness path. (The safety argument stands on that fact, not on CLAUDE.md
  invariant #7's wording, which appears stale vs `LivenessFilter.swift` — see Known
  risks. The existing Codex rate_limits + idle-prune paths are unchanged.)
- **Background queue / ~0% idle CPU:** scans stay on the `.utility` detached task at
  the existing 30s cadence; no new high-frequency polling.
- **NotchPanel invariants:** the Today row is display-only inside the existing
  panel; no focus/mouse behavior changes.
- **Local day boundaries:** all bucketing uses `Calendar.current` `startOfDay`
  (user-intuitive), tested across midnight + timezone.

## Decisions (resolved)

- **Sparkline = daily total tokens** (always available; cost can be incomplete for
  unpriced models). Main row still shows both tokens and `$`.
- **Per-agent split = always-visible subline** (`C … · X …`) — glanceable in an
  ambient panel; no hover.
- **Unpriced model → priced-portion cost + `≥` floor marker** (never hide the
  number; signal it's a floor). Bundled pricing covers the common models, so the
  marker is the rare new-model case.
- **One spec, but two implementation plans** (Codex review #13): **Plan A — data
  layer** (per-day buckets, Codex daily scan + parse cache, cost fold, pricing
  wiring, tests; **no UI**, no visible behavior) ships and is verified first, which
  forces the Codex perf/schema questions to be answered before any UI. **Plan B —
  UI/config** (TodayConsumptionRow, both surfaces, pill toggle, config, menu,
  docs) follows.
- **Per-file parse cache is in scope** (not deferred) — required to keep the full
  Codex daily scan within the idle-CPU budget.
- **Codex daily scan is separate** from the existing rate_limits scan.

## Known risks

- **Full Codex 7d rescan cost** (the headline risk — Codex review #1). New IO vs
  the prior tail-only read. Mitigated by the **in-scope per-file parse cache**
  (`(path, mtime, size)` → tallies, so steady-state ≈ the active rollout) + mtime
  prefilter + `.utility` queue. Plan A must *measure* idle CPU before Plan B; a
  coarser daily cadence is the further fallback.
- **Codex rollout schema assumption.** The per-turn-delta derivation is observed,
  not guaranteed by the codebase — locked by real-rollout fixture tests (above),
  with a `max(0, …)` guard for non-monotonic edges.
- **Stale invariant doc (flag, not fixed here).** `CLAUDE.md` invariant #7 says the
  Codex path must not enter LivenessFilter cwd detection, but `LivenessFilter.swift`
  now appears to support optional Codex cwd filtering. This predates #84 and isn't
  touched by it; worth reconciling separately.
- **Cross-agent token total is approximate** (Claude counts cache tokens
  additively; Codex doesn't). Acceptable for a glance metric; cost uses precise
  per-component math.
- **Raw model id availability.** Pricing needs raw ids; Claude `message.model` and
  Codex `turn_context.payload.model` are both present in the files we scan. A model
  missing from `pricing.json` degrades to tokens-only + `≥` marker, never a wrong
  `$` ([[pricing-price-for-takes-raw-model-ids]]).
