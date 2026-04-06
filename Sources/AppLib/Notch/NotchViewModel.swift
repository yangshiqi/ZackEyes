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

    public var statusColor: Color {
        switch sessionStore.state {
        case .idle, .stopped: return .gray
        case .working: return Color(red: 0.31, green: 0.80, blue: 0.77) // #4ecdc4
        case .waiting: return Color(red: 0.96, green: 0.65, blue: 0.14) // #f5a623
        }
    }

    public var statusText: String {
        switch sessionStore.state {
        case .idle, .stopped: return "idle"
        case .working: return "working"
        case .waiting: return "awaiting approval"
        }
    }

    public var toolBadge: String? {
        sessionStore.currentToolName
    }

    public func approve() {
        sessionStore.resolvePermission(allow: true)
    }

    public func deny() {
        sessionStore.resolvePermission(allow: false)
    }
}
