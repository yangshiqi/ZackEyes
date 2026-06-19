import Foundation
import Shared

/// Read side of the pending-event spool (#89). At app startup, replays the
/// events `PendingEventQueue` wrote while the app was closed, in filename
/// (timestamp) order, through the same handler the live socket uses.
///
/// Every `.json` file is consumed — replayed, expired, or malformed, it is
/// deleted afterwards — so the spool can never accumulate across launches.
/// Replayed events carry `isReplayed == true` (set post-decode)
/// so the event pipeline suppresses stale notifications.
public struct PendingEventReplayer {

    private let directory: String
    private let maxAge: TimeInterval

    public init(
        directory: String = NSHomeDirectory() + "/.zackeyes/pending",
        maxAge: TimeInterval = 24 * 3600
    ) {
        self.directory = directory
        self.maxAge = maxAge
    }

    /// Returns the number of events handed to `handler`.
    @discardableResult
    public func replayAll(
        now: Date = Date(),
        handler: (BridgeEvent) -> Void
    ) -> Int {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory) else { return 0 }

        var replayed = 0
        for name in names.filter({ $0.hasSuffix(".json") }).sorted() {
            let path = directory + "/" + name
            // Consume unconditionally: replayed, expired, or unreadable, the
            // file is done after this iteration.
            defer { try? fm.removeItem(atPath: path) }

            guard let ts = Self.timestamp(fromFileName: name),
                  now.timeIntervalSince(ts) <= maxAge,
                  let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  var event = try? JSONDecoder().decode(BridgeEvent.self, from: data),
                  // Read side must enforce the SAME allowlist the write side uses
                  // (#127/F-012): a planted file with any other event type — or a
                  // forged PermissionRequest — is rejected, not fed to the handler.
                  BridgeEvent.replayableEventNames.contains(event.bridgeEvent)
            else { continue }

            event.isReplayed = true
            handler(event)
            replayed += 1
        }
        return replayed
    }

    /// `<unix-ms>-<pid>-<uuid>.json` → spool time.
    static func timestamp(fromFileName name: String) -> Date? {
        guard let msPart = name.split(separator: "-").first,
              let ms = Double(msPart) else { return nil }
        return Date(timeIntervalSince1970: ms / 1000)
    }
}
