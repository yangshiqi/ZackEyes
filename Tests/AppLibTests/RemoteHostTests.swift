import Foundation
import RemoteCore
import Testing

@testable import AppLib

struct RemoteHostTests {
    @Test func configRejectsUnsafeDestinationsAndPreservesUnreadableFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RemoteHostStore(url: root.appendingPathComponent("remote-hosts.json"))
        let host = RemoteHost(name: "Build server", destination: "user@build.example.com")
        try store.save([host])
        #expect(try store.load() == [host])
        for destination in ["-oProxyCommand=evil", "host;touch /tmp/bad", "host\nother", "", "$(whoami)"] {
            #expect(throws: (any Error).self) { try store.save([RemoteHost(name: "Test", destination: destination)]) }
        }
        #expect(try store.load() == [host])
        try Data("{broken".utf8).write(to: store.url)
        #expect(throws: (any Error).self) { try store.load() }
        #expect(try String(contentsOf: store.url, encoding: .utf8) == "{broken")
    }
    @Test func hostLimitAndSSHArgumentsKeepCommandFixed() throws {
        #expect(throws: (any Error).self) {
            try RemoteHostStore.validate((0..<9).map { RemoteHost(name: "Host \($0)", destination: "host\($0)") })
        }
        let host = RemoteHost(name: "Build", destination: "build-alias")
        let args = try RemoteSSHTransport.arguments(for: host)
        #expect(args.contains("BatchMode=yes"))
        #expect(args.contains("StrictHostKeyChecking=yes"))
        #expect(args.contains("UpdateHostKeys=no"))
        #expect(args.contains("ControlMaster=no"))
        #expect(args.contains("PreferredAuthentications=publickey"))
        #expect(args.suffix(2) == ["build-alias", "exec \"$HOME/.local/bin/zackeyes\" --stream"])
    }
}
