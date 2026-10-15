import AppKit
import SwiftUI
import Testing
@testable import AppLib

@Suite @MainActor struct RemoteSessionCardRenderingTests {
    @Test(arguments: [ColorScheme.light, .dark])
    func darkCardKeepsAllMetadataReadableInEitherAppearance(scheme: ColorScheme) throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var session = SessionInfo(
            id: "remote-contrast", cwd: "/work/RemoteProject", agent: .codex,
            state: .working, startedAt: now.addingTimeInterval(-60))
        session.source = .remote
        session.remoteHostName = "Example host"
        session.remoteObservedState = .working
        session.modelDisplayName = "gpt-test"
        session.currentToolName = "exec_command"
        session.lastActiveAt = now.addingTimeInterval(-60)
        let renderer = ImageRenderer(
            content: RemoteSessionCard(session: session, now: now)
                .frame(width: 420)
                .background(Color.black)
                .environment(\.colorScheme, scheme))
        renderer.scale = 1
        let image = try #require(renderer.cgImage)
        let bitmap = NSBitmapImageRep(cgImage: image)

        // Count visible neutral text rows on the card's left, excluding the
        // colored agent badge. Project, host/state, model, tool and activity
        // must each have legible glyphs against the fixed dark background.
        var rows: [Int] = []
        for y in 0..<bitmap.pixelsHigh {
            var readable = 0
            for x in 12..<280 {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let channels = [color.redComponent, color.greenComponent, color.blueComponent]
                if channels.min()! > 0.5 && channels.max()! - channels.min()! < 0.05 { readable += 1 }
            }
            if readable >= 3 { rows.append(y) }
        }
        var bands = 0
        var previous = -10
        for row in rows {
            if row - previous > 3 { bands += 1 }
            previous = row
        }
        var badgePixels = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 300..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if color.greenComponent > 0.5 && color.greenComponent > color.redComponent + 0.2
                    && color.greenComponent > color.blueComponent + 0.1 { badgePixels += 1 }
            }
        }
        #expect(badgePixels >= 5, "The agent badge must retain its own identity color")
        #expect(bands >= 5, "All five metadata rows must remain readable on a dark card (\(scheme)); found \(bands)")
    }
}
