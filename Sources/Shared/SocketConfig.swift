import Foundation

/// Canonical AF_UNIX socket path shared by the app (server) and the bridge
/// (client). It lives in the per-user `0700` `~/.zackeyes` directory rather than
/// the world-writable, sticky `/tmp` so another local uid cannot pre-bind or
/// squat it before the app starts (#136 / F-006). The app and bridge always run
/// as the same user, so `NSHomeDirectory()` resolves identically on both sides.
public enum SocketConfig {
    public static var defaultPath: String {
        NSHomeDirectory() + "/.zackeyes/zackeyes.sock"
    }
}
