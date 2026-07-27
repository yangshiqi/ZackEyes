import Testing
import Foundation
@testable import AppLib

/// #203 — one rule, one place. Claude and Codex each owned a copy of this
/// decision; the security fix (#129/F-018) landed on one of them, and the stale
/// copy went on claiming third-party hooks by bare substring.
struct HookOwnershipTests {
    private let bridge = "/Users/me/.zackeyes/bin/bridge"

    @Test func claimsOurLauncherPath() {
        #expect(HookOwnership.isOurs(
            command: "/Users/me/.zackeyes/bin/bridge --event Stop --agent codex", bridgePath: bridge))
    }

    @Test func claimsConfiguredBridgePathOutsideOurDirectory() {
        // Test fixtures and relocated installs point somewhere else entirely.
        #expect(HookOwnership.isOurs(command: "/test/bridge --event Stop", bridgePath: "/test/bridge"))
        #expect(HookOwnership.isOurs(command: "\"/test/b r/bridge\" --event Stop", bridgePath: "/test/b r/bridge"))
        #expect(HookOwnership.isOurs(command: "'/test/b r/bridge' --event Stop", bridgePath: "/test/b r/bridge"))
    }

    /// The regression: a third-party command is not ours just because our name
    /// appears somewhere in it.
    @Test func doesNotClaimThirdPartyCommandsMentioningOurName() {
        for command in [
            "/Users/me/tools/zackeyes-helper/notify.sh --codex",
            "/opt/homebrew/bin/zackeyes-exporter",
            "echo 'installing zackeyes' && other-tool",
            "~/scripts/backup-zackeyes-config.sh",
        ] {
            #expect(HookOwnership.isOurs(command: command, bridgePath: bridge) == false,
                    "claimed a hook we do not own: \(command)")
        }
    }

    /// Our path appearing as an ARGUMENT does not make the entry ours — the
    /// same bug as the substring match, one step narrower (found in review).
    @Test func doesNotClaimCommandsWhereOurPathIsMerelyAnArgument() {
        for command in [
            "backup-tool \"$HOME/.zackeyes/config.json\"",
            "BRIDGE=/Users/me/.zackeyes/bin/bridge other-tool",
            "rsync -a /Users/me/.zackeyes/ /backup/",
            "/test/bridge-helper --check",
        ] {
            #expect(HookOwnership.isOurs(command: command, bridgePath: "/test/bridge") == false,
                    "claimed an entry whose program is not ours: \(command)")
        }
    }

    /// An env-var prefix in front of OUR launcher must still be recognised, or
    /// uninstall silently leaves the entry behind.
    @Test func claimsOurLauncherBehindEnvironmentPrefixes() {
        #expect(HookOwnership.isOurs(
            command: "ZACKEYES_DEBUG=1 /Users/me/.zackeyes/bin/bridge --event Stop",
            bridgePath: "/Users/me/.zackeyes/bin/bridge"))
        #expect(HookOwnership.isOurs(
            command: "A=1 B=2 \"/test/bridge\" --event Stop", bridgePath: "/test/bridge"))
    }

    @Test func doesNotClaimUnrelatedCommands() {
        #expect(HookOwnership.isOurs(command: "other-tool --check", bridgePath: bridge) == false)
        #expect(HookOwnership.isOurs(command: "", bridgePath: bridge) == false)
    }
}
