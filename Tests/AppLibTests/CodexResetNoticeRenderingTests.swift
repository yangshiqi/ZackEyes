import AppKit
import SwiftUI
import Testing
@testable import AppLib

@MainActor
struct CodexResetNoticeRenderingTests {
    @Test(arguments: [380.0, 520.0])
    func originalTextUsesTwoRowsWithoutExpandingTheCard(width: Double) throws {
        let now = Date()
        let short = "A short original announcement."
        let long = String(repeating: "Original announcement: an extra reset is planned, with timing to follow. ", count: 20)
        var heights: [Int] = []
        for (name, text, expected) in [
            ("unknown-short", short, nil as Date?),
            ("unknown-long", long, nil as Date?),
            ("scheduled-long", long, now.addingTimeInterval(3600)),
            ("missing", nil as String?, nil as Date?)
        ] {
            let notice = CodexResetAnnouncement(
                kind: .automatic, phase: expected == nil ? .announced : .scheduled,
                sourceURL: URL(string: "https://x.com/example/status/123")!,
                announcedAt: now, expectedAt: expected, expectedDay: nil,
                expectedWindowText: nil, reportedDeliveredAt: nil,
                scope: "All users (per announcement)", providerUpdatedAt: now,
                originalText: text)
            let host = NSHostingView(rootView: CodexResetNoticeView(announcement: notice)
                .frame(width: width).background(Color.black))
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: 120),
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            panel.contentView = host
            panel.setContentSize(host.fittingSize)
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            panel.close()
            heights.append(bitmap.pixelsHigh)
            #expect(bitmap.pixelsHigh <= 220, "Header, two original rows and announced time must stay compact")
            if let directory = ProcessInfo.processInfo.environment["ZACKEYES_RESET_RENDER_DIR"] {
                let file = URL(fileURLWithPath: directory).appendingPathComponent("\(name)-\(Int(width)).png")
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try #require(bitmap.representation(using: .png, properties: [:])).write(to: file)
            }
        }
        #expect(Set(heights).count == 1, "Long original text and known timing must not create extra card rows")
    }
}

extension CodexResetNoticeRenderingTests {
    @Test func originalHoverTracksAnInactivePanelWithoutTakingClicksOrFocus() throws {
        let anchor = CodexResetOriginalTextPopover.AnchorView(frame: NSRect(x: 0, y: 0, width: 200, height: 30))
        anchor.updateTrackingAreas()
        #expect(anchor.trackingAreas.contains { $0.options.contains(.activeAlways) })
        #expect(anchor.hitTest(NSPoint(x: 10, y: 10)) == nil)
        var transitions: [Bool] = []
        anchor.onHover = { transitions.append($0) }
        let event = try #require(NSEvent.enterExitEvent(with: .mouseEntered, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            eventNumber: 0, trackingNumber: 0, userData: nil))
        anchor.mouseEntered(with: event)
        anchor.mouseExited(with: event)
        #expect(transitions == [true, false])
        let panel = CodexResetOriginalTextPopover.HoverPanel(contentRect: .zero,
            styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        #expect(!panel.canBecomeKey)
        #expect(!panel.canBecomeMain)
        panel.close()
    }
}

extension CodexResetNoticeRenderingTests {
    @Test func fullTextChunksPreserveEveryCharacterWithBoundedLayout() {
        let original = String(repeating: "Original 👩🏽‍💻 中文 é announcement.\n", count: 10_000)
        let chunks = CodexResetOriginalTextPopover.readerChunks(original)
        #expect(chunks.joined() == original)
        #expect(chunks.allSatisfy { $0.utf8.count <= 2051 })
        #expect(chunks.count > 1)
    }

    @Test func hoverReaderBelongsToItsParentEvenOutsideTheParentFrame() {
        let parent = CodexResetOriginalTextPopover.HoverPanel(
            contentRect: NSRect(x: -3000, y: -3000, width: 100, height: 40),
            styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        let child = CodexResetOriginalTextPopover.HoverPanel(
            contentRect: NSRect(x: -3000, y: -3200, width: 100, height: 180),
            styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        child.isReleasedWhenClosed = false
        defer { parent.removeChildWindow(child); child.close(); parent.close() }
        parent.addChildWindow(child, ordered: .above)
        parent.orderFrontRegardless()
        child.orderFrontRegardless()
        let point = NSPoint(x: child.frame.midX, y: child.frame.midY)
        #expect(!parent.frame.contains(point))
        #expect(CodexResetOriginalTextPopover.containsReader(at: point, attachedTo: parent))
        #expect(CodexResetOriginalTextPopover.isReaderWindow(child, attachedTo: parent))
        #expect(!CodexResetOriginalTextPopover.isReaderWindow(parent, attachedTo: parent))
        child.orderOut(nil)
        #expect(!CodexResetOriginalTextPopover.containsReader(at: point, attachedTo: parent))
    }
}
