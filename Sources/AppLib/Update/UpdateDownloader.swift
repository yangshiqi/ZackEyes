import AppKit
import Foundation

/// Downloads the DMG asset for a new release into the user's tmp directory
/// and hands it to `NSWorkspace` so Finder mounts the disk image and shows
/// the drag-to-Applications layout.
///
/// Cache rule: if the same DMG filename already exists in tmp from an earlier
/// click in this session (or before reboot), skip the network and just open
/// it. macOS wipes tmp on reboot — fine.
///
/// `opener` is injectable so tests can avoid bouncing the user's actual
/// Finder. Production callers use the default (`NSWorkspace.shared.open`).
@MainActor
public final class UpdateDownloader: ObservableObject {
    public enum State: Equatable {
        case idle
        case downloading
        case ready(URL)
        case failed(String)
    }

    @Published public private(set) var state: State = .idle

    private let opener: (URL) -> Void

    public init(opener: @escaping (URL) -> Void = { url in
        NSWorkspace.shared.open(url)
    }) {
        self.opener = opener
    }

    /// Download the DMG at `url` to tmp/<filename>, then open it with Finder.
    /// On cache hit, skips the URLSession call entirely.
    public func download(from url: URL) async {
        // Prevent re-entrance: if a previous click is still mid-flight, ignore.
        // The menu rebuild disables the item, but @Published propagation can lag
        // a fast double-click — this gate is the actual safety net.
        if case .downloading = state { return }

        // Re-validate the filename before using it as a path component (the URL
        // is reconstructed + validated upstream, but this sink must not assume
        // that — T-4).
        let filename = url.lastPathComponent
        guard !filename.isEmpty, filename.hasSuffix(".dmg"),
              !filename.contains("/"), !filename.contains("..") else {
            state = .failed("invalid asset filename")
            return
        }
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent(filename)

        if FileManager.default.fileExists(atPath: dest.path) {
            state = .ready(dest)
            opener(dest)
            return
        }

        state = .downloading
        do {
            let (tmpURL, response) = try await URLSession.shared.download(from: url)
            // URLSession.download does NOT throw on 4xx/5xx — without this guard
            // we'd cheerfully save GitHub's 404 HTML page as a "DMG" and hand it
            // to NSWorkspace.open. Treat anything outside 2xx as a download failure.
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                state = .failed("HTTP \(code)")
                return
            }
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tmpURL, to: dest)
            state = .ready(dest)
            opener(dest)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Reset to `.idle` so a failed item's menu title goes back to the
    /// "Update Available" affordance.
    public func reset() {
        state = .idle
    }

    // MARK: - Test helpers

    /// Test-only seam: lets unit tests assert state transitions without
    /// running the URLSession path.
    internal func simulateFailure(message: String) {
        state = .failed(message)
    }
}
