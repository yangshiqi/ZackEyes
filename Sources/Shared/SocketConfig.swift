import Foundation

/// Canonical AF_UNIX socket path shared by the app (server) and the bridge
/// (client). It lives in the per-user `0700` `~/.zackeyes` directory rather than
/// the world-writable, sticky `/tmp` so another local uid cannot pre-bind or
/// squat it before the app starts (#136 / F-006). The app and bridge always run
/// as the same user, so `NSHomeDirectory()` resolves identically on both sides.
public enum SocketConfig {
    /// `sockaddr_un.sun_path` holds 104 bytes on Darwin; keep a small margin.
    static let maxSunPath = 100

    public static var defaultPath: String {
        let preferred = NSHomeDirectory() + "/.zackeyes/zackeyes.sock"
        if preferred.utf8.count <= maxSunPath { return preferred }
        // Pathological long home dir would overflow sun_path, which would make
        // connect()/bind() reject the path and silently break every hook (Codex
        // review, PR #141). Fall back to a guaranteed-short per-uid /tmp name.
        // This is still safe against a same-name squatter from another uid:
        // both ends now getpeereid-verify the peer and reject a foreign euid.
        return "/tmp/zackeyes-\(getuid()).sock"
    }
}
