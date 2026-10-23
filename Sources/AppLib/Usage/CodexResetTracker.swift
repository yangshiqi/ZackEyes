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
    private var hasFetched = false
    private var generation = 0
    private static let notifiedKey = "codexResetNotifiedAnnouncementsV1"

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
            let notice = CodexResetFeed.latest(from: data, now: now())
            setAnnouncement(notice)
            let isFirstFetch = !hasFetched
            hasFetched = true
            guard let notice else { return }
            let key = notice.notificationKey(at: now())
            let previous = defaults.stringArray(forKey: Self.notifiedKey) ?? []
            if isFirstFetch && notice.phase != .scheduled {
                if !previous.contains(key) {
                    defaults.set(Array((previous + [key]).suffix(100)), forKey: Self.notifiedKey)
                }
                return
            }
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

    private func setAnnouncement(_ notice: CodexResetAnnouncement?) {
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
