import Foundation

/// Keep every setup action pinned to this client release. Unknown development
/// versions still offer documentation/downloads, without guessing an installer.
struct RemoteSetupGuide {
    let installCommand: String?
    let downloadURL: URL
    let documentationURL = URL(string: "https://zackeyes.vercel.app/docs#ssh-troubleshooting")!

    init(appVersion: String?) {
        let releases = "https://github.com/yangshiqi/ZackEyes-release/releases"
        if let version = appVersion,
            let match = version.range(of: "[0-9]+\\.[0-9]+\\.[0-9]+", options: .regularExpression),
            match == version.startIndex..<version.endIndex
        {
            downloadURL = URL(string: "\(releases)/tag/v\(version)")!
            installCommand =
                "curl -fsSL \(releases)/download/v\(version)/install-remote.sh | sh -s -- \(version)"
        } else {
            downloadURL = URL(string: releases)!
            installCommand = nil
        }
    }
}
