import Foundation
import RemoteCore

public struct RemoteHostStatus: Identifiable, Equatable, Sendable {
    public enum Phase: String, Sendable { case disabled, connecting, connected, failed }
    public var host: RemoteHost
    public var phase: Phase
    public var message: String?
    public var sessionCount: Int
    public var id: UUID { host.id }
    public var keepsVisible: Bool { host.enabled && (phase == .connecting || phase == .failed || sessionCount > 0) }
    public init(host: RemoteHost, phase: Phase, message: String? = nil, sessionCount: Int = 0) {
        self.host = host
        self.phase = phase
        self.message = message
        self.sessionCount = sessionCount
    }
    public var label: String {
        switch phase {
        case .disabled: return "Disabled"
        case .connecting: return "Connecting…"
        case .connected: return "\(sessionCount) observed"
        case .failed: return message ?? "Disconnected"
        }
    }
}

@MainActor public final class RemoteHostManager: ObservableObject {
    public typealias Connector = @Sendable (RemoteHost) throws -> RemoteConnection
    @Published public private(set) var statuses: [RemoteHostStatus] = []
    @Published public private(set) var configurationError: String?
    public var onChange: (() -> Void)?
    private let sessionStore: SessionStore
    private let store: RemoteHostStore
    private let connect: Connector
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private var hosts: [RemoteHost] = []
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var generations: [UUID: UUID] = [:]
    private var running = false
    public init(
        sessionStore: SessionStore, store: RemoteHostStore = RemoteHostStore(),
        connect: @escaping Connector = { try RemoteSSHTransport().connect($0) },
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    ) {
        self.sessionStore = sessionStore
        self.store = store
        self.connect = connect
        self.sleep = sleep
        do { hosts = try store.load() } catch {
            configurationError = "Could not load remote hosts. Existing file was preserved."
        }
        statuses = hosts.map { RemoteHostStatus(host: $0, phase: .disabled) }
    }
    public func start() {
        guard !running else { return }
        running = true
        for host in hosts { restart(host) }
    }
    public func stop() {
        running = false
        for task in tasks.values { task.cancel() }
        generations.removeAll()
        for host in hosts { sessionStore.removeRemoteSessions(hostID: host.id) }
        statuses = hosts.map { RemoteHostStatus(host: $0, phase: .disabled) }
        onChange?()
    }
    /// Used by NSApplication's deferred termination path. Keep the app alive
    /// until cancellation has reaped every owned SSH process, including the
    /// bounded SIGKILL fallback for children that ignore TERM.
    public func shutdown() async {
        stop()
        let pending = Array(tasks.values)
        for task in pending { await task.value }
    }
    public func saveHost(_ host: RemoteHost) throws {
        // A failed load must never turn an unrelated edit into overwriting the
        // user's unreadable/unsupported document. Repair it externally first.
        guard configurationError == nil else { throw RemoteHostError.invalidConfiguration }
        var updated = hosts
        if let index = updated.firstIndex(where: { $0.id == host.id }) {
            updated[index] = host
        } else {
            updated.append(host)
        }
        try store.save(updated)
        hosts = updated
        restart(host)
    }
    public func removeHost(_ id: UUID) throws {
        guard configurationError == nil else { throw RemoteHostError.invalidConfiguration }
        let updated = hosts.filter { $0.id != id }
        try store.save(updated)
        hosts = updated
        generations[id] = nil
        tasks[id]?.cancel()
        sessionStore.removeRemoteSessions(hostID: id)
        statuses.removeAll { $0.id == id }
        onChange?()
    }
    private func restart(_ host: RemoteHost) {
        let old = tasks[host.id]
        old?.cancel()
        let generation = UUID()
        generations[host.id] = generation
        sessionStore.removeRemoteSessions(hostID: host.id)
        setStatus(host, phase: running && host.enabled ? .connecting : .disabled)
        // Retain the predecessor until its process has exited, even across
        // rapid edit/remove/re-add cycles. No second SSH process can overlap.
        tasks[host.id] = Task { [weak self] in
            await old?.value
            guard let self, self.running, host.enabled, !Task.isCancelled,
                self.generations[host.id] == generation
            else { return }
            await self.observe(host, generation: generation)
        }
    }
    private func observe(_ host: RemoteHost, generation: UUID) async {
        var failures = 0
        while !Task.isCancelled && running && generations[host.id] == generation {
            setStatus(host, phase: .connecting)
            var connection: RemoteConnection?
            do {
                let current = try connect(host)
                connection = current
                try await withTaskCancellationHandler {
                    for try await snapshot in current.snapshots {
                        guard !Task.isCancelled, generations[host.id] == generation else { break }
                        try sessionStore.replaceRemoteSessions(host: host, snapshot: snapshot)
                        failures = 0
                        setStatus(host, phase: .connected, count: snapshot.sessions.count)
                    }
                    throw RemoteHostError.disconnected("SSH stream ended. Retrying…")
                } onCancel: {
                    current.cancel()
                }
            } catch {
                connection?.cancel()
                await connection?.waitForExit()
                guard !Task.isCancelled, running, generations[host.id] == generation else { return }
                sessionStore.removeRemoteSessions(hostID: host.id)
                setStatus(host, phase: .failed, message: error.localizedDescription)
            }
            let delay = min(60, pow(2, Double(min(failures + 1, 6))))
            failures += 1
            do { try await sleep(delay) } catch { return }
        }
    }
    private func setStatus(_ host: RemoteHost, phase: RemoteHostStatus.Phase, message: String? = nil, count: Int = 0) {
        let status = RemoteHostStatus(host: host, phase: phase, message: message, sessionCount: count)
        if let index = statuses.firstIndex(where: { $0.id == host.id }) {
            statuses[index] = status
        } else {
            statuses.append(status)
        }
        onChange?()
    }
}
