import Foundation

/// A downloadable asset attached to a GitHub release.
public struct GitHubAsset: Codable, Sendable {
    public let name: String
    public let browserDownloadURL: URL

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
    }
}

/// Minimal model for GitHub's /releases/latest response.
public struct GitHubRelease: Codable, Sendable {
    public let tagName: String
    public let htmlURL: URL
    public let assets: [GitHubAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case assets
    }
}

/// Checks GitHub Releases for new versions of ZackEyes.
///
/// Usage: create once, call `start()`. Publishes `availableVersion` and
/// `releaseURL` when a newer release is found.
@MainActor
public final class UpdateChecker: ObservableObject {

    @Published public var availableVersion: String?
    @Published public var releaseURL: URL?
    @Published public var dmgURL: URL?

    /// Called once when a new version is first detected.
    public var onNewVersion: ((String, URL) -> Void)?

    private var notifiedVersion: String?

    private var timer: Timer?
    private let checkInterval: TimeInterval
    private let repoOwner = "yangshiqi"
    private let repoName = "ZackEyes-release"

    /// Current app version from Info.plist.
    private var localVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    public init(checkInterval: TimeInterval = 6 * 3600) {
        self.checkInterval = checkInterval
    }

    public func start() {
        Task { await check() }
        timer = Timer.scheduledTimer(withTimeInterval: checkInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.check()
            }
        }
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Manual "Check for Updates" trigger. Runs the same poll as the 6h
    /// timer; results surface through the existing publish path
    /// (availableVersion → onNewVersion notification + menu item). No
    /// separate "up to date" UI — consistent with the app's auto-poll model.
    public func checkNow() {
        Task { await check() }
    }

    // MARK: - Check logic

    private func check() async {
        guard let url = URL(string: "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/latest") else { return }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }
            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            let remoteVersion = release.tagName.hasPrefix("v")
                ? String(release.tagName.dropFirst())
                : release.tagName

            if Self.isNewer(remote: remoteVersion, thanLocal: localVersion) {
                availableVersion = remoteVersion
                releaseURL = release.htmlURL
                // Do NOT trust the server-supplied browser_download_url (it could
                // point at any host). Reconstruct the canonical GitHub asset URL
                // from trusted components + a validated single-component filename
                // and tag, so the download host/repo can never be attacker-chosen
                // (T-4). .urlHostAllowed encodes '/', blocking path traversal via a
                // compromised tag_name (flagged by Gemini + Codex on PR #134).
                if let asset = release.assets.first(where: { $0.name.hasSuffix(".dmg") }),
                   Self.isSafeAssetName(asset.name),
                   !release.tagName.contains("/"), !release.tagName.contains(".."),
                   let tag = release.tagName.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed),
                   let name = asset.name.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) {
                    dmgURL = URL(string: "https://github.com/\(repoOwner)/\(repoName)/releases/download/\(tag)/\(name)")
                } else {
                    dmgURL = nil
                }
                if remoteVersion != notifiedVersion {
                    notifiedVersion = remoteVersion
                    onNewVersion?(remoteVersion, release.htmlURL)
                }
            }
        } catch {
            // Network/parse failure — silent, retry on next timer tick
        }
    }

    // MARK: - Semantic version comparison

    /// Returns true if `remote` is strictly newer than `local`.
    /// Strips leading "v" from either string. Returns false on parse failure.
    public nonisolated static func isNewer(remote: String, thanLocal local: String) -> Bool {
        let r = parseVersion(remote)
        let l = parseVersion(local)
        guard !r.isEmpty, !l.isEmpty else { return false }

        for i in 0..<max(r.count, l.count) {
            let rv = i < r.count ? r[i] : 0
            let lv = i < l.count ? l[i] : 0
            if rv > lv { return true }
            if rv < lv { return false }
        }
        return false
    }

    /// A release asset name must be a single, simple filename before it is used
    /// to build a download URL or a tmp destination path: non-empty, ends in
    /// `.dmg`, no path separators, no parent ref (T-4).
    nonisolated static func isSafeAssetName(_ name: String) -> Bool {
        !name.isEmpty
            && name.hasSuffix(".dmg")
            && !name.contains("/")
            && !name.contains("\\")
            && !name.contains("..")
    }

    private nonisolated static func parseVersion(_ string: String) -> [Int] {
        let stripped = string.hasPrefix("v") ? String(string.dropFirst()) : string
        let parts = stripped.split(separator: ".").compactMap { Int($0) }
        guard !parts.isEmpty, parts.count == stripped.split(separator: ".").count else { return [] }
        return parts
    }
}
