# Daily Token Consumption — Plan A: Data Layer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the data layer for issue #84 — per-local-day token + USD-cost buckets (last 7 days, both agents) on `UsageTracker.Snapshot`, with **no UI**. Plan B adds the UI later.

**Architecture:** Token scanning stays on the existing detached `.utility` task; pricing is folded on `@MainActor` afterward via a pure function. Claude per-day tallies piggyback on the existing `computeSnapshot` pass (one read). Codex gets a new full-rollout daily scan guarded by a per-file `(mtime,size)` parse cache so steady-state cost ≈ the active rollout. Cost uses the merged `PricingStore` (#82); unpriced models count tokens but no cost (floor marker).

**Tech Stack:** Swift 6 strict concurrency, Foundation only, `Testing` framework. Spec: `docs/superpowers/specs/2026-06-02-daily-token-consumption-design.md`.

---

## File Structure

| File | Responsibility |
|------|----------------|
| `Sources/AppLib/Usage/DailyUsage.swift` (new) | Pure value types (`ModelTokenTally`, `DayUsage`) + pure functions (`buildDailyUsage`, `mergeTallies`, `parseCodexDailyTallies`). No actor state, no I/O. |
| `Sources/AppLib/Usage/UsageTracker.swift` (modify) | `Snapshot.dailyUsage` field; Claude per-day tallies in `computeSnapshot`/`parseFile`; new cached `scanCodexDailyTokens`; `weak var pricingStore`; fold in `refresh()`; clear `dailyUsage` in `loadFromCache()`. |
| `Sources/ZackEyes/AppDelegate.swift` (modify) | Reorder so `PricingStore` is started + wired into `usageTracker` **before** `usageTracker.start()`. |
| `Tests/AppLibTests/DailyUsageTests.swift` (new) | `buildDailyUsage`, `parseCodexDailyTallies` (real-rollout fixtures). |
| `Tests/AppLibTests/UsageTrackerDailyTests.swift` (new) | Claude daily scan (temp dirs, midnight/tz), Codex scan + parse cache, refresh fold, cache-not-persisted. |

All new types/functions in `DailyUsage.swift` are `nonisolated` + `Sendable`, so they're callable from the detached scan and unit-testable without the main actor.

---

## Task A1: Daily value types + pure cost fold

**Files:**
- Create: `Sources/AppLib/Usage/DailyUsage.swift`
- Test: `Tests/AppLibTests/DailyUsageTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/AppLibTests/DailyUsageTests.swift`:

```swift
import Testing
import Foundation
@testable import AppLib

struct DailyUsageTests {
    // Fixed clock so "today" is deterministic. 2026-06-02 12:00 UTC.
    static let now = Date(timeIntervalSince1970: 1_780_401_600)
    static var utc: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }

    static func pricing() -> PricingTable {
        let json = """
        {"version":"t","models":{
          "claude-opus-4-8":{"input":1e-5,"output":1e-4,"cache_read":1e-6,"cache_creation":2e-5},
          "gpt-5.5":{"input":1e-6,"output":1e-5,"cache_read":1e-7,"cache_creation":0}
        }}
        """
        return try! PricingTable(data: Data(json.utf8))
    }

    @Test func sevenZeroFilledBucketsEndingToday() {
        let days = UsageTracker.buildDailyUsage(claude: [:], codex: [:], pricing: .empty, calendar: Self.utc, now: Self.now)
        #expect(days.count == 7)
        #expect(days.last?.dayStart == Self.utc.startOfDay(for: Self.now))
        #expect(days.allSatisfy { $0.totalTokens == 0 })
        #expect(days.last?.claudeCostUSD == nil)   // no priced tokens → nil, not 0
        #expect(days.last?.anyUnpriced == false)
    }

    @Test func claudeTokensAndCostForToday() {
        let today = Self.utc.startOfDay(for: Self.now)
        let claude: [Date: [String: ModelTokenTally]] = [
            today: ["claude-opus-4-8": ModelTokenTally(input: 100, output: 10, cacheRead: 1000, cacheCreate: 50)]
        ]
        let days = UsageTracker.buildDailyUsage(claude: claude, codex: [:], pricing: Self.pricing(), calendar: Self.utc, now: Self.now)
        let t = days.last!
        #expect(t.claudeTokens == 1160)                 // 100+10+1000+50
        // 100*1e-5 + 10*1e-4 + 1000*1e-6 + 50*2e-5 = 0.001+0.001+0.001+0.001 = 0.004
        #expect(abs((t.claudeCostUSD ?? -1) - 0.004) < 1e-12)
        #expect(t.codexCostUSD == nil)
        #expect(t.anyUnpriced == false)
    }

    @Test func codexUncachedInputCost() {
        let today = Self.utc.startOfDay(for: Self.now)
        // input includes cached: input=1000, cached(cacheRead)=600, output=20
        let codex: [Date: [String: ModelTokenTally]] = [
            today: ["gpt-5.5": ModelTokenTally(input: 1000, output: 20, cacheRead: 600, cacheCreate: 0)]
        ]
        let days = UsageTracker.buildDailyUsage(claude: [:], codex: codex, pricing: Self.pricing(), calendar: Self.utc, now: Self.now)
        let t = days.last!
        #expect(t.codexTokens == 1020)                  // input+output (cached is subset of input)
        // uncached=400 *1e-6 + cached 600*1e-7 + output 20*1e-5 = 4e-4 + 6e-5 + 2e-4 = 6.6e-4
        #expect(abs((t.codexCostUSD ?? -1) - 6.6e-4) < 1e-12)
    }

    @Test func unpricedModelCountsTokensButNoCostAndSetsFlag() {
        let today = Self.utc.startOfDay(for: Self.now)
        let claude: [Date: [String: ModelTokenTally]] = [
            today: ["mystery-model": ModelTokenTally(input: 100, output: 10, cacheRead: 0, cacheCreate: 0)]
        ]
        let days = UsageTracker.buildDailyUsage(claude: claude, codex: [:], pricing: Self.pricing(), calendar: Self.utc, now: Self.now)
        let t = days.last!
        #expect(t.claudeTokens == 110)
        #expect(t.claudeCostUSD == nil)     // no priced tokens at all → nil
        #expect(t.anyUnpriced == true)      // floor marker
    }

    @Test func dropsTalliesOutsideSevenDayWindow() {
        let old = Self.utc.date(byAdding: .day, value: -30, to: Self.utc.startOfDay(for: Self.now))!
        let claude: [Date: [String: ModelTokenTally]] = [
            old: ["claude-opus-4-8": ModelTokenTally(input: 999, output: 0, cacheRead: 0, cacheCreate: 0)]
        ]
        let days = UsageTracker.buildDailyUsage(claude: claude, codex: [:], pricing: Self.pricing(), calendar: Self.utc, now: Self.now)
        #expect(days.allSatisfy { $0.claudeTokens == 0 })   // 30-day-old bucket not in the 7-day window
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter DailyUsageTests 2>&1 | tail -15`
Expected: build failure — `cannot find 'ModelTokenTally'` / `buildDailyUsage`.

- [ ] **Step 3: Create `DailyUsage.swift` with the types + `buildDailyUsage` + `mergeTallies`**

Create `Sources/AppLib/Usage/DailyUsage.swift`:

```swift
import Foundation

/// Per-(day, agent, model) token tally. Raw counts as emitted by each agent.
public struct ModelTokenTally: Sendable, Equatable {
    public var input: Int
    public var output: Int
    public var cacheRead: Int
    public var cacheCreate: Int
    public init(input: Int = 0, output: Int = 0, cacheRead: Int = 0, cacheCreate: Int = 0) {
        self.input = input; self.output = output
        self.cacheRead = cacheRead; self.cacheCreate = cacheCreate
    }
}

/// One calendar day's consumption across both agents.
public struct DayUsage: Sendable, Codable, Equatable {
    public var dayStart: Date            // local startOfDay
    public var claudeTokens: Int
    public var codexTokens: Int
    public var claudeCostUSD: Double?    // nil = no priced Claude tokens that day
    public var codexCostUSD: Double?     // nil = no priced Codex tokens that day
    public var anyUnpriced: Bool         // some tokens lacked a price → combined cost is a floor (≥)
    public var totalTokens: Int { claudeTokens + codexTokens }

    public init(dayStart: Date, claudeTokens: Int = 0, codexTokens: Int = 0,
                claudeCostUSD: Double? = nil, codexCostUSD: Double? = nil, anyUnpriced: Bool = false) {
        self.dayStart = dayStart; self.claudeTokens = claudeTokens; self.codexTokens = codexTokens
        self.claudeCostUSD = claudeCostUSD; self.codexCostUSD = codexCostUSD; self.anyUnpriced = anyUnpriced
    }
}

extension UsageTracker {
    /// Sum `src` tallies into `dst` (per day, per model).
    nonisolated static func mergeTallies(
        _ dst: inout [Date: [String: ModelTokenTally]],
        _ src: [Date: [String: ModelTokenTally]]
    ) {
        for (day, models) in src {
            for (model, t) in models {
                var cur = dst[day]?[model] ?? ModelTokenTally()
                cur.input += t.input; cur.output += t.output
                cur.cacheRead += t.cacheRead; cur.cacheCreate += t.cacheCreate
                dst[day, default: [:]][model] = cur
            }
        }
    }

    /// Pure cost fold (nonisolated; called from `@MainActor refresh()`). Builds
    /// exactly 7 zero-filled local-day buckets ending at `now`'s local day,
    /// folds tokens and `PricingTable` cost. `*CostUSD` is nil iff that agent had
    /// no priced tokens that day; `anyUnpriced` is set if some tokens lacked a price.
    nonisolated static func buildDailyUsage(
        claude: [Date: [String: ModelTokenTally]],
        codex: [Date: [String: ModelTokenTally]],
        pricing: PricingTable,
        calendar: Calendar,
        now: Date
    ) -> [DayUsage] {
        let today = calendar.startOfDay(for: now)
        let days: [Date] = (0..<7).reversed().compactMap {
            calendar.date(byAdding: .day, value: -$0, to: today)
        }
        return days.map { day in
            var u = DayUsage(dayStart: day)
            if let models = claude[day] {
                var cost = 0.0, priced = false
                for (model, t) in models {
                    u.claudeTokens += t.input + t.output + t.cacheRead + t.cacheCreate
                    if let p = pricing.price(for: model) {
                        cost += Double(t.input) * p.inputPerToken
                              + Double(t.output) * p.outputPerToken
                              + Double(t.cacheRead) * p.cacheReadPerToken
                              + Double(t.cacheCreate) * p.cacheCreatePerToken
                        priced = true
                    } else { u.anyUnpriced = true }
                }
                if priced { u.claudeCostUSD = cost }
            }
            if let models = codex[day] {
                var cost = 0.0, priced = false
                for (model, t) in models {
                    u.codexTokens += t.input + t.output    // cached is a subset of input
                    if let p = pricing.price(for: model) {
                        let uncached = max(0, t.input - t.cacheRead)
                        cost += Double(uncached) * p.inputPerToken
                              + Double(t.cacheRead) * p.cacheReadPerToken
                              + Double(t.output) * p.outputPerToken
                        priced = true
                    } else { u.anyUnpriced = true }
                }
                if priced { u.codexCostUSD = cost }
            }
            return u
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter DailyUsageTests 2>&1 | tail -15`
Expected: all 5 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/AppLib/Usage/DailyUsage.swift Tests/AppLibTests/DailyUsageTests.swift
git commit -m "feat(usage): add DayUsage/ModelTokenTally + pure buildDailyUsage (#84)"
```

---

## Task A2: Claude per-day tallies (extend `computeSnapshot`/`parseFile`)

**Files:**
- Modify: `Sources/AppLib/Usage/UsageTracker.swift` (`computeSnapshot`, `parseFile`)
- Test: `Tests/AppLibTests/UsageTrackerDailyTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/AppLibTests/UsageTrackerDailyTests.swift`:

```swift
import Testing
import Foundation
@testable import AppLib

@MainActor
struct UsageTrackerDailyTests {
    private static func tmpDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    // A Shanghai (UTC+8) calendar to prove buckets use the LOCAL day boundary.
    private static var shanghai: Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Asia/Shanghai")!; return c
    }
    private static func claudeLine(ts: String, model: String, input: Int, output: Int) -> String {
        """
        {"type":"assistant","timestamp":"\(ts)","message":{"model":"\(model)","usage":{"input_tokens":\(input),"output_tokens":\(output),"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}
        """
    }

    @Test func claudeMidnightSplitsByLocalDay() throws {
        // now = 2026-06-02 12:00 Shanghai. Two messages straddle local midnight:
        //  23:30 on 06-01 Shanghai (== 15:30Z) and 00:30 on 06-02 Shanghai (== 16:30Z 06-01).
        let now = Self.shanghai.date(from: DateComponents(timeZone: TimeZone(identifier: "Asia/Shanghai"),
            year: 2026, month: 6, day: 2, hour: 12))!
        let projects = try Self.tmpDir()
        let proj = projects.appendingPathComponent("p"); try FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)
        let text = [
            Self.claudeLine(ts: "2026-06-01T15:30:00.000Z", model: "claude-opus-4-8", input: 10, output: 1),  // 23:30 06-01 SH
            Self.claudeLine(ts: "2026-06-01T16:30:00.000Z", model: "claude-opus-4-8", input: 20, output: 2)   // 00:30 06-02 SH
        ].joined(separator: "\n")
        try text.write(to: proj.appendingPathComponent("s.jsonl"), atomically: true, encoding: .utf8)

        let res = UsageTracker.computeSnapshot(projectsDir: projects, calendar: Self.shanghai, now: now)
        let jun1 = Self.shanghai.startOfDay(for: Self.shanghai.date(from: DateComponents(timeZone: TimeZone(identifier: "Asia/Shanghai"), year: 2026, month: 6, day: 1, hour: 12))!)
        let jun2 = Self.shanghai.startOfDay(for: now)
        #expect(res.daily[jun1]?["claude-opus-4-8"]?.input == 10)   // first msg → 06-01 local
        #expect(res.daily[jun2]?["claude-opus-4-8"]?.input == 20)   // second msg → 06-02 local
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter UsageTrackerDailyTests 2>&1 | tail -15`
Expected: failure — `computeSnapshot` doesn't take `calendar:`/`now:` and has no `.daily`.

- [ ] **Step 3: Add `ClaudeScanResult` and rewrite `computeSnapshot`**

In `Sources/AppLib/Usage/UsageTracker.swift`, replace the entire existing `computeSnapshot` function (the `private nonisolated static func computeSnapshot(projectsDir: URL) -> Snapshot { ... }`) with:

```swift
    /// Result of one Claude transcript scan: the 5h/7d estimate plus per-local-day
    /// token tallies (for the #84 Today row).
    struct ClaudeScanResult: Sendable {
        var snapshot: Snapshot
        var daily: [Date: [String: ModelTokenTally]]
    }

    nonisolated static func computeSnapshot(
        projectsDir: URL,
        calendar: Calendar = .current,
        now: Date = Date()
    ) -> ClaudeScanResult {
        let cutoff5h = now.addingTimeInterval(-5 * 3600)
        let cutoff7d = now.addingTimeInterval(-7 * 86400)
        // Daily window: the 7 local days ending today (startOfDay(today) - 6 days).
        let dailyCutoff = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now)) ?? cutoff7d
        // Keep any file touched within the wider of the two windows.
        let fileCutoff = min(cutoff7d, dailyCutoff)

        let fm = FileManager.default
        guard let projectDirs = try? fm.contentsOfDirectory(
            at: projectsDir, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return ClaudeScanResult(snapshot: .empty, daily: [:]) }

        var tokens5h = 0, tokens7d = 0, msgs5h = 0, msgs7d = 0
        var daily: [Date: [String: ModelTokenTally]] = [:]

        for projectDir in projectDirs {
            guard let files = try? fm.contentsOfDirectory(
                at: projectDir, includingPropertiesForKeys: [.contentModificationDateKey]
            ) else { continue }
            for file in files where file.pathExtension == "jsonl" {
                if let attrs = try? fm.attributesOfItem(atPath: file.path),
                   let mod = attrs[.modificationDate] as? Date, mod < fileCutoff {
                    continue
                }
                parseFile(at: file, cutoff5h: cutoff5h, cutoff7d: cutoff7d,
                          dailyCutoff: dailyCutoff, calendar: calendar,
                          tokens5h: &tokens5h, tokens7d: &tokens7d,
                          msgs5h: &msgs5h, msgs7d: &msgs7d, daily: &daily)
            }
        }

        let snapshot = Snapshot(
            fiveHourUsedPct: nil, fiveHourResetsAt: nil,
            sevenDayUsedPct: nil, sevenDayResetsAt: nil,
            tokens5h: tokens5h, tokens7d: tokens7d,
            messages5h: msgs5h, messages7d: msgs7d
        )
        return ClaudeScanResult(snapshot: snapshot, daily: daily)
    }
