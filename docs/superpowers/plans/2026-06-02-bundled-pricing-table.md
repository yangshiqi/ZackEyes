# Bundled Pricing Table Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a zero-dependency `price(for: model) → ModelPrice?` lookup service (issue #82) so #84 can later turn token counts into USD.

**Architecture:** A pure, testable `PricingTable` (parse + lookup) wrapped by a `@MainActor PricingStore` that version-gates a bundled snapshot against a disk cache and a 24h remote refresh. All Bundle/network/disk seams are injected so the store is unit-testable. No UI.

**Tech Stack:** Swift 6 (strict concurrency), Foundation only (`JSONDecoder`, `URLSession`, `Timer`), `Testing` framework for tests, Makefile-assembled `.app` bundle.

**Spec:** `docs/superpowers/specs/2026-06-02-bundled-pricing-table-design.md`

---

## File Structure

| File | Responsibility |
|------|----------------|
| `Sources/AppLib/Usage/ModelPrice.swift` | Value type: four per-token USD prices. No logic. |
| `Sources/AppLib/Usage/PricingTable.swift` | Pure parse of `pricing.json` + `price(for:)` lookup (exact → date-strip → alias → nil). Owns `version`. |
| `Sources/AppLib/Usage/PricingStore.swift` | `@MainActor` shell: version-gated load (cache vs bundled), monotonic 24h refresh, injected seams. |
| `Resources/pricing.json` | Curated, trimmed price snapshot (the models we actually see). |
| `Makefile` | Copy `pricing.json` into the bundle in both `app` and `app-release`. |
| `Sources/ZackEyes/AppDelegate.swift` | Construct + `start()`/`stop()` the store. |
| `Tests/AppLibTests/PricingTableTests.swift` | Parse / lookup / contract / bundled-resource validity. |
| `Tests/AppLibTests/PricingStoreTests.swift` | Version-gated load + monotonic refresh via injected seams. |
| `ARCHITECTURE.md` | Document the new module + data flow. |

All Swift source lives in `Sources/AppLib/Usage/` next to `UsageTracker`, since pricing is part of the usage subsystem.

---

## Task 1: `ModelPrice` + `PricingTable` (parse + lookup)

**Files:**
- Create: `Sources/AppLib/Usage/ModelPrice.swift`
- Create: `Sources/AppLib/Usage/PricingTable.swift`
- Test: `Tests/AppLibTests/PricingTableTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/AppLibTests/PricingTableTests.swift`:

```swift
import Testing
import Foundation
@testable import AppLib

struct PricingTableTests {
    static let json = """
    {
      "version": "2026-06-02",
      "models": {
        "claude-opus-4-8":  { "input": 1.5e-5, "output": 7.5e-5, "cache_read": 1.5e-6, "cache_creation": 1.875e-5 },
        "claude-haiku-4-5": { "input": 1.0e-6, "output": 5.0e-6, "cache_read": 1.0e-7, "cache_creation": 1.25e-6 },
        "gpt-5.5":          { "input": 1.25e-6, "output": 1.0e-5, "cache_read": 1.25e-7, "cache_creation": 0 }
      },
      "aliases": { "claude-opus-latest": "claude-opus-4-8" }
    }
    """.data(using: .utf8)!

    @Test func parsesVersionAndExactLookup() throws {
        let t = try PricingTable(data: Self.json)
        #expect(t.version == "2026-06-02")
        let p = t.price(for: "claude-opus-4-8")
        #expect(p?.inputPerToken == 1.5e-5)
        #expect(p?.outputPerToken == 7.5e-5)
        #expect(p?.cacheReadPerToken == 1.5e-6)
        #expect(p?.cacheCreatePerToken == 1.875e-5)
    }

    @Test func dateSuffixStripped() throws {
        let t = try PricingTable(data: Self.json)
        #expect(t.price(for: "claude-haiku-4-5-20251001")?.inputPerToken == 1.0e-6)
    }

    @Test func aliasLookup() throws {
        let t = try PricingTable(data: Self.json)
        #expect(t.price(for: "claude-opus-latest")?.inputPerToken == 1.5e-5)
    }

    @Test func missingModelIsNil() throws {
        let t = try PricingTable(data: Self.json)
        #expect(t.price(for: "totally-unknown-model") == nil)
    }

    @Test func displayNameIsNil() throws {
        // Model-ID contract: display names must NOT resolve to a price.
        let t = try PricingTable(data: Self.json)
        #expect(t.price(for: "Opus 4.8") == nil)
    }

    @Test func nonDateTrailingNotStripped() throws {
        // "claude-opus-4-8" must not be mangled by the date-suffix stripper.
        let t = try PricingTable(data: Self.json)
        #expect(t.price(for: "claude-opus-4-8")?.inputPerToken == 1.5e-5)
    }

    @Test func malformedThrows() {
        #expect(throws: (any Error).self) {
            _ = try PricingTable(data: Data("{not json".utf8))
        }
    }

    @Test func emptyModelsParses() throws {
        let t = try PricingTable(data: Data(#"{"models":{}}"#.utf8))
        #expect(t.version == "")
        #expect(t.price(for: "claude-opus-4-8") == nil)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails (does not compile)**

Run: `swift test --filter PricingTableTests 2>&1 | tail -15`
Expected: build failure — `cannot find 'PricingTable' in scope` / `cannot find 'ModelPrice'`.

- [ ] **Step 3: Create `ModelPrice`**

Create `Sources/AppLib/Usage/ModelPrice.swift`:

```swift
import Foundation

