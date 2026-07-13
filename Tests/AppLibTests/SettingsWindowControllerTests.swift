import AppKit
import Testing
@testable import AppLib

struct SettingsWindowControllerTests {
    @Test @MainActor
    func settingsFloatsOnlyWhileActive() {
        #expect(SettingsWindowLevelPolicy.level(isActive: true) == .floating)
        #expect(SettingsWindowLevelPolicy.level(isActive: false) == .normal)
    }
}
