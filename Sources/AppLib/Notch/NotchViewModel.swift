import Foundation
import SwiftUI
import Combine
import Shared

@MainActor
public final class NotchViewModel: ObservableObject {
    public let sessionStore: SessionStore
    @Published public var panelState: PanelState = .collapsed
    private var cancellable: AnyCancellable?

    public init(sessionStore: SessionStore) {
        self.sessionStore = sessionStore
        // Forward SessionStore changes to trigger SwiftUI re-renders.
        // Nested ObservableObjects don't propagate automatically.
        cancellable = sessionStore.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    public var aggregateState: SessionState {
        sessionStore.aggregateState
    }

    public var primarySession: SessionInfo? {
        sessionStore.primarySession
    }

    public var statusColor: Color {
        switch aggregateState {
        case .idle, .stopped: return .gray
        case .working: return Color(red: 0.31, green: 0.80, blue: 0.77) // #4ecdc4
        case .waiting: return Color(red: 0.96, green: 0.65, blue: 0.14) // #f5a623
        }
    }

    public var statusText: String {
        let count = sessionStore.sessions.count
        switch aggregateState {
        case .idle, .stopped:
            return count == 0 ? "no sessions" : (count == 1 ? "idle" : "\(count) idle")
        case .working:
            let working = sessionStore.sessions.values.filter { $0.state == .working }.count
            return working > 1 ? "\(working) working" : "working"
        case .waiting:
            let waiting = sessionStore.sessions.values.filter { $0.pendingPermission != nil }.count
            return waiting > 1 ? "\(waiting) awaiting" : "awaiting approval"
        }
    }

    public func approve() {
        sessionStore.resolvePrimaryPermission(allow: true)
    }

    public func deny() {
        sessionStore.resolvePrimaryPermission(allow: false)
    }
}
