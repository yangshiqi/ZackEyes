import Testing
import Foundation
@testable import AppLib

struct WelcomeTriggerTests {
    // Each test uses a uniquely-named suite so tests don't share state and
    // don't touch the user's real defaults.
    private func defaults(_ suite: String) -> UserDefaults {
        let d = UserDefaults(suiteName: "WelcomeTriggerTests.\(suite)")!
        d.removePersistentDomain(forName: "WelcomeTriggerTests.\(suite)")
        return d
    }

    @Test func firesWhenNoVersionStored() {
        let d = defaults(#function)
        #expect(WelcomeTrigger.shouldShowWelcome(defaults: d, currentVersion: "1.0.0") == true)
    }

    @Test func firesWhenStoredVersionDiffers() {
        let d = defaults(#function)
        d.set("0.9.0", forKey: WelcomeTrigger.storageKey)
        #expect(WelcomeTrigger.shouldShowWelcome(defaults: d, currentVersion: "1.0.0") == true)
    }

    @Test func skipsWhenStoredVersionMatches() {
        let d = defaults(#function)
        d.set("1.0.0", forKey: WelcomeTrigger.storageKey)
        #expect(WelcomeTrigger.shouldShowWelcome(defaults: d, currentVersion: "1.0.0") == false)
    }

    @Test func skipsWhenCurrentVersionNil() {
        let d = defaults(#function)
        #expect(WelcomeTrigger.shouldShowWelcome(defaults: d, currentVersion: nil) == false)
    }

    @Test func markShownPersistsVersion() {
        let d = defaults(#function)
        WelcomeTrigger.markShown(defaults: d, currentVersion: "1.2.3")
        #expect(d.string(forKey: WelcomeTrigger.storageKey) == "1.2.3")
        #expect(WelcomeTrigger.shouldShowWelcome(defaults: d, currentVersion: "1.2.3") == false)
    }

    @Test func markShownWithNilVersionIsNoop() {
        let d = defaults(#function)
        d.set("0.9.0", forKey: WelcomeTrigger.storageKey)
        WelcomeTrigger.markShown(defaults: d, currentVersion: nil)
        #expect(d.string(forKey: WelcomeTrigger.storageKey) == "0.9.0")
    }
}
