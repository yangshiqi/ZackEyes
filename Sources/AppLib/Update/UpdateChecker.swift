import Foundation

/// Minimal model for GitHub's /releases/latest response.
public struct GitHubRelease: Codable, Sendable {
    public let tagName: String
    public let htmlURL: URL

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
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

    /// Called once when a new version is first detected.
    public var onNewVersion: ((String, URL) -> Void)?

    private var notifiedVersion: String?

    private var timer: Timer?
    private let checkInterval: TimeInterval
    private let repoOwner = "yangshiqi"
    private let repoName = "ZackEyes"

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

    // MARK: - Check logic

    private func check() async {
        guard let url = URL(string: "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/latest") else { return }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        if let token = Self.loadGitHubToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
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
                if remoteVersion != notifiedVersion {
                    notifiedVersion = remoteVersion
                    onNewVersion?(remoteVersion, release.htmlURL)
                }
            }
        } catch {
            // Network/parse failure — silent, retry on next timer tick
        }
    }

    // MARK: - GitHub token

    /// Read optional GitHub token from ~/.zackeyes/config.json ("githubToken" key).
    /// Enables update checks for private repos.
    private nonisolated static func loadGitHubToken() -> String? {
        let path = NSHomeDirectory() + "/.zackeyes/config.json"
        guard let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["githubToken"] as? String,
              !token.isEmpty else { return nil }
        return token
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

    private nonisolated static func parseVersion(_ string: String) -> [Int] {
        let stripped = string.hasPrefix("v") ? String(string.dropFirst()) : string
        let parts = stripped.split(separator: ".").compactMap { Int($0) }
        guard !parts.isEmpty, parts.count == stripped.split(separator: ".").count else { return [] }
        return parts
    }
}
