import Testing
import Foundation
@testable import AppLib

struct RedactorTests {

    @Test func redactsHomeDirectoryPrefixToTilde() {
        let r = Redactor(homeDirectory: "/Users/alice", username: "alice")
        #expect(r.redact("/Users/alice/.zackeyes/bin/bridge") == "~/.zackeyes/bin/bridge")
    }

    @Test func redactsBareUsernameOccurrences() {
        let r = Redactor(homeDirectory: "/Users/alice", username: "alice")
        #expect(r.redact("/opt/tools/alice-helper --user alice")
            == "/opt/tools/<user>-helper --user <user>")
    }

    @Test func homePrefixTakesPrecedenceOverBareUsername() {
        let r = Redactor(homeDirectory: "/Users/alice", username: "alice")
        #expect(r.redact("/Users/alice/projects/alice-app")
            == "~/projects/<user>-app")
    }

    @Test func leavesUnrelatedTextUntouched() {
        let r = Redactor(homeDirectory: "/Users/alice", username: "alice")
        #expect(r.redact("socket reachable; statusLine: direct")
            == "socket reachable; statusLine: direct")
    }

    @Test func handlesEmptyAndNilGracefully() {
        let r = Redactor(homeDirectory: "/Users/alice", username: "alice")
        #expect(r.redact("") == "")
        #expect(r.redactOptional(nil) == nil)
        #expect(r.redactOptional("/Users/alice/x") == "~/x")
    }

    @Test func shortOrEmptyUsernameDoesNotCorruptOutput() {
        // Guard against a pathological empty username turning every char into <user>.
        // Home dir is set to a path that won't match the test input so we isolate
        // the empty-username guard. (Flagged deviation: original used "/Users/" which
        // itself matched the prefix — the intent is to test the empty-username guard.)
        let r = Redactor(homeDirectory: "/Users/alice", username: "")
        #expect(r.redact("/Users/bob/file") == "/Users/bob/file")
    }

    // #129 F-016 / F-020: case-insensitive username + hostname (incl .local) redaction.
    @Test func caseInsensitiveUsernameAndHostname() {
        let r = Redactor(homeDirectory: "/Users/bob", username: "bob", hostName: "workstation-7.local")
        let out = r.redact("/Users/bob/x ran by BOB on workstation-7.local (Workstation-7)")
        #expect(out.contains("<user>"))
        #expect(out.contains("<host>"))
        #expect(!out.lowercased().contains("bob"))
        #expect(!out.lowercased().contains("workstation-7"))
    }
}
