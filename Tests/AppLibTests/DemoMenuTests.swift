import Testing
import AppKit
import Shared
@testable import AppLib

@MainActor
struct DemoMenuTests {
    private func menu(_ viewModel: NotchViewModel) -> NSMenu {
        StatusBarMenu(updateChecker: UpdateChecker(checkInterval: 60), downloader: UpdateDownloader(),
            demoViewModel: viewModel).build()
    }

    @Test func menuReflectsActiveModeAndPermitsExit() throws {
        let viewModel = NotchViewModel(sessionStore: SessionStore(),
            demoController: DemoSessionController(cycleInterval: .seconds(3600)))
        let off = try #require(menu(viewModel).items.first { $0.title == "Demo mode" })
        #expect(off.state == .off)
        #expect(off.isEnabled)
        #expect(viewModel.startDemo())
        let on = try #require(menu(viewModel).items.first { $0.title == "Demo mode" })
        #expect(on.state == .on)
        #expect(on.isEnabled)
        viewModel.stopDemo()
    }

    @Test func realAttentionDisablesStartingDemo() throws {
        let live = SessionStore()
        live.sessions["waiting"] = SessionInfo(id: "waiting", cwd: nil, state: .waiting)
        let viewModel = NotchViewModel(sessionStore: live)
        let item = try #require(menu(viewModel).items.first { $0.title == "Demo mode" })
        #expect(!item.isEnabled)
        #expect(item.state == .off)
    }

    @Test func appKitValidationKeepsDemoDisabledDuringRealAttention() throws {
        _ = NSApplication.shared
        let live = SessionStore()
        live.sessions["waiting"] = SessionInfo(id: "waiting", cwd: nil, state: .waiting)
        let viewModel = NotchViewModel(sessionStore: live)
        let builder = StatusBarMenu(updateChecker: UpdateChecker(checkInterval: 60), downloader: UpdateDownloader(),
            demoViewModel: viewModel)
        let menu = builder.build()
        menu.update()
        let item = try #require(menu.items.first { $0.title == "Demo mode" })
        #expect(!item.isEnabled)
        #expect(item.action == nil)
        #expect(item.target == nil)
        withExtendedLifetime(builder) {}
    }
}
