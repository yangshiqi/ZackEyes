import AppKit
import SwiftUI
import Testing
import Shared
@testable import AppLib

@MainActor
struct CodexCreditsRenderingTests {
    @Test(arguments: [380.0, 520.0])
    func creditsReplaceTheExistingHeaderForSingleAndDualAgentLayouts(width: Double) throws {
        for dual in [false, true] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let tracker = UsageTracker(projectsDir: directory, codexSessionsDir: nil,
                                       cacheURL: directory.appendingPathComponent("cache.json"))
            let reset = Date().addingTimeInterval(3600).timeIntervalSince1970
            tracker.updateFromCodexRateLimits([
                "primary": ["used_percent": 100, "window_minutes": 10080, "resets_at": reset],
                "credits": ["has_credits": true, "balance": "58459.3490105"]])
            if dual {
                tracker.updateFromHook(rateLimits: [
                    "five_hour": AnyCodable(["used_percentage": 42, "resets_at": reset]),
                    "seven_day": AnyCodable(["used_percentage": 31, "resets_at": reset])])
            }
            #expect(tracker.snapshot.creditsInUse() != nil)
            let root = SimulatedNotchFullView(viewModel: NotchViewModel(sessionStore: SessionStore()),
                usageTracker: tracker, modeStore: NotchModeStore(), updateChecker: UpdateChecker(),
                downloader: UpdateDownloader(downloadDir: directory), isActive: false, showMenu: { _ in })
                .frame(width: width, height: 480)
            let host = NSHostingView(rootView: root)
            host.frame = NSRect(x: 0, y: 0, width: width, height: 480)
            let panel = NSPanel(contentRect: host.frame, styleMask: [.nonactivatingPanel],
                                backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            panel.contentView = host
            host.layoutSubtreeIfNeeded()
            let rect = NSRect(x: 0, y: 0, width: width, height: 150)
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: rect))
            host.cacheDisplay(in: rect, to: bitmap)
            panel.close()
            #expect(bitmap.pixelsWide >= Int(width))
            if let destination = ProcessInfo.processInfo.environment["ZACKEYES_CREDITS_RENDER_DIR"] {
                let file = URL(fileURLWithPath: destination).appendingPathComponent("credits-\(dual ? "dual" : "single")-\(Int(width)).png")
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try #require(bitmap.representation(using: .png, properties: [:])).write(to: file)
            }
        }
    }
}