/// Per-token USD unit prices for one model (LiteLLM convention, e.g. `1.5e-5`).
/// `cacheCreatePerToken` is 0 for providers (Codex) with no cache-creation cost.
public struct ModelPrice: Sendable, Equatable, Codable {
    public let inputPerToken: Double
    public let outputPerToken: Double
    public let cacheReadPerToken: Double
    public let cacheCreatePerToken: Double

    public init(inputPerToken: Double, outputPerToken: Double,
                cacheReadPerToken: Double, cacheCreatePerToken: Double) {
        self.inputPerToken = inputPerToken
        self.outputPerToken = outputPerToken
        self.cacheReadPerToken = cacheReadPerToken
        self.cacheCreatePerToken = cacheCreatePerToken
    }
}
```

- [ ] **Step 4: Create `PricingTable`**

Create `Sources/AppLib/Usage/PricingTable.swift`:

```swift
import Foundation

/// Pure model→price lookup parsed from a curated `pricing.json`.
/// No Bundle, no network — fully unit-testable with inline `Data`.
public struct PricingTable: Sendable {
    /// `pricing.json` `version` (ISO date string); "" if absent. Used by
    /// `PricingStore` for monotonic version-gated selection.
    public let version: String
    private let models: [String: ModelPrice]
    private let aliases: [String: String]

    /// Empty table — every lookup returns nil; version sorts lowest.
    public static let empty = PricingTable(version: "", models: [:], aliases: [:])

    init(version: String, models: [String: ModelPrice], aliases: [String: String]) {
        self.version = version
        self.models = models
        self.aliases = aliases
    }

    /// Parse a curated pricing.json. Throws on malformed JSON so callers can
    /// keep a previously-loaded table instead of swapping in garbage.
    public init(data: Data) throws {
        let dto = try JSONDecoder().decode(PricingFile.self, from: data)
        self.version = dto.version ?? ""
        self.models = dto.models.mapValues {
            ModelPrice(inputPerToken: $0.input, outputPerToken: $0.output,
                       cacheReadPerToken: $0.cache_read, cacheCreatePerToken: $0.cache_creation)
        }
        self.aliases = dto.aliases ?? [:]
    }

    /// Look up by RAW provider model id (e.g. "claude-opus-4-8", "gpt-5.5").
    /// Display names are not valid keys and return nil.
    /// Order: exact → date-suffix-stripped → alias → nil.
    public func price(for model: String) -> ModelPrice? {
        if let p = models[model] { return p }
        let stripped = Self.stripDateSuffix(model)
        if stripped != model, let p = models[stripped] { return p }
        if let canonical = aliases[model], let p = models[canonical] { return p }
        return nil
    }

    /// Drop a trailing `-YYYY-MM-DD` or `-YYYYMMDD` date stamp if present.
    static func stripDateSuffix(_ model: String) -> String {
        if let r = model.range(of: "-[0-9]{4}-[0-9]{2}-[0-9]{2}$", options: .regularExpression) {
            return String(model[..<r.lowerBound])
        }
        if let r = model.range(of: "-[0-9]{8}$", options: .regularExpression) {
            return String(model[..<r.lowerBound])
        }
        return model
    }
}

