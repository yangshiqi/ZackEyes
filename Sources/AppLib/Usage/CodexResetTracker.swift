import Combine
import Foundation
import Shared

public enum CodexResetActivity {
    public static func hasActiveLocalCodex(_ sessions: [SessionInfo]) -> Bool {
        sessions.contains {
            $0.agent == .codex && $0.source.isLocal
                && ($0.state == .working || $0.state == .waiting)
        }
    }
}

/// Polls a public, unauthenticated announcement feed while local Codex is in
/// use. It does not read Codex auth/config or write to account quota state.
@MainActor
public final class CodexResetTracker: ObservableObject {
    @Published public private(set) var announcement: CodexResetAnnouncement?
    public var onNotify: ((CodexResetAnnouncement) -> Void)?
    public var onChange: ((CodexResetAnnouncement?) -> Void)?

    private let config: ConfigStore
    private let defaults: UserDefaults
    private let now: () -> Date
    private let fetch: @MainActor () async throws -> Data
    private var pollingTask: Task<Void, Never>?
    private var lastAttempt: Date?
    private var inFlight = false
    private var activeCodex = false
    private var generation = 0
    // V1 also stored notices suppressed on first fetch, so those keys were
    // never evidence that a notification actually appeared.
    private static let notifiedKey = "codexResetNotifiedAnnouncementsV2"

    public init(
        config: ConfigStore = ConfigStore(),
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init,
        fetch: (@MainActor () async throws -> Data)? = nil
    ) {
        self.config = config
        self.defaults = defaults
        self.now = now
        self.fetch = fetch ?? { try await Self.fetchDefault() }
    }

    public func start(activeCodex: @escaping @MainActor () -> Bool) {
        pollingTask?.cancel()
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh(activeCodex: activeCodex())
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    private static let localRecoveryKey = "codexResetLocalRecoveryAtV1"
    private var quotaReadings: [String: CodexQuotaReading] = [:]

    /// Called only with account-level observations from the local rollout scan.
    /// Never infer recovery from missing data, cached display state or scope swaps.
    public func recordQuotaReadings(_ readings: [CodexQuotaReading]) {
        let current = now()
        let savedRecovery = defaults.object(forKey: Self.localRecoveryKey) as? Date
        var recovery = savedRecovery
        if let saved = recovery, saved > current { recovery = nil }
        for reading in readings {
            guard reading.observedAt <= current,
                  current.timeIntervalSince(reading.observedAt) <= CodexQuotaRecovery.freshness else { continue }
            if let detected = reading.recoveredAt, detected <= reading.observedAt,
               current.timeIntervalSince(detected) <= 24 * 3600 {
                recovery = max(recovery ?? .distantPast, detected)
            }
            if let previous = quotaReadings[reading.sourceID] {
                guard reading.observedAt > previous.observedAt else { continue }
                if CodexQuotaRecovery.occurred(from: previous, to: reading) {
                    recovery = max(recovery ?? .distantPast, reading.observedAt)
                }
            }
            quotaReadings[reading.sourceID] = reading
        }
        quotaReadings = Dictionary(uniqueKeysWithValues: quotaReadings.values
            .filter { current.timeIntervalSince($0.observedAt) <= CodexQuotaRecovery.freshness }
            .sorted { $0.observedAt > $1.observedAt }.prefix(128).map { ($0.sourceID, $0) })
        if let recovery {
            if recovery != savedRecovery { defaults.set(recovery, forKey: Self.localRecoveryKey) }
            setAnnouncement(announcement)
        }
    }

    public func stop() {
        pollingTask?.cancel()
        pollingTask = nil
        generation += 1
        activeCodex = false
        setAnnouncement(nil)
    }

    /// Call on activity/settings transitions as well as from the minute tick.
    /// The five-minute attempt gate prevents those extra calls from polling.
    public func refresh(activeCodex: Bool) async {
        self.activeCodex = activeCodex
        guard activeCodex, config.loadCodexResetAnnouncements() else {
            generation += 1
            setAnnouncement(nil)
            return
        }
        let current = now()
        if let announcement, current.timeIntervalSince(announcement.providerUpdatedAt) > 6 * 3600 {
            setAnnouncement(nil)
        }
        guard !inFlight,
              lastAttempt.map({ current.timeIntervalSince($0) >= 5 * 60 }) ?? true else { return }
        inFlight = true
        lastAttempt = current
        let requestGeneration = generation
        defer { inFlight = false }
        do {
            let data = try await fetch()
            guard generation == requestGeneration, self.activeCodex,
                  config.loadCodexResetAnnouncements() else { return }
            let notice = visibleAnnouncement(CodexResetFeed.latest(from: data, now: now()))
            setAnnouncement(notice)
            guard let notice else { return }
            let key = notice.notificationKey(at: now())
            let previous = defaults.stringArray(forKey: Self.notifiedKey) ?? []
            if CodexResetAlertPolicy.shouldNotify(
                notice, activeCodex: self.activeCodex, enabled: true,
                notificationsEnabled: config.loadCodexResetNotifications(),
                lastKey: previous.contains(key) ? key : nil, now: now()
            ), let onNotify {
                onNotify(notice)
                defaults.set(Array((previous + [key]).suffix(100)), forKey: Self.notifiedKey)
            }
        } catch {
            // Keep a still-fresh notice through transient network failures.
            // No logging of response bodies or account/session information.
            if let announcement, now().timeIntervalSince(announcement.providerUpdatedAt) > 6 * 3600 {
                setAnnouncement(nil)
            }
        }
    }

    private func visibleAnnouncement(_ notice: CodexResetAnnouncement?) -> CodexResetAnnouncement? {
        guard let notice, notice.kind == .automatic,
              let recovery = defaults.object(forKey: Self.localRecoveryKey) as? Date,
              recovery <= now(), notice.announcedAt <= recovery else { return notice }
        return nil
    }

    private func setAnnouncement(_ notice: CodexResetAnnouncement?) {
        let notice = visibleAnnouncement(notice)
        guard announcement != notice else { return }
        announcement = notice
        onChange?(notice)
    }

    private nonisolated static func fetchDefault() async throws -> Data {
        var request = URLRequest(url: URL(string: "https://codexreset.ai/api/v1/resets.json")!)
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        defer { bytes.task.cancel() }
        let limit = 512 * 1024
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              response.expectedContentLength <= Int64(limit) else {
            throw URLError(.badServerResponse)
        }
        var data = Data()
        data.reserveCapacity(Int(min(max(response.expectedContentLength, 0), Int64(limit))))
        for try await byte in bytes {
            guard data.count < limit else { throw URLError(.dataLengthExceedsMaximum) }
            data.append(byte)
        }
        return data
    }
}
