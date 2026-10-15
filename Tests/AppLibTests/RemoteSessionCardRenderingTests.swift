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
        session.permissionRisk = .yolo
        session.reasoningEffort = "high"
        session.lastActiveAt = now.addingTimeInterval(-60)
        let view = NotchExpandedView(viewModel: NotchViewModel(sessionStore: SessionStore()), isActive: false)
        let renderer = ImageRenderer(
            content: view.sessionCardContent(session, theme: .rock, title: session.displayName)
                .frame(width: 420)
                .background(Color.black)
                .environment(\.colorScheme, scheme))
        renderer.scale = 1
        let image = try #require(renderer.cgImage)
        let bitmap = NSBitmapImageRep(cgImage: image)

        // Count visible neutral text rows on the card's left, excluding the
        // colored badges. Project, context, host/state, model and tool must
        // each have legible glyphs against the fixed dark background.
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
        var riskPixels = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 200..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if color.redComponent > 0.6 && color.redComponent > color.greenComponent + 0.2
                    && color.redComponent > color.blueComponent + 0.2 { riskPixels += 1 }
                if color.greenComponent > 0.5 && color.greenComponent > color.redComponent + 0.2
                    && color.greenComponent > color.blueComponent + 0.1 { badgePixels += 1 }
            }
        }
        #expect(riskPixels >= 5, "The YOLO badge must use the same critical color as local cards")
        #expect(badgePixels >= 5, "The agent badge must retain its own identity color")
        #expect(bands >= 5, "All five text rows must remain readable on a dark card (\(scheme)); found \(bands)")
        if let directory = ProcessInfo.processInfo.environment["ZACKEYES_CARD_RENDER_DIR"] {
            let url = URL(fileURLWithPath: directory).appendingPathComponent("remote-card-\(scheme).png")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: url)
        }
    }
    @Test func remoteAttentionKeepsItsSemanticColor() throws {
        var session = SessionInfo(id: "remote-attention", cwd: "/work/Project", agent: .codex, state: .waiting)
        session.source = .remote
        session.remoteObservedState = .waiting
        let view = NotchExpandedView(viewModel: NotchViewModel(sessionStore: SessionStore()), isActive: false)
        let renderer = ImageRenderer(content:
            view.sessionCardContent(session, theme: .rock, title: session.displayName)
                .frame(width: 420).background(Color.black).environment(\.colorScheme, .light))
        let bitmap = NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
        var attentionPixels = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 60..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if color.redComponent > 0.6 && color.greenComponent > 0.4 && color.blueComponent < 0.4 {
                    attentionPixels += 1
                }
            }
        }
        #expect(attentionPixels >= 5, "Remote waiting instructions must retain the attention color")
    }

}
