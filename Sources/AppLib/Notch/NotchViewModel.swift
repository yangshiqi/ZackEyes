import Foundation
import SwiftUI
import Shared

@MainActor
public final class NotchViewModel: ObservableObject {
    public let sessionStore: SessionStore
    @Published public var panelState: PanelState = .collapsed

    public init(sessionStore: SessionStore) {
        self.sessionStore = sessionStore
    }

    public var statusColor: Color {
        switch sessionStore.state {
        case .idle: return .gray
        case .working: return Color(red: 0.31, green: 0.80, blue: 0.77) // #4ecdc4
        case .waiting: return Color(red: 0.96, green: 0.65, blue: 0.14) // #f5a623
        case .stopped: return .gray
        }
    }

    public var statusText: String {
        switch sessionStore.state {
        case .idle: return "idle"
        case .working: return "working"
        case .waiting: return "awaiting approval"
        case .stopped: return "stopped"
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