/// Wire format for `pricing.json`. Private — only `PricingTable` decodes it.
private struct PricingFile: Decodable {
    let version: String?
    let models: [String: Entry]
    let aliases: [String: String]?
    struct Entry: Decodable {
        let input: Double
        let output: Double
        let cache_read: Double
        let cache_creation: Double
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --filter PricingTableTests 2>&1 | tail -15`
Expected: all 8 tests pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/AppLib/Usage/ModelPrice.swift Sources/AppLib/Usage/PricingTable.swift Tests/AppLibTests/PricingTableTests.swift
git commit -m "feat(usage): add ModelPrice + pure PricingTable lookup (#82)"
```

---

## Task 2: Curated `pricing.json` + Makefile bundling

**Files:**
- Create: `Resources/pricing.json`
- Modify: `Makefile:21-22` (the `app` target, after the `*.mp3` copy) and `Makefile:34-35` (the `app-release` target, after the `*.mp3` copy)
- Test: `Tests/AppLibTests/PricingTableTests.swift` (append one test)

- [ ] **Step 1: Write the failing test (append to `PricingTableTests.swift`)**

Add this method inside `struct PricingTableTests`:

```swift
    @Test func bundledResourceFileParsesAndHasCoreModels() throws {
        // Locate Resources/pricing.json relative to this test file (repo root
        // is three dirs up from Tests/AppLibTests/).
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // AppLibTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
        let url = repoRoot.appendingPathComponent("Resources/pricing.json")
        let data = try Data(contentsOf: url)
        let table = try PricingTable(data: data)
        #expect(!table.version.isEmpty)
        #expect(table.price(for: "claude-opus-4-8") != nil)
        #expect(table.price(for: "gpt-5.5") != nil)
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter bundledResourceFileParsesAndHasCoreModels 2>&1 | tail -15`
Expected: FAIL — `Data(contentsOf:)` throws because `Resources/pricing.json` does not exist yet.

- [ ] **Step 3: Create `Resources/pricing.json`**

Create `Resources/pricing.json`. Per-token USD values below are derived from published list prices (Claude: cache-read = 0.1× input, cache-write = 1.25× input). **Verify against current official/LiteLLM pricing before the next release and bump `version` on any change.**

```json
{
  "version": "2026-06-02",
  "models": {
    "claude-opus-4-8":   { "input": 1.5e-5, "output": 7.5e-5, "cache_read": 1.5e-6,  "cache_creation": 1.875e-5 },
    "claude-sonnet-4-6": { "input": 3.0e-6, "output": 1.5e-5, "cache_read": 3.0e-7,  "cache_creation": 3.75e-6 },
    "claude-haiku-4-5":  { "input": 1.0e-6, "output": 5.0e-6, "cache_read": 1.0e-7,  "cache_creation": 1.25e-6 },
    "gpt-5.5":           { "input": 1.25e-6, "output": 1.0e-5, "cache_read": 1.25e-7, "cache_creation": 0 },
    "gpt-5-codex":       { "input": 1.25e-6, "output": 1.0e-5, "cache_read": 1.25e-7, "cache_creation": 0 }
  },
  "aliases": {}
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter bundledResourceFileParsesAndHasCoreModels 2>&1 | tail -15`
Expected: PASS.

- [ ] **Step 5: Add the bundle copy to BOTH Makefile targets**

In `Makefile`, in the `app:` target, immediately after the line `cp Resources/*.mp3 $(RESOURCES)/` (currently `Makefile:22`), add:

```makefile
	cp Resources/pricing.json $(RESOURCES)/
```

Then do the **same** in the `app-release:` target, immediately after its own `cp Resources/*.mp3 $(RESOURCES)/` line (currently `Makefile:35`):

```makefile
	cp Resources/pricing.json $(RESOURCES)/
```

(Both blocks are separate — missing either ships a build with no bundled table.)

- [ ] **Step 6: Verify the bundle includes the file**

Run: `make app 2>&1 | tail -3 && ls .build/ZackEyes.app/Contents/Resources/pricing.json`
Expected: the `ls` prints the path (file exists in the assembled bundle).

- [ ] **Step 7: Commit**

```bash
git add Resources/pricing.json Makefile Tests/AppLibTests/PricingTableTests.swift
git commit -m "feat(usage): bundle curated pricing.json into the app (#82)"
```

---

## Task 3: `PricingStore` (version-gated load + monotonic refresh)

**Files:**
- Create: `Sources/AppLib/Usage/PricingStore.swift`
- Test: `Tests/AppLibTests/PricingStoreTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/AppLibTests/PricingStoreTests.swift`:

```swift
import Testing
import Foundation
@testable import AppLib

@MainActor
struct PricingStoreTests {
    private static func tmpCacheURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("pricing-cache.json")
    }

    private static func json(version: String, opusInput: Double) -> Data {
        """
        {"version":"\(version)","models":{"claude-opus-4-8":{"input":\(opusInput),"output":1,"cache_read":1,"cache_creation":1}}}
        """.data(using: .utf8)!
    }

    @Test func loadPrefersHigherVersionCacheOverBundled() throws {
        let cache = Self.tmpCacheURL()
        try FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.json(version: "2026-06-02", opusInput: 2e-5).write(to: cache)
        let store = PricingStore(
            cacheURL: cache,
            bundledData: { Self.json(version: "2026-01-01", opusInput: 9e-9) },
            fetch: { nil }
        )
        store.loadInitial()
        #expect(store.price(for: "claude-opus-4-8")?.inputPerToken == 2e-5)
    }

    @Test func loadPrefersHigherVersionBundledAfterUpdate() throws {
        let cache = Self.tmpCacheURL()
        try FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.json(version: "2026-01-01", opusInput: 9e-9).write(to: cache)
        let store = PricingStore(
            cacheURL: cache,
            bundledData: { Self.json(version: "2026-06-02", opusInput: 2e-5) },
            fetch: { nil }
        )
        store.loadInitial()
        #expect(store.price(for: "claude-opus-4-8")?.inputPerToken == 2e-5)
    }

    @Test func corruptCacheFallsBackToBundled() throws {
        let cache = Self.tmpCacheURL()
        try FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("garbage".utf8).write(to: cache)
        let store = PricingStore(
            cacheURL: cache,
            bundledData: { Self.json(version: "2026-06-02", opusInput: 2e-5) },
            fetch: { nil }
        )
        store.loadInitial()
        #expect(store.price(for: "claude-opus-4-8")?.inputPerToken == 2e-5)
    }

    @Test func missingBothGivesEmptyTable() {
        let store = PricingStore(cacheURL: Self.tmpCacheURL(), bundledData: { nil }, fetch: { nil })
        store.loadInitial()
        #expect(store.price(for: "claude-opus-4-8") == nil)
    }

    @Test func refreshSwapsOnNewerVersionAndWritesCache() async {
        let cache = Self.tmpCacheURL()
        let store = PricingStore(
            cacheURL: cache,
            bundledData: { Self.json(version: "2026-01-01", opusInput: 1e-9) },
            fetch: { Self.json(version: "2026-06-02", opusInput: 2e-5) }
        )
        store.loadInitial()
        await store.refresh()
        #expect(store.price(for: "claude-opus-4-8")?.inputPerToken == 2e-5)
        #expect(FileManager.default.fileExists(atPath: cache.path))
    }

    @Test func refreshIgnoresOlderVersion() async {
        let store = PricingStore(
            cacheURL: Self.tmpCacheURL(),
            bundledData: { Self.json(version: "2026-06-02", opusInput: 2e-5) },
            fetch: { Self.json(version: "2025-01-01", opusInput: 9e-9) }
        )
        store.loadInitial()
        await store.refresh()
        #expect(store.price(for: "claude-opus-4-8")?.inputPerToken == 2e-5)
    }

    @Test func refreshIgnoresNilFetch() async {
        let store = PricingStore(
            cacheURL: Self.tmpCacheURL(),
            bundledData: { Self.json(version: "2026-06-02", opusInput: 2e-5) },
            fetch: { nil }
        )
        store.loadInitial()
        await store.refresh()
        #expect(store.price(for: "claude-opus-4-8")?.inputPerToken == 2e-5)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails (does not compile)**

Run: `swift test --filter PricingStoreTests 2>&1 | tail -15`
Expected: build failure — `cannot find 'PricingStore' in scope`.

- [ ] **Step 3: Create `PricingStore`**

Create `Sources/AppLib/Usage/PricingStore.swift`:

```swift
import Foundation

/// Serves `price(for:)` from the highest-version pricing snapshot available.
///
/// Borrows the timer + silent-`URLSession`-failure shape from `UpdateChecker`,
/// and the atomic-write + defensive-read shape from `ConfigStore`/`UsageTracker`.
/// All external seams (cache path, bundled bytes, network fetch) are injected so
/// the store is fully unit-testable with no real network and no writes to the
/// real `~/.zackeyes`.
@MainActor
public final class PricingStore: ObservableObject {
    @Published public private(set) var table: PricingTable = .empty

