import Testing
import Foundation
@testable import Shared

/// #136 / F-006: the socket must live under the per-user 0700 ~/.zackeyes dir,
/// not world-writable /tmp, so another uid can't pre-bind / squat it.
@Test func socketConfig_isUnderHomeNotTmp() {
    let path = SocketConfig.defaultPath
    #expect(path.hasSuffix("/.zackeyes/zackeyes.sock"))
    #expect(!path.hasPrefix("/tmp/"))
    #expect(path.hasPrefix(NSHomeDirectory()))
}

/// Codex review (PR #141): the path must always fit AF_UNIX sun_path (<=103 on
/// Darwin) — otherwise connect()/bind() reject it and every hook silently fails.
@Test func socketConfig_fitsSunPath() {
    #expect(SocketConfig.defaultPath.utf8.count <= 103)
}
