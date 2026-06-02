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
  unchanged. `dailyUsage` is also persisted in `usage-cache.json` (Codable); a
  restored stale "today" is corrected by the refresh that fires on `start()`.

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
- **Codex (new `scanCodexDailyTokens(rootDir:calendar:now:)`):** a **full** scan
  (not tail-only) of every rollout whose mtime is within the 7d window
  (mtime-prefiltered, like the Claude scan). For each `event_msg` line of payload
  type `token_count` carrying `info.last_token_usage` (a verified clean per-turn
  delta), accumulate its components into the local-day bucket for the **current
  model** (the most recent `turn_context.payload.model` seen earlier in that
  file, default `"unknown"` if none). Codex components map as:
  `input = input_tokens`, `cacheRead = cached_input_tokens`,
  `output = output_tokens`, `cacheCreate = 0`.
- **This is a separate scan from the existing `scanLatestCodexRateLimits`**, which
  stays exactly as-is (tail-only, 15-min active window). We do NOT fold them
  together — the rate_limits scan's 15-min semantics and the daily scan's 7d
  window are different concerns, and leaving rate_limits untouched is lower-risk.
- **Not a LivenessFilter interaction** (CLAUDE.md invariant #7): this is a
  read-only token aggregator, unrelated to the cwd→process liveness detection.

### Pure cost fold (`@MainActor`, testable)

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
PricingStore?`, wired in `AppDelegate`.

### Performance

Reuses the existing 30s refresh cadence + 7d mtime prefilter. The Claude per-day
buckets are nearly free (same scan that already runs). The Codex daily scan is the
genuinely new IO (full read of 7d rollouts vs today's tail-only) — accepted, and
bounded by the mtime prefilter + `.utility` priority. **No per-file parse cache in
v1** (YAGNI; the Claude scan already full-rescans every 30s without one — revisit
only if profiling shows pain).

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
- **Codex delta summation:** summing `last_token_usage` per day; model attributed
  from the preceding `turn_context.payload.model`; `cached_input_tokens` treated as
  a subset of `input_tokens`.
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
| `Sources/ZackEyes/AppDelegate.swift` | wire `usageTracker.pricingStore = pricingStore`; seed `NotchModeStore` flag |
| `Tests/AppLibTests/UsageTrackerDailyTests.swift` (new) | bucketing / codex / cost / combined |
| `Tests/AppLibTests/TodayConsumptionRowTests.swift` (new) | humanizer / sparkline / hidden-when-empty |
| `ARCHITECTURE.md` | document the consumption axis + Today data flow |

## Invariants & constraints

- **Zero deps:** Foundation/SwiftUI only.
- **LivenessFilter codex bypass (#7):** untouched — the daily scan is a read-only
  aggregator, not liveness detection; the existing Codex rate_limits + idle-prune
  paths are unchanged.
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
- **One spec / one plan**, ordered data-layer → shared view → both surfaces → pill
  toggle → docs.
- **Codex daily scan is separate** from the existing rate_limits scan.

## Known risks

- **Full Codex 7d rescan cost.** New IO vs the prior tail-only read. Mitigated by
  mtime prefilter + `.utility` queue + matching the existing Claude full-rescan
  pattern. If a user has very many large rollouts, a per-file (mtime,size) parse
  cache is the escape hatch — deferred until measured.
- **Cross-agent token total is approximate** (Claude counts cache tokens
  additively; Codex doesn't). Acceptable for a glance metric; cost uses precise
  per-component math.
- **Raw model id availability.** Pricing needs raw ids; Claude `message.model` and
  Codex `turn_context.payload.model` are both present in the files we scan. A model
  missing from `pricing.json` degrades to tokens-only + `≥` marker, never a wrong
  `$` ([[pricing-price-for-takes-raw-model-ids]]).