```

(`computeSnapshot` changes from `private` to internal `nonisolated static` so the test can call it.)

- [ ] **Step 4: Extend `parseFile` to accumulate daily tallies**

In the same file, replace the existing `parseFile` signature and its token-accumulation tail. Change the signature to:

```swift
    private nonisolated static func parseFile(
        at url: URL,
        cutoff5h: Date, cutoff7d: Date,
        dailyCutoff: Date, calendar: Calendar,
        tokens5h: inout Int, tokens7d: inout Int,
        msgs5h: inout Int, msgs7d: inout Int,
        daily: inout [Date: [String: ModelTokenTally]]
    ) {
```

Then, inside the `for line in text.split(...)` loop, replace the existing accumulation block:

```swift
            let total = input + output + cacheRead + cacheCreate

            tokens7d += total
            msgs7d += 1
            if ts >= cutoff5h {
                tokens5h += total
                msgs5h += 1
            }
```

with:

```swift
            let total = input + output + cacheRead + cacheCreate

            tokens7d += total
            msgs7d += 1
            if ts >= cutoff5h {
                tokens5h += total
                msgs5h += 1
            }

            // #84 per-local-day tally (subset of the 7d window, by local calendar day).
            if ts >= dailyCutoff {
                let model = (msg["model"] as? String) ?? "unknown"
                let day = calendar.startOfDay(for: ts)
                var tally = daily[day]?[model] ?? ModelTokenTally()
                tally.input += input; tally.output += output
                tally.cacheRead += cacheRead; tally.cacheCreate += cacheCreate
                daily[day, default: [:]][model] = tally
            }
```

- [ ] **Step 5: Fix the existing `refresh()` call site so it compiles**

In `refresh()`, change the Claude scan line from `Self.computeSnapshot(projectsDir: dir)` to capture local clock and use `.snapshot` (the `.daily` is wired in Task A5):

Replace:
```swift
        let estimated = await Task.detached(priority: .utility) {
            Self.computeSnapshot(projectsDir: dir)
        }.value
```
with:
```swift
        let cal = Calendar.current
        let scanNow = Date()
        let claudeScan = await Task.detached(priority: .utility) {
            Self.computeSnapshot(projectsDir: dir, calendar: cal, now: scanNow)
        }.value
        let estimated = claudeScan.snapshot
```

(`estimated` keeps its existing uses below; `claudeScan.daily`, `cal`, `scanNow` are used in Task A5.)

- [ ] **Step 6: Run the test + full build**

Run: `swift test --filter UsageTrackerDailyTests 2>&1 | tail -15` → PASS.
Run: `swift build 2>&1 | tail -3` → Build complete.

- [ ] **Step 7: Commit**

```bash
git add Sources/AppLib/Usage/UsageTracker.swift Tests/AppLibTests/UsageTrackerDailyTests.swift
git commit -m "feat(usage): bucket Claude per-local-day token tallies in computeSnapshot (#84)"
```

---

## Task A3: Codex daily parser (pure, total-diff deltas)

**Files:**
- Modify: `Sources/AppLib/Usage/DailyUsage.swift` (add `parseCodexDailyTallies`)
- Test: `Tests/AppLibTests/DailyUsageTests.swift` (append)

- [ ] **Step 1: Write the failing test (append to `DailyUsageTests`)**

Add these inside `struct DailyUsageTests`:

```swift
    // Real-rollout-shaped fixture: session_meta, turn_context (model), then two
    // token_count events whose cumulative total_token_usage grows per turn.
    static func codexRollout() -> String {
        [
        #"{"type":"session_meta","timestamp":"2026-06-02T03:00:00.000Z","payload":{"id":"x"}}"#,
        #"{"type":"turn_context","timestamp":"2026-06-02T03:00:01.000Z","payload":{"model":"gpt-5.5"}}"#,
        // turn 1: cumulative input=100 (cached 40), output=10
        #"{"type":"event_msg","timestamp":"2026-06-02T03:00:02.000Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":40,"output_tokens":10,"total_tokens":110},"total_token_usage":{"input_tokens":100,"cached_input_tokens":40,"output_tokens":10,"total_tokens":110}}}}"#,
        // turn 2: cumulative input=300 (cached 140), output=30 → delta input=200, cached=100, output=20
        #"{"type":"event_msg","timestamp":"2026-06-02T03:00:03.000Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":200,"cached_input_tokens":100,"output_tokens":20,"total_tokens":220},"total_token_usage":{"input_tokens":300,"cached_input_tokens":140,"output_tokens":30,"total_tokens":330}}}}"#
        ].joined(separator: "\n")
    }

    @Test func codexDeltaFromCumulativeTotals() {
        // now 2026-06-02 12:00 UTC; cutoff = startOfDay - 6d, so everything is in-window.
        let tallies = UsageTracker.parseCodexDailyTallies(text: Self.codexRollout(), calendar: Self.utc,
            cutoff: Self.utc.date(byAdding: .day, value: -6, to: Self.utc.startOfDay(for: Self.now))!)
        let day = Self.utc.startOfDay(for: Self.now)
        let t = tallies[day]?["gpt-5.5"]
        #expect(t?.input == 300)        // 100 + 200 (per-turn deltas of cumulative input)
        #expect(t?.cacheRead == 140)    // 40 + 100 (cached deltas)
        #expect(t?.output == 30)        // 10 + 20
        #expect(t?.cacheCreate == 0)    // codex has no cache-creation
    }

    @Test func codexDropsTurnsBeforeCutoff() {
        let line = #"{"type":"turn_context","timestamp":"2020-01-01T00:00:00.000Z","payload":{"model":"gpt-5.5"}}"#
            + "\n" + #"{"type":"event_msg","timestamp":"2020-01-01T00:00:01.000Z","payload":{"type":"token_count","info":{"last_token_usage":{},"total_token_usage":{"input_tokens":500,"cached_input_tokens":0,"output_tokens":50,"total_tokens":550}}}}"#
        let tallies = UsageTracker.parseCodexDailyTallies(text: line, calendar: Self.utc,
            cutoff: Self.utc.date(byAdding: .day, value: -6, to: Self.utc.startOfDay(for: Self.now))!)
        #expect(tallies.isEmpty)        // 2020 turn is far before the 7-day window
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter codexDeltaFromCumulativeTotals 2>&1 | tail -15`
Expected: `cannot find 'parseCodexDailyTallies'`.

- [ ] **Step 3: Add `parseCodexDailyTallies` to `DailyUsage.swift`**

Add inside the `extension UsageTracker { ... }` in `Sources/AppLib/Usage/DailyUsage.swift`:

```swift
    /// Parse ONE codex rollout's text into per-local-day, per-model tallies.
    /// Per-turn token deltas are derived from the **cumulative** `total_token_usage`
    /// component diffs (robust by construction — does not trust `last_token_usage`).
    /// Model is the most recent `turn_context.payload.model` seen in the file.
    nonisolated static func parseCodexDailyTallies(
        text: String, calendar: Calendar, cutoff: Date
    ) -> [Date: [String: ModelTokenTally]] {
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoNoFrac = ISO8601DateFormatter()
        var out: [Date: [String: ModelTokenTally]] = [:]
        var currentModel = "unknown"
        var prevInput = 0, prevCached = 0, prevOutput = 0
        var sawTotals = false

        for line in text.split(separator: "\n") {
            guard let d = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
            let type = obj["type"] as? String
            let payload = obj["payload"] as? [String: Any]

            if type == "turn_context", let m = payload?["model"] as? String {
                currentModel = m; continue
            }
            guard type == "event_msg",
                  (payload?["type"] as? String) == "token_count",
                  let info = payload?["info"] as? [String: Any],
                  let totals = info["total_token_usage"] as? [String: Any] else { continue }

            let curInput = (totals["input_tokens"] as? Int) ?? prevInput
            let curCached = (totals["cached_input_tokens"] as? Int) ?? prevCached
            let curOutput = (totals["output_tokens"] as? Int) ?? prevOutput
            // First totals row in this file establishes the baseline (= the turn's own usage).
            let dInput = sawTotals ? max(0, curInput - prevInput) : curInput
            let dCached = sawTotals ? max(0, curCached - prevCached) : curCached
            let dOutput = sawTotals ? max(0, curOutput - prevOutput) : curOutput
            prevInput = curInput; prevCached = curCached; prevOutput = curOutput; sawTotals = true

            guard let tsString = obj["timestamp"] as? String,
                  let ts = iso.date(from: tsString) ?? isoNoFrac.date(from: tsString),
                  ts >= cutoff, (dInput + dOutput) > 0 else { continue }

            let day = calendar.startOfDay(for: ts)
            var tally = out[day]?[currentModel] ?? ModelTokenTally()
            tally.input += dInput
            tally.cacheRead += dCached
            tally.output += dOutput
            out[day, default: [:]][currentModel] = tally
        }
        return out
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter DailyUsageTests 2>&1 | tail -15`
Expected: all DailyUsageTests pass (7 now).

- [ ] **Step 5: Commit**

```bash
git add Sources/AppLib/Usage/DailyUsage.swift Tests/AppLibTests/DailyUsageTests.swift
git commit -m "feat(usage): add Codex per-day token parser via cumulative-total diffs (#84)"
```

---

## Task A4: Cached Codex daily scan (file walk + `(mtime,size)` cache)

**Files:**
- Modify: `Sources/AppLib/Usage/UsageTracker.swift` (add `FileTally`, `scanCodexDailyTokens`)
- Test: `Tests/AppLibTests/UsageTrackerDailyTests.swift` (append)

- [ ] **Step 1: Write the failing test (append to `UsageTrackerDailyTests`)**

Add inside `struct UsageTrackerDailyTests`:

```swift
    private static func codexDayDir(under root: URL, now: Date) -> URL {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!
        let comps = c.dateComponents([.year, .month, .day], from: now)
        return root.appendingPathComponent(String(format: "%04d/%02d/%02d", comps.year!, comps.month!, comps.day!))
    }

    @Test func codexScanReadsRolloutAndCacheIsHonored() throws {
        let now = Date()
        let root = try Self.tmpDir()
        let dayDir = Self.codexDayDir(under: root, now: now)
        try FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)
        let file = dayDir.appendingPathComponent("rollout-x.jsonl")
        // a turn_context + token_count with a recent timestamp (use now's ISO)
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let tsString = iso.string(from: now)
        let text = #"{"type":"turn_context","timestamp":"\#(tsString)","payload":{"model":"gpt-5.5"}}"#
            + "\n" + #"{"type":"event_msg","timestamp":"\#(tsString)","payload":{"type":"token_count","info":{"last_token_usage":{},"total_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":10,"total_tokens":110}}}}"#
        try text.write(to: file, atomically: true, encoding: .utf8)

        let cal = Calendar.current
        let r1 = UsageTracker.scanCodexDailyTokens(rootDir: root, cache: [:], calendar: cal, now: now)
        let today = cal.startOfDay(for: now)
        #expect(r1.merged[today]?["gpt-5.5"]?.input == 100)
        #expect(r1.cache[file.path] != nil)

        // Re-scan with a cache that returns a SENTINEL tally for the unchanged file →
        // proves the cache is used (file not re-parsed).
        var poisoned = r1.cache
        poisoned[file.path]?.tallies = [today: ["sentinel": ModelTokenTally(input: 7)]]
        let r2 = UsageTracker.scanCodexDailyTokens(rootDir: root, cache: poisoned, calendar: cal, now: now)
        #expect(r2.merged[today]?["sentinel"]?.input == 7)        // served from cache
        #expect(r2.merged[today]?["gpt-5.5"] == nil)
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter codexScanReadsRolloutAndCacheIsHonored 2>&1 | tail -15`
Expected: `cannot find 'scanCodexDailyTokens'` / `FileTally`.

- [ ] **Step 3: Add `FileTally` + `scanCodexDailyTokens`**

In `Sources/AppLib/Usage/UsageTracker.swift`, add (near the other codex scan helpers):

```swift
    /// Cached parse of one rollout file, keyed by identity `(mtime, size)`.
    struct FileTally: Sendable {
        var mtime: Date
        var size: UInt64
        var tallies: [Date: [String: ModelTokenTally]]
    }

    /// Full-window Codex daily-token scan with a per-file parse cache. Walks all
    /// date dirs (codex --resume appends to old dirs), skips files untouched within
    /// the 7-day window, and reuses cached tallies for files whose `(mtime,size)`
    /// is unchanged — so steady-state cost ≈ the active rollout. Returns the merged
    /// tallies plus the refreshed cache (the caller stores the cache on @MainActor).
    nonisolated static func scanCodexDailyTokens(
        rootDir: URL,
        cache: [String: FileTally],
        calendar: Calendar,
        now: Date
    ) -> (merged: [Date: [String: ModelTokenTally]], cache: [String: FileTally]) {
        let dailyCutoff = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now))
            ?? now.addingTimeInterval(-7 * 86400)
        let fm = FileManager.default
        var newCache: [String: FileTally] = [:]
        var merged: [Date: [String: ModelTokenTally]] = [:]

        for dayDir in SessionScanner.allDateDirs(under: rootDir) {
            guard let files = try? fm.contentsOfDirectory(
                at: dayDir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
            ) else { continue }
            for file in files where file.pathExtension == "jsonl" {
                guard let vals = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                      let mtime = vals.contentModificationDate,
                      let size = vals.fileSize else { continue }
                if mtime < dailyCutoff { continue }   // file untouched within the window
                let key = file.path
                let tallies: [Date: [String: ModelTokenTally]]
                if let hit = cache[key], hit.mtime == mtime, hit.size == UInt64(size) {
                    tallies = hit.tallies               // cache hit — no re-parse
                } else if let text = try? String(contentsOf: file, encoding: .utf8) {
                    tallies = parseCodexDailyTallies(text: text, calendar: calendar, cutoff: dailyCutoff)
                } else {
                    tallies = [:]
                }
                newCache[key] = FileTally(mtime: mtime, size: UInt64(size), tallies: tallies)
                mergeTallies(&merged, tallies)
            }
        }
        return (merged, newCache)
    }
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter codexScanReadsRolloutAndCacheIsHonored 2>&1 | tail -15`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/AppLib/Usage/UsageTracker.swift Tests/AppLibTests/UsageTrackerDailyTests.swift
git commit -m "feat(usage): cached full-rollout Codex daily-token scan (#84)"
```

---

## Task A5: Wire `dailyUsage` into `Snapshot` + `refresh()` + `loadFromCache()`

**Files:**
- Modify: `Sources/AppLib/Usage/UsageTracker.swift` (`Snapshot`, `refresh`, `loadFromCache`, add `pricingStore` + caches)
- Test: `Tests/AppLibTests/UsageTrackerDailyTests.swift` (append)

- [ ] **Step 1: Write the failing test (append to `UsageTrackerDailyTests`)**

```swift
    @Test func refreshPopulatesSevenDayUsageWithCost() async throws {
        let now = Date()
        // Claude transcript with one of today's messages.
        let projects = try Self.tmpDir()
        let proj = projects.appendingPathComponent("p"); try FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let line = """
        {"type":"assistant","timestamp":"\(iso.string(from: now))","message":{"model":"claude-opus-4-8","usage":{"input_tokens":1000,"output_tokens":100,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}
        """
        try line.write(to: proj.appendingPathComponent("s.jsonl"), atomically: true, encoding: .utf8)

        let tracker = UsageTracker(projectsDir: projects, codexSessionsDir: nil)
        let store = PricingStore(cacheURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
                                 bundledData: { Data(#"{"version":"t","models":{"claude-opus-4-8":{"input":1e-5,"output":1e-4,"cache_read":0,"cache_creation":0}}}"#.utf8) },
                                 fetch: { nil })
        store.loadInitial()
        tracker.pricingStore = store

        await tracker.refresh()
        let today = Calendar.current.startOfDay(for: now)
        let day = tracker.snapshot.dailyUsage.first { $0.dayStart == today }
        #expect(tracker.snapshot.dailyUsage.count == 7)
        #expect(day?.claudeTokens == 1100)
        // 1000*1e-5 + 100*1e-4 = 0.01 + 0.01 = 0.02
        #expect(abs((day?.claudeCostUSD ?? -1) - 0.02) < 1e-12)
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter refreshPopulatesSevenDayUsageWithCost 2>&1 | tail -15`
Expected: failure — `pricingStore` / `dailyUsage` not found.

- [ ] **Step 3: Add `dailyUsage` to `Snapshot`**

In `Sources/AppLib/Usage/UsageTracker.swift`, in the `Snapshot` struct, after the `public var lastUpdated: Date?` line, add:

```swift

        // #84 — per-local-day consumption (tokens + cost), 7 entries oldest→today.
        // NOT trusted from cache (cleared on load, rebuilt by refresh) to avoid a
        // stale "today" after midnight.
        public var dailyUsage: [DayUsage] = []
```

(The `= []` default keeps the `.empty` and `computeSnapshot` `Snapshot(...)` sites compiling unchanged.)

- [ ] **Step 4: Add `pricingStore` + the codex parse cache as stored properties**

In the same file, just after the `@Published public private(set) var snapshot: Snapshot = .empty` line, add:

```swift

    /// Pricing source for daily cost (both `@MainActor`; read after the detached
    /// scan returns). Weak so it never extends the store's lifetime.
    public weak var pricingStore: PricingStore?

    /// Per-file Codex daily-scan parse cache, keyed by file path. Lives on the
    /// main actor; passed by value into the detached scan and replaced on return.
    private var codexDailyCache: [String: FileTally] = [:]
```

- [ ] **Step 5: Fold daily usage into `refresh()`**

In `refresh()`, you already (Task A2 Step 5) have `claudeScan`, `cal`, `scanNow`, and `estimated`. Replace the **codex observation** block and the trailing snapshot assignment so the daily fold runs. Specifically, change this existing block:

```swift
        let codexObservation = await Task.detached(priority: .utility) { () -> CodexRateLimitObservation? in
            guard let codexDir else { return nil }
            return Self.scanLatestCodexRateLimits(rootDir: codexDir)
        }.value

        var merged = snapshot
        merged.tokens5h = estimated.tokens5h
        merged.tokens7d = estimated.tokens7d
        merged.messages5h = estimated.messages5h
        merged.messages7d = estimated.messages7d
        self.snapshot = merged
```

to:

```swift
        let codexObservation = await Task.detached(priority: .utility) { () -> CodexRateLimitObservation? in
            guard let codexDir else { return nil }
            return Self.scanLatestCodexRateLimits(rootDir: codexDir)
        }.value

        // #84 daily token scan (Codex), with the per-file parse cache.
        let codexCacheSnapshot = codexDailyCache
        let codexDaily = await Task.detached(priority: .utility) {
            () -> (merged: [Date: [String: ModelTokenTally]], cache: [String: FileTally])? in
            guard let codexDir else { return nil }
            return Self.scanCodexDailyTokens(rootDir: codexDir, cache: codexCacheSnapshot, calendar: cal, now: scanNow)
        }.value
        if let codexDaily { codexDailyCache = codexDaily.cache }

        var merged = snapshot
        merged.tokens5h = estimated.tokens5h
        merged.tokens7d = estimated.tokens7d
        merged.messages5h = estimated.messages5h
        merged.messages7d = estimated.messages7d
        merged.dailyUsage = Self.buildDailyUsage(
            claude: claudeScan.daily,
            codex: codexDaily?.merged ?? [:],
            pricing: pricingStore?.table ?? .empty,
            calendar: cal, now: scanNow
        )
        self.snapshot = merged
```

- [ ] **Step 6: Clear `dailyUsage` in `loadFromCache()`**

In `loadFromCache()`, change:

```swift
        snapshot = cached
```
to:
```swift
        var restored = cached
        restored.dailyUsage = []   // #84: never trust a persisted (possibly stale) "today"
        snapshot = restored
```

- [ ] **Step 7: Run the test + full suite**

Run: `swift test --filter refreshPopulatesSevenDayUsageWithCost 2>&1 | tail -15` → PASS.
Run: `swift test 2>&1 | tail -6` → all tests pass (no regressions).

- [ ] **Step 8: Commit**

```bash
git add Sources/AppLib/Usage/UsageTracker.swift Tests/AppLibTests/UsageTrackerDailyTests.swift
git commit -m "feat(usage): fold daily token+cost into Snapshot.dailyUsage on refresh (#84)"
```

---

## Task A6: Wire `PricingStore` into `UsageTracker` at launch (ordering fix)

**Files:**
- Modify: `Sources/ZackEyes/AppDelegate.swift`

No new unit test (app glue); correctness = clean build + full suite green + the ordering invariant.

- [ ] **Step 1: Reorder so pricing is created + wired before usage starts**

In `Sources/ZackEyes/AppDelegate.swift`, the current sequence is: `usageTracker = UsageTracker()` then `usageTracker.start(intervalSeconds: 30)` (near line 76–82), and later `let ps = PricingStore(); pricingStore = ps; ps.start()` (the `3.6` block added for #82). Move the PricingStore creation **above** the usage-tracker start and wire it. Replace the `3.5 Usage tracker` + `3.6 Pricing` region so it reads:

```swift
        // 3.5 Pricing table (must exist + be wired before the usage tracker starts,
        // so the first daily refresh prices against the loaded bundled/cache table).
        let ps = PricingStore()
        pricingStore = ps
        ps.start()

        // 3.6 Usage tracker (5h/7d quota + #84 daily consumption). Pricing wired in
        // so daily cost is available from the first refresh.
        usageTracker = UsageTracker()
        usageTracker.pricingStore = ps
        usageTracker.start(intervalSeconds: 30)
```

Delete the old standalone `3.6 Pricing table` block (the one added in #82 that created `ps` after the usage tracker) so `PricingStore` is created exactly once. Keep the existing `pricingStore?.stop()` / `usageTracker.stop()` teardown calls as-is.

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build 2>&1 | tail -5`
Expected: Build complete, no errors.

- [ ] **Step 3: Run the full suite**

Run: `swift test 2>&1 | tail -6`
Expected: all tests pass.

- [ ] **Step 4: Commit**

```bash
git add Sources/ZackEyes/AppDelegate.swift
git commit -m "feat(app): wire PricingStore into UsageTracker before start (#84)"
```

---

## Self-Review

**Spec coverage (data-layer items):**
- `DayUsage` + `Snapshot.dailyUsage` (7 buckets, oldest→today) → Task A1 + A5. ✅
- Claude per-day buckets in the existing scan (model from `message.model`) → Task A2. ✅
- Codex full-rollout daily scan, separate from rate_limits scan → Task A4 (uses A3). ✅
- Per-turn delta from cumulative `total_token_usage` diffs + `max(0,…)` → Task A3. ✅
- Per-file `(mtime,size)` parse cache → Task A4. ✅
- Pure `buildDailyUsage(…, pricing, calendar, now)`, nonisolated, nil-vs-0 + `anyUnpriced` → Task A1. ✅
- Off-main scan / on-main pricing (`pricingStore?.table` read after detached returns; closures capture only Sendable inputs) → Task A5. ✅
- `dailyUsage` NOT trusted from cache → Task A5 Step 6. ✅
- AppDelegate ordering (pricing before usage start) → Task A6. ✅
- Tests: midnight/timezone bucketing (A2, Shanghai calendar), Codex delta fixtures (A3), cost priced/unpriced/nil-vs-0 (A1), combined totals (A1/A5), parse cache (A4). ✅
- **No UI / no pill / no config** — correctly deferred to Plan B. ✅

**Placeholder scan:** every code step has complete code; commands have expected output; no "TBD"/"handle edge cases"/"similar to". Fixtures are concrete real-rollout-shaped JSON.

**Type consistency:** `ModelTokenTally(input:output:cacheRead:cacheCreate:)`, `DayUsage(dayStart:…)`, `buildDailyUsage(claude:codex:pricing:calendar:now:)`, `mergeTallies(_:_:)`, `parseCodexDailyTallies(text:calendar:cutoff:)`, `computeSnapshot(projectsDir:calendar:now:) -> ClaudeScanResult` (`.snapshot`/`.daily`), `parseFile(…dailyCutoff:calendar:…daily:)`, `scanCodexDailyTokens(rootDir:cache:calendar:now:) -> (merged:cache:)`, `FileTally(mtime:size:tallies:)`, `UsageTracker.pricingStore`, `codexDailyCache`, `Snapshot.dailyUsage` — all used identically across tasks. `PricingStore`/`PricingTable`/`ModelPrice` match the merged #82 API (`price(for:)`, `.table`, `init(cacheURL:bundledData:fetch:)`, `.empty`).

**Note:** `computeSnapshot` is made internal `nonisolated static` (was `private`) so its test can call it directly — consistent with how `scanCodexDailyTokens` is exposed for tests.
