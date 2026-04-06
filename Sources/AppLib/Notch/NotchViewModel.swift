import Foundation
import Shared

@MainActor
public final class NotchViewModel: ObservableObject {
    public let sessionStore: SessionStore
    @Published public var panelState: PanelState = .collapsed

    public init(sessionStore: SessionStore) {
        self.sessionStore = sessionStore
    }
}