    public func price(for model: String) -> ModelPrice? { table.price(for: model) }

    private let checkInterval: TimeInterval
    private let cacheURL: URL
    private let bundledData: @Sendable () -> Data?
    private let fetch: @Sendable () async -> Data?
    private var timer: Timer?

    public init(
        checkInterval: TimeInterval = 24 * 3600,
        cacheURL: URL = URL(fileURLWithPath: NSHomeDirectory() + "/.zackeyes/pricing-cache.json"),
        bundledData: @escaping @Sendable () -> Data? = { PricingStore.loadBundled() },
        fetch: @escaping @Sendable () async -> Data? = { await PricingStore.defaultFetch() }
    ) {
        self.checkInterval = checkInterval
        self.cacheURL = cacheURL
        self.bundledData = bundledData
        self.fetch = fetch
    }

    public func start() {
        loadInitial()
        Task { await refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: checkInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.refresh() }
        }
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Version-gated initial load: keep the higher-`version` table that parses.
    func loadInitial() {
        let cache = (try? Data(contentsOf: cacheURL)).flatMap { try? PricingTable(data: $0) }
        let bundled = bundledData().flatMap { try? PricingTable(data: $0) }
        switch (cache, bundled) {
        case let (c?, b?): table = c.version >= b.version ? c : b
        case let (c?, nil): table = c
        case let (nil, b?): table = b
        case (nil, nil):    table = .empty
        }
    }

