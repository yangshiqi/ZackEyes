import Foundation
import Testing

@testable import AppLib

@Suite struct RemoteSetupGuideTests {
    @Test func installAndDownloadMatchTheClientVersion() throws {
        let guide = RemoteSetupGuide(appVersion: "0.10.1")
        #expect(
            guide.downloadURL.absoluteString
                == "https://github.com/yangshiqi/ZackEyes-release/releases/tag/v0.10.1")
        let command = try #require(guide.installCommand)
        #expect(command.contains("/download/v0.10.1/install-remote.sh"))
        #expect(command.hasSuffix("| sh -s -- 0.10.1"))
        #expect(
            guide.documentationURL.absoluteString
                == "https://zackeyes.vercel.app/docs#ssh-troubleshooting")
    }

    @Test(
        arguments: [nil, "", "latest", "0.10.1\n", "0.10.1; touch /tmp/test", "../other"]
            as [String?])
    func unknownVersionOffersDownloadsWithoutInventingACommand(version: String?) {
        let guide = RemoteSetupGuide(appVersion: version)
        #expect(guide.installCommand == nil)
        #expect(
            guide.downloadURL.absoluteString
                == "https://github.com/yangshiqi/ZackEyes-release/releases")
    }
}
