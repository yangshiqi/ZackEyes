import Testing
import Foundation
@testable import AppLib

/// Scan findings F-001/F-002: the socket must only accept peers running as the
/// same user. These pin the peer-authorization decision (the getpeereid call
/// itself needs a cross-uid connection, which a single-user test cannot stage).
struct SocketServerAuthTests {
    @Test func acceptsSameUidPeer() {
        #expect(SocketServer.peerIsAuthorized(peerEUID: 501, ownEUID: 501) == true)
    }

    @Test func rejectsDifferentUidPeer() {
        #expect(SocketServer.peerIsAuthorized(peerEUID: 502, ownEUID: 501) == false)
        #expect(SocketServer.peerIsAuthorized(peerEUID: 0, ownEUID: 501) == false)   // even root
    }
}
