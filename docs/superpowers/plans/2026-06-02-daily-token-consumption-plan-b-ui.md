# Daily Token Consumption — Plan B: UI/Config Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Surface issue #84's daily consumption data (shipped in Plan A as `Snapshot.dailyUsage`) in the UI — a shared "Today" row (tokens + cost + 7-day sparkline + per-agent subline) in both notch surfaces, plus an optional gear toggle that appends today's cost to the compact pill.

**Architecture:** A new self-contained `TodayConsumptionRow` SwiftUI view with pure static formatting helpers (humanizer, cost string, sparkline normalization) that are unit-tested; the view is embedded read-only below the existing 5h/7d bars in both `UsageBarsView` (real notch) and `SimulatedNotchFullView.usageHeader` (simulated). The pill toggle reuses the exact `compactAgent` plumbing pattern (ConfigStore field → NotchModeStore `@Published` → GearMenuTarget action → seeded by the controller at launch).

**Tech Stack:** Swift 6 strict concurrency, SwiftUI/Foundation only, `Testing` framework (+ XCTest for `ConfigStoreTests`). Builds on Plan A (`DayUsage`, `Snapshot.dailyUsage`). Spec: `docs/superpowers/specs/2026-06-02-daily-token-consumption-design.md`.

**Branch:** continues on `feat/84-daily-token-cost` (stacked on Plan A; same PR #90).

---

## File Structure

| File | Responsibility |
|------|----------------|
| `Sources/AppLib/Usage/TodayConsumptionRow.swift` (new) | The shared Today row view + `SparklineView` + pure static helpers (`humanizeTokens`, `costString`, `sparklineFractions`, `combinedCost`). |
| `Sources/AppLib/Usage/UsageTracker.swift` (modify) | Add `Snapshot.hasConsumption` computed flag. |
| `Sources/AppLib/Usage/UsageBarsView.swift` (modify) | Embed the Today row + hairline below the 5h/7d bars (real notch). |
| `Sources/AppLib/SimulatedNotch/SimulatedNotchFullView.swift` (modify) | Embed the Today row + hairline in `usageHeader`; add the pill-cost toggle to `popGearMenu`. |
| `Sources/AppLib/Config/ConfigStore.swift` (modify) | `showTodayCostInPill` flag (ConfigWrapper field + load/save). |
| `Sources/AppLib/SimulatedNotch/SimulatedNotchRoot.swift` (modify) | `NotchModeStore.showTodayCostInPill` `@Published`. |
| `Sources/AppLib/SimulatedNotch/SimulatedNotchController.swift` (modify) | Seed the flag from `ConfigStore` at launch. |
| `Sources/AppLib/SimulatedNotch/GearMenuTarget.swift` (modify) | `toggleTodayCostInPillClicked` action. |
| `Sources/AppLib/SimulatedNotch/SimulatedNotchView.swift` (modify) | `compactContent` appends compact cost when toggled. |
| `Tests/AppLibTests/TodayConsumptionRowTests.swift` (new) | Pure-helper tests (humanizer, cost string, sparkline, combinedCost, hasConsumption). |
| `Tests/AppLibTests/ConfigStoreTests.swift` (modify) | `showTodayCostInPill` round-trip + default. |
| `ARCHITECTURE.md` (modify) | Document the consumption axis + Today row. |

SwiftUI view bodies aren't unit-tested directly; all branchable logic (formatting, sparkline scaling, cost combination, visibility gating) lives in tested pure helpers, and the view wiring is verified by build + manual/screenshot validation (Task B8).

---

## Task B1: `TodayConsumptionRow` view + pure helpers

**Files:**
- Create: `Sources/AppLib/Usage/TodayConsumptionRow.swift`
- Test: `Tests/AppLibTests/TodayConsumptionRowTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/AppLibTests/TodayConsumptionRowTests.swift`:

```swift
import Testing
import Foundation
@testable import AppLib

struct TodayConsumptionRowTests {
    @Test func humanizeTokens() {
        #expect(TodayConsumptionRow.humanizeTokens(1_400_000) == "1.4M")
        #expect(TodayConsumptionRow.humanizeTokens(12_000_000) == "12M")
        #expect(TodayConsumptionRow.humanizeTokens(1_000_000) == "1M")
        #expect(TodayConsumptionRow.humanizeTokens(340_000) == "340K")
        #expect(TodayConsumptionRow.humanizeTokens(12_000) == "12K")
        #expect(TodayConsumptionRow.humanizeTokens(1234) == "1234")
        #expect(TodayConsumptionRow.humanizeTokens(0) == "0")
    }

    @Test func costString() {
        #expect(TodayConsumptionRow.costString(4.2, floor: false) == "$4.20")
        #expect(TodayConsumptionRow.costString(4.2, floor: true) == "≥$4.20")
        #expect(TodayConsumptionRow.costString(nil, floor: false) == nil)
        #expect(TodayConsumptionRow.costString(4.25, floor: false, compact: true) == "$4.2")
        #expect(TodayConsumptionRow.costString(4.25, floor: true, compact: true) == "≥$4.2")
    }

    @Test func sparklineFractions() {
        #expect(TodayConsumptionRow.sparklineFractions([0, 5, 10]) == [0, 0.5, 1.0])
        #expect(TodayConsumptionRow.sparklineFractions([0, 0, 0]) == [0, 0, 0])
        #expect(TodayConsumptionRow.sparklineFractions([]) == [])
    }

    @Test func combinedCost() {
        let d = Date(timeIntervalSince1970: 0)
        #expect(TodayConsumptionRow.combinedCost(DayUsage(dayStart: d, claudeCostUSD: 1.0, codexCostUSD: 2.0)) == 3.0)
        #expect(TodayConsumptionRow.combinedCost(DayUsage(dayStart: d, claudeCostUSD: 1.5, codexCostUSD: nil)) == 1.5)
        #expect(TodayConsumptionRow.combinedCost(DayUsage(dayStart: d, claudeCostUSD: nil, codexCostUSD: nil)) == nil)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter TodayConsumptionRowTests 2>&1 | tail -15`
Expected: `cannot find 'TodayConsumptionRow' in scope`.

- [ ] **Step 3: Create `Sources/AppLib/Usage/TodayConsumptionRow.swift`**

```swift
import SwiftUI

/// One-glance "Today" consumption row: humanized today tokens · cost · a 7-day
/// token sparkline, with a per-agent subline. Shared by the real-notch
/// (`UsageBarsView`) and simulated-notch (`SimulatedNotchFullView`) headers.
/// Display-only; all branchable logic is in the tested static helpers below.
struct TodayConsumptionRow: View {
    let today: DayUsage
    let series: [Int]   // 7 daily totalTokens, oldest → today (rightmost = today)

    private static let accent = Color(red: 0.31, green: 0.80, blue: 0.77)

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text("Today")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.7))
                Text("\(Self.humanizeTokens(today.totalTokens)) tok")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.85))
                if let cost = Self.costString(Self.combinedCost(today), floor: today.anyUnpriced) {
                    Text("· \(cost)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Self.accent)
                }
                Spacer(minLength: 6)
                SparklineView(values: series)
                    .frame(width: 56, height: 12)
            }
            if let sub = subline {
                Text(sub)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.45))
            }
        }
    }

    private var subline: String? {
        var parts: [String] = []
        if today.claudeTokens > 0 { parts.append("C \(Self.humanizeTokens(today.claudeTokens))") }
        if today.codexTokens > 0 { parts.append("X \(Self.humanizeTokens(today.codexTokens))") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: - Pure helpers (unit-tested)

    /// 1_400_000 → "1.4M", 12_000_000 → "12M", 340_000 → "340K", 1234 → "1234".
    static func humanizeTokens(_ n: Int) -> String {
        guard n > 0 else { return "0" }
        if n >= 1_000_000 {
            let s = String(format: "%.1f", Double(n) / 1_000_000)
            return (s.hasSuffix(".0") ? String(s.dropLast(2)) : s) + "M"
        }
        if n >= 10_000 {
            return "\(Int((Double(n) / 1000).rounded()))K"
        }
        return "\(n)"
    }

    /// Sum of the per-agent costs, or nil if neither agent had priced tokens.
    static func combinedCost(_ day: DayUsage) -> Double? {
        switch (day.claudeCostUSD, day.codexCostUSD) {
        case (nil, nil):            return nil
        case let (c?, x?):          return c + x
        case let (c?, nil):         return c
        case let (nil, x?):         return x
        }
    }

    /// "$4.20" / "≥$4.20" (or compact "$4.2"); nil when `usd` is nil.
    static func costString(_ usd: Double?, floor: Bool, compact: Bool = false) -> String? {
        guard let usd else { return nil }
        let prefix = floor ? "≥$" : "$"
        return prefix + String(format: compact ? "%.1f" : "%.2f", usd)
    }

    /// Each value as a 0...1 fraction of the max; all-zero (or empty) → zeros.
    static func sparklineFractions(_ values: [Int]) -> [Double] {
        guard let mx = values.max(), mx > 0 else { return values.map { _ in 0 } }
        return values.map { Double($0) / Double(mx) }
    }
}

/// 7 thin bars, heights normalized to the max; the last bar (today) is brighter.
struct SparklineView: View {
    let values: [Int]
    var body: some View {
        let fractions = TodayConsumptionRow.sparklineFractions(values)
        GeometryReader { geo in
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(Array(fractions.enumerated()), id: \.offset) { idx, f in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.white.opacity(idx == fractions.count - 1 ? 0.8 : 0.35))
                        .frame(height: max(1, f * geo.size.height))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter TodayConsumptionRowTests 2>&1 | tail -15`
Expected: all 4 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/AppLib/Usage/TodayConsumptionRow.swift Tests/AppLibTests/TodayConsumptionRowTests.swift
git commit -m "feat(notch): add TodayConsumptionRow view + pure formatting helpers (#84)"
```

---

## Task B2: `Snapshot.hasConsumption` flag

**Files:**
- Modify: `Sources/AppLib/Usage/UsageTracker.swift` (`Snapshot`)
- Test: `Tests/AppLibTests/TodayConsumptionRowTests.swift` (append)

- [ ] **Step 1: Write the failing test (append inside `TodayConsumptionRowTests`)**

```swift
    @Test func hasConsumption() {
        let d = Date(timeIntervalSince1970: 0)
        var snap = UsageTracker.Snapshot.empty
        #expect(snap.hasConsumption == false)
        snap.dailyUsage = [DayUsage(dayStart: d, claudeTokens: 0, codexTokens: 0)]
        #expect(snap.hasConsumption == false)
        snap.dailyUsage = [DayUsage(dayStart: d, claudeTokens: 100, codexTokens: 0)]
        #expect(snap.hasConsumption == true)
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter "hasConsumption" 2>&1 | tail -15`
Expected: `value of type 'UsageTracker.Snapshot' has no member 'hasConsumption'`.

- [ ] **Step 3: Add the computed property** in `Sources/AppLib/Usage/UsageTracker.swift`, inside the `Snapshot` struct (e.g. right after the `hasRealData` computed property):

```swift
        /// True when any of the 7 daily buckets has nonzero consumption — drives
        /// whether the #84 Today row is shown at all (hidden on fresh installs).
        public var hasConsumption: Bool {
            dailyUsage.contains { $0.totalTokens > 0 }
        }
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter "hasConsumption" 2>&1 | tail -15`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/AppLib/Usage/UsageTracker.swift Tests/AppLibTests/TodayConsumptionRowTests.swift
git commit -m "feat(usage): add Snapshot.hasConsumption flag for Today-row visibility (#84)"
```

---

## Task B3: Embed Today row in the real-notch `UsageBarsView`

**Files:**
- Modify: `Sources/AppLib/Usage/UsageBarsView.swift`

No unit test (SwiftUI body); verified by build + Task B8 manual validation.

- [ ] **Step 1: Add the Today row + hairline to the body**

In `Sources/AppLib/Usage/UsageBarsView.swift`, the `body` is currently:

```swift
    var body: some View {
        let snap = usageTracker.snapshot
        VStack(spacing: 8) {
            usageBar(label: "5h", usedPct: snap.fiveHourUsedPct, resetsAt: snap.fiveHourResetsAt) {
                trailing
            }
            usageBar(label: "7d", usedPct: snap.sevenDayUsedPct, resetsAt: snap.sevenDayResetsAt) {
                EmptyView()
            }
        }
    }
```

Replace it with:

```swift
    var body: some View {
        let snap = usageTracker.snapshot
        VStack(spacing: 8) {
            usageBar(label: "5h", usedPct: snap.fiveHourUsedPct, resetsAt: snap.fiveHourResetsAt) {
                trailing
            }
            usageBar(label: "7d", usedPct: snap.sevenDayUsedPct, resetsAt: snap.sevenDayResetsAt) {
                EmptyView()
            }
            if snap.hasConsumption, let today = snap.dailyUsage.last {
                Rectangle()
                    .fill(Color.white.opacity(0.08))
                    .frame(height: 1)
                    .padding(.vertical, 2)
                TodayConsumptionRow(today: today, series: snap.dailyUsage.map(\.totalTokens))
            }
        }
    }
```

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build 2>&1 | tail -5`
Expected: Build complete.

- [ ] **Step 3: Run the full suite (no regression)**

Run: `swift test 2>&1 | tail -6`
Expected: all tests pass.

- [ ] **Step 4: Commit**

```bash
git add Sources/AppLib/Usage/UsageBarsView.swift
git commit -m "feat(notch): show Today row below 5h/7d in the real-notch header (#84)"
```

---

## Task B4: Embed Today row in the simulated-notch `usageHeader`

**Files:**
- Modify: `Sources/AppLib/SimulatedNotch/SimulatedNotchFullView.swift` (`usageHeader`)

No unit test; build + Task B8 validation.

- [ ] **Step 1: Add the Today row + hairline to `usageHeader`**

In `Sources/AppLib/SimulatedNotch/SimulatedNotchFullView.swift`, `usageHeader` ends with a `return VStack(spacing: 4) { ... }` containing the `if bothActive { … } else { … }` 5h/7d rows. Add the Today row as the last child of that `VStack`, after the `if bothActive { … } else { … }` block (still inside the `VStack`):

```swift
            if snap.hasConsumption, let today = snap.dailyUsage.last {
                Rectangle()
                    .fill(Color.white.opacity(0.08))
                    .frame(height: 1)
                    .padding(.top, 2)
                TodayConsumptionRow(today: today, series: snap.dailyUsage.map(\.totalTokens))
            }
```

(`snap` is the `let snap = usageTracker.snapshot` already bound at the top of `usageHeader`. The header sits inside a fixed-height panel with a scrolling session list below, so the new row consumes header space without any height recompute.)

- [ ] **Step 2: Build**

Run: `swift build 2>&1 | tail -5`
Expected: Build complete.

- [ ] **Step 3: Commit**

```bash
git add Sources/AppLib/SimulatedNotch/SimulatedNotchFullView.swift
git commit -m "feat(notch): show Today row in the simulated-notch header (#84)"
```

---

## Task B5: `ConfigStore.showTodayCostInPill` flag

**Files:**
- Modify: `Sources/AppLib/Config/ConfigStore.swift`
- Test: `Tests/AppLibTests/ConfigStoreTests.swift`

- [ ] **Step 1: Write the failing test (append inside `ConfigStoreTests`)**

```swift
    func testShowTodayCostInPillDefaultsFalse() {
        let store = ConfigStore(directory: tmpDir.path)
        XCTAssertFalse(store.loadShowTodayCostInPill())
    }

    func testShowTodayCostInPillRoundTrips() {
        let store = ConfigStore(directory: tmpDir.path)
        store.saveShowTodayCostInPill(true)
        XCTAssertTrue(store.loadShowTodayCostInPill())
        store.saveShowTodayCostInPill(false)
        XCTAssertFalse(store.loadShowTodayCostInPill())
    }

    func testSaveShowTodayCostInPillPreservesOtherKeys() {
        let store = ConfigStore(directory: tmpDir.path)
        store.saveCompactAgent(.codex)
        store.saveShowTodayCostInPill(true)
        XCTAssertEqual(store.loadCompactAgent(), .codex)   // not clobbered
        XCTAssertTrue(store.loadShowTodayCostInPill())
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter ConfigStoreTests 2>&1 | tail -15`
Expected: `value of type 'ConfigStore' has no member 'loadShowTodayCostInPill'`.

- [ ] **Step 3: Add the field to `ConfigWrapper`** at the end of the struct in `Sources/AppLib/Config/ConfigStore.swift`:

```swift
    var showTodayCostInPill: Bool?      // nil = false (default — #84 pill cost suffix off)
```

- [ ] **Step 4: Add load/save methods** (mirror `loadCompactAgent`/`saveCompactAgent`'s defensive pattern). Add to `ConfigStore`:

```swift
    /// Load whether the collapsed pill appends today's cost. Defaults to `false`.
    public func loadShowTodayCostInPill() -> Bool {
        guard let data = FileManager.default.contents(atPath: configPath),
              let wrapper = try? JSONDecoder().decode(ConfigWrapper.self, from: data) else {
            return false
        }
        return wrapper.showTodayCostInPill ?? false
    }

    /// Save the pill-cost preference. Same defensive contract as
    /// `saveCompactAgent` — bail rather than clobber a corrupt file.
    public func saveShowTodayCostInPill(_ enabled: Bool) {
        let fm = FileManager.default
        if !fm.fileExists(atPath: directory) {
            try? fm.createDirectory(atPath: directory, withIntermediateDirectories: true)
        }
        var wrapper: ConfigWrapper
        if fm.fileExists(atPath: configPath) {
            guard let data = fm.contents(atPath: configPath),
                  let existing = try? JSONDecoder().decode(ConfigWrapper.self, from: data) else {
                return  // corrupt file — don't clobber other fields
            }
            wrapper = existing
        } else {
            wrapper = ConfigWrapper(hotkey: .default)
        }
        wrapper.showTodayCostInPill = enabled
        guard let data = try? JSONEncoder().encode(wrapper) else { return }
        try? data.write(to: URL(fileURLWithPath: configPath), options: .atomic)
    }
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --filter ConfigStoreTests 2>&1 | tail -15`
Expected: all pass (incl. the 3 new ones).

- [ ] **Step 6: Commit**

```bash
git add Sources/AppLib/Config/ConfigStore.swift Tests/AppLibTests/ConfigStoreTests.swift
git commit -m "feat(config): add showTodayCostInPill flag (#84)"
```

---

## Task B6: Pill-cost toggle plumbing (store + controller seed + gear action)

**Files:**
- Modify: `Sources/AppLib/SimulatedNotch/SimulatedNotchRoot.swift` (`NotchModeStore`)
- Modify: `Sources/AppLib/SimulatedNotch/SimulatedNotchController.swift` (seed)
- Modify: `Sources/AppLib/SimulatedNotch/GearMenuTarget.swift` (action)
- Modify: `Sources/AppLib/SimulatedNotch/SimulatedNotchFullView.swift` (`popGearMenu` item)

No unit test (AppKit/SwiftUI glue); build + B8 validation.

- [ ] **Step 1: Add the published flag** to `NotchModeStore` in `SimulatedNotchRoot.swift`, after the `compactAgent` property:

```swift
    /// Whether the collapsed pill appends today's cost (#84). Persisted via
    /// `ConfigStore`; seeded by `SimulatedNotchController` at launch.
    @Published public var showTodayCostInPill: Bool = false
```

- [ ] **Step 2: Seed it at launch** in `SimulatedNotchController.swift`. Find the line `self.modeStore.compactAgent = ConfigStore().loadCompactAgent()` and add directly after it:

```swift
        self.modeStore.showTodayCostInPill = ConfigStore().loadShowTodayCostInPill()
```

- [ ] **Step 3: Add the gear action** to `GearMenuTarget.swift` (mirror `compactAgentClicked`):

```swift
    @objc func toggleTodayCostInPillClicked(_ sender: Any?) {
        modeStore?.isMenuOpen = false
        let next = !(modeStore?.showTodayCostInPill ?? false)
        ConfigStore().saveShowTodayCostInPill(next)
        modeStore?.showTodayCostInPill = next
        (sender as? NSMenuItem)?.state = next ? .on : .off
    }
```

- [ ] **Step 4: Add the menu item** in `SimulatedNotchFullView.popGearMenu`. Find the "Compact display" submenu block (it ends with `menu.addItem(compactItem)`). Immediately after `menu.addItem(compactItem)`, add:

```swift
        let pillCost = NSMenuItem(
            title: "Show today's cost in pill",
            action: #selector(GearMenuTarget.toggleTodayCostInPillClicked(_:)),
            keyEquivalent: ""
        )
        pillCost.target = GearMenuTarget.shared
        pillCost.state = ConfigStore().loadShowTodayCostInPill() ? .on : .off
        menu.addItem(pillCost)
```

- [ ] **Step 5: Build + full suite**

Run: `swift build 2>&1 | tail -5` → Build complete.
Run: `swift test 2>&1 | tail -6` → all pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/AppLib/SimulatedNotch/SimulatedNotchRoot.swift Sources/AppLib/SimulatedNotch/SimulatedNotchController.swift Sources/AppLib/SimulatedNotch/GearMenuTarget.swift Sources/AppLib/SimulatedNotch/SimulatedNotchFullView.swift
git commit -m "feat(notch): pill-cost toggle plumbing (config + store + gear menu) (#84)"
```

---

## Task B7: Append today's cost to the compact pill when toggled

**Files:**
- Modify: `Sources/AppLib/SimulatedNotch/SimulatedNotchView.swift` (`compactContent`)

No unit test; build + B8 validation (esp. width).

- [ ] **Step 1: Append the cost chip in `compactContent`**

In `Sources/AppLib/SimulatedNotch/SimulatedNotchView.swift`, `compactContent` currently ends after the 7d `percentageChip`. Append, as the last statements of the `@ViewBuilder var compactContent`:

```swift
        if modeStore.showTodayCostInPill,
           let today = snap.dailyUsage.last,
           let cost = TodayConsumptionRow.costString(
               TodayConsumptionRow.combinedCost(today), floor: today.anyUnpriced, compact: true) {
            Text("·")
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.3))
            Text(cost)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundColor(Color(red: 0.31, green: 0.80, blue: 0.77))
        }
```

(`snap` and `modeStore` are already in scope in `compactContent`. The pill is a fixed 220pt with slack; the compact `$N.N` format keeps the suffix short. Width is validated in B8 — if a realistic value clips, the fallback is to drop to a `$N` integer format here.)

- [ ] **Step 2: Build + full suite**

Run: `swift build 2>&1 | tail -5` → Build complete.
Run: `swift test 2>&1 | tail -6` → all pass.

- [ ] **Step 3: Commit**

```bash
git add Sources/AppLib/SimulatedNotch/SimulatedNotchView.swift
git commit -m "feat(notch): append today's cost to the pill when the toggle is on (#84)"
```

---

## Task B8: Docs + build/test/bundle + manual visual validation

**Files:**
- Modify: `ARCHITECTURE.md`

- [ ] **Step 1: Document the consumption axis** in `ARCHITECTURE.md`. In the "全局功能" module table, after the `UsageTracker` / `PricingStore` rows, add:

```markdown
| `TodayConsumptionRow` | `Sources/AppLib/Usage/TodayConsumptionRow.swift` | #84 消费轴：full-view header 的 "Today" 行（今日 token + $ + 近 7 日 sparkline + 每 agent 副行）。纯静态格式化助手（humanize/cost/sparkline）+ 只读视图；嵌入 `UsageBarsView`（真刘海）与 `SimulatedNotchFullView.usageHeader`（模拟）。可选齿轮开关把今日 $ 追加到 compact pill。|
```

- [ ] **Step 2: Full build + test + bundle**

Run:
```bash
swift build 2>&1 | tail -3
swift test 2>&1 | tail -6
make app 2>&1 | tail -2
```
Expected: build complete; all tests pass; app assembled.

- [ ] **Step 3: Manual visual validation (REQUIRED — codex review #9/#10)**

Run `make run` (or open `.build/ZackEyes.app`) and confirm with screenshots:
1. **Simulated full panel:** the "Today" row appears below the 5h/7d bars under a hairline; tokens humanized; sparkline shows 7 bars (rightmost brightest); per-agent subline present; nothing clips and the session list below still scrolls.
2. **Real notch (if on a notched Mac):** same row in the expanded header.
3. **Empty state:** with no transcripts today/this week, the Today row is hidden (no "Today 0").
4. **Pill toggle:** gear → "Show today's cost in pill" → the pill appends `· $N.N` without clipping or pushing content off the 220pt pill (try a realistic cost). Toggle off → pill returns to exactly `5h % · 7d %`.

Record the outcome (and, if the pill clips on a realistic value, switch the B7 format to `%.0f`/`$N` and re-validate before shipping).

- [ ] **Step 4: Commit**

```bash
git add ARCHITECTURE.md
git commit -m "docs: document TodayConsumptionRow / #84 consumption axis (#84)"
```

---

## Self-Review

**Spec coverage (UI items):**
- Shared `TodayConsumptionRow` (tokens + cost + sparkline + subline) → B1. ✅
- Token humanizer (1.4M/340K/1234), `≥` floor marker, combined cost → B1 helpers + tests. ✅
- Sparkline = daily total **tokens**, rightmost = today, normalized → B1 (`sparklineFractions`, `SparklineView`). ✅
- Per-agent split = **always-visible subline**, omit zero agent → B1 (`subline`). ✅
- Embedded in BOTH surfaces below 5h/7d with a hairline → B3 (real), B4 (simulated). ✅
- Hidden only when whole window empty (`hasConsumption`) → B2 + the `if snap.hasConsumption` gates. ✅
- Fixed-height panel ⇒ no height recompute, validated → B4 note + B8. ✅
- Pill toggle: ConfigStore flag (B5) + NotchModeStore + controller seed + GearMenuTarget + popGearMenu (B6) + compactContent append (B7), default off. ✅
- Pill width handling (compact format + validation; fallback documented) → B7 + B8. ✅
- ARCHITECTURE.md → B8. ✅

**Placeholder scan:** every code step has complete code; commands have expected output; the only "TODO-like" content is the B8 manual-validation checklist (intentional — it's a human step) and the documented B7 fallback (a contingency, not a gap).

**Type consistency:** `TodayConsumptionRow(today:series:)`, `humanizeTokens(_:)`, `costString(_:floor:compact:)`, `combinedCost(_:)`, `sparklineFractions(_:)`, `SparklineView(values:)`, `Snapshot.hasConsumption`, `DayUsage(dayStart:claudeTokens:codexTokens:claudeCostUSD:codexCostUSD:anyUnpriced:)`, `ConfigStore.loadShowTodayCostInPill()/saveShowTodayCostInPill(_:)`, `ConfigWrapper.showTodayCostInPill`, `NotchModeStore.showTodayCostInPill`, `GearMenuTarget.toggleTodayCostInPillClicked(_:)` — all used identically across tasks and match the Plan A / #82 / existing-code APIs (`DayUsage`, `Snapshot.dailyUsage`, `compactAgent` plumbing pattern).