    /// Monotonic refresh: replace only on a strictly newer `version`.
    func refresh() async {
        guard let data = await fetch(),
              let fetched = try? PricingTable(data: data),
              fetched.version > table.version else { return }
        try? FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: cacheURL, options: .atomic)
        table = fetched
    }

    // MARK: - Default seams (replaced in tests)

    private nonisolated static let remoteURL = URL(string:
        "https://raw.githubusercontent.com/yangshiqi/ZackEyes-release/main/pricing.json")!

    nonisolated static func loadBundled() -> Data? {
        guard let url = Bundle.main.url(forResource: "pricing", withExtension: "json") else { return nil }
        return try? Data(contentsOf: url)
    }

    nonisolated static func defaultFetch() async -> Data? {
        var request = URLRequest(url: remoteURL)
        request.timeoutInterval = 15
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        return data
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter PricingStoreTests 2>&1 | tail -15`
Expected: all 7 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/AppLib/Usage/PricingStore.swift Tests/AppLibTests/PricingStoreTests.swift
git commit -m "feat(usage): add PricingStore with version-gated load + monotonic refresh (#82)"
```

---

## Task 4: Wire `PricingStore` into `AppDelegate`

**Files:**
- Modify: `Sources/ZackEyes/AppDelegate.swift` (property near `:15`, construct+start near `:82`, stop near `:438`)

There is no unit test for app glue; correctness is verified by a clean build + the full suite still passing.

- [ ] **Step 1: Add the stored property**

In `Sources/ZackEyes/AppDelegate.swift`, after the line `private var updateDownloader: UpdateDownloader?` (currently `:16`), add:

```swift
    private var pricingStore: PricingStore?
```

- [ ] **Step 2: Construct + start it**

In the same file, immediately after the usage-tracker start block — the line `usageTracker.start(intervalSeconds: 30)` (currently `:82`) — add:

```swift

        // 3.6 Pricing table (model→$ snapshot; bundled + 24h remote refresh).
        // Consumed by token-cost features; safe no-op until then.
        let ps = PricingStore()
        pricingStore = ps
        ps.start()
```

- [ ] **Step 3: Stop it on teardown**

In the same file, find the teardown that calls `updateChecker?.stop()` (currently `:438`) and add directly after it:

```swift
        pricingStore?.stop()
```

- [ ] **Step 4: Build to verify it compiles**

Run: `swift build 2>&1 | tail -5`
Expected: `Compiling`/`Build complete!` with no errors.

- [ ] **Step 5: Run the full test suite**

Run: `swift test 2>&1 | tail -20`
Expected: all tests pass (SharedTests + BridgeLibTests + AppLibTests), including the new Pricing tests.

- [ ] **Step 6: Commit**

```bash
git add Sources/ZackEyes/AppDelegate.swift
git commit -m "feat(app): start PricingStore at launch (#82)"
```

---

## Task 5: Document + final verification

**Files:**
- Modify: `ARCHITECTURE.md` (module table under "全局功能", + a pricing note)

- [ ] **Step 1: Add `PricingStore` to the module table**

In `ARCHITECTURE.md`, in the "全局功能" module table, after the `UsageTracker` row, add:

```markdown
| `PricingStore` / `PricingTable` | `Sources/AppLib/Usage/PricingStore.swift`、`PricingTable.swift` | 模型→单价查询（`price(for:)`）。`PricingTable` 纯解析+查找（exact→去日期后缀→alias→nil，仅接受原始 model id）；`PricingStore` 按 `version` 在 bundled 快照 / 磁盘缓存 / 24h 远端拉取间择新，失败静默。无 UI。 |
```

- [ ] **Step 2: Add a one-line data-flow note**

In `ARCHITECTURE.md`, append to the end of the "核心数据流" section:

```markdown
### Pricing 数据流

```
PricingStore.start()
  → loadInitial(): max(version) of {bundled pricing.json, ~/.zackeyes/pricing-cache.json}
  → 24h Timer + 即刻一次: URLSession GET raw pricing.json
        → version 严格更新才 atomic 写缓存 + swap table；否则静默保持
消费方（后续 #84）: pricingStore.price(for: rawModelID) → ModelPrice?
```
```

- [ ] **Step 3: Full build + test + bundle verification**

Run: `swift build 2>&1 | tail -3 && swift test 2>&1 | tail -10 && make app 2>&1 | tail -2 && ls .build/ZackEyes.app/Contents/Resources/pricing.json`
Expected: build complete, all tests pass, app assembled, and `pricing.json` present in the bundle.

- [ ] **Step 4: Commit**

```bash
git add ARCHITECTURE.md
git commit -m "docs: document PricingStore/PricingTable module + data flow (#82)"
```

---

## Self-Review

**Spec coverage:**
- `ModelPrice` (4 prices) → Task 1. ✅
- Pure `PricingTable` parse + lookup (exact/date-strip/alias/nil) → Task 1. ✅
- Model-ID contract (display name → nil) → Task 1 (`displayNameIsNil` test). ✅
- Curated trimmed `pricing.json` + Makefile both blocks → Task 2. ✅
- `PricingStore` version-gated load + monotonic refresh + injected seams → Task 3. ✅
- Concurrency (`@MainActor`, `nonisolated` static seams, `await` off-main) → Task 3 code. ✅
- AppDelegate wiring (start/stop) → Task 4. ✅
- Tests for parse/lookup/contract/version-gating/refresh → Tasks 1 & 3. ✅
- ARCHITECTURE.md update → Task 5. ✅

**Placeholder scan:** `pricing.json` values are concrete published list prices with an explicit "verify + bump version before release" instruction (not a TODO). No "TBD"/"handle edge cases"/"similar to" placeholders. All code steps show full code.

**Type consistency:** `PricingTable(data:)`, `price(for:)`, `version`, `.empty`, `ModelPrice(inputPerToken:outputPerToken:cacheReadPerToken:cacheCreatePerToken:)`, and `PricingStore(checkInterval:cacheURL:bundledData:fetch:)` / `loadInitial()` / `refresh()` / `start()` / `stop()` / `price(for:)` are used identically in implementation and tests. JSON field names (`input`/`output`/`cache_read`/`cache_creation`/`version`/`models`/`aliases`) match the `PricingFile` DTO and the curated file.
