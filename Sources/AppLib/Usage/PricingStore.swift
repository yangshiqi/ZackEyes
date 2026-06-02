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
        // In-memory table always wins; persisting to the cache is best-effort
        // (a write failure just means next launch falls back to bundled).
        table = fetched
        try? FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: cacheURL, options: .atomic)
    }

    // MARK: - Default seams (replaced in tests)

    private nonisolated static let remoteURL = URL(string:
        "https://raw.githubusercontent.com/yangshiqi/ZackEyes-release/main/pricing.json")!

    public nonisolated static func loadBundled() -> Data? {
        guard let url = Bundle.main.url(forResource: "pricing", withExtension: "json") else { return nil }
        return try? Data(contentsOf: url)
    }

    public nonisolated static func defaultFetch() async -> Data? {
        var request = URLRequest(url: remoteURL)
        request.timeoutInterval = 15
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        return data
    }
}
