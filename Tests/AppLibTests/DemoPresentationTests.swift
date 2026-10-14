import Testing
import Foundation
import Combine
import Shared
@testable import AppLib

@MainActor
struct DemoPresentationTests {
    private func model(_ live: SessionStore = SessionStore()) -> NotchViewModel {
        NotchViewModel(sessionStore: live, demoController: DemoSessionController(cycleInterval: .seconds(3600)))
    }

    @Test func realIngestionContinuesAndExitRestoresItsLatestState() {
        let live = SessionStore()
        let viewModel = model(live)
        #expect(viewModel.startDemo())
        #expect(viewModel.presentationStore !== live)
        live.handleEvent(BridgeEvent(bridgeEvent: "SessionStart", sessionId: "real", cwd: "/tmp/real"))
        live.handleEvent(BridgeEvent(bridgeEvent: "PreToolUse", sessionId: "real", toolName: "Read"))
        #expect(live.sessions.count == 1)
        #expect(viewModel.presentationStore.sessions.count == 4)
        viewModel.stopDemo()
        #expect(viewModel.presentationStore === live)
        #expect(viewModel.primarySession?.currentToolName == "Read")
    }

    @Test(arguments: ["waiting", "error", "permission"])
    func realAttentionPreventsStartingDemo(kind: String) {
        let live = SessionStore()
        var session = SessionInfo(id: "real", cwd: "/tmp", state: .working)
        if kind == "waiting" { session.state = .waiting }
        if kind == "error" { session.errorMessage = "Sample real error" }
        if kind == "permission" {
            session.pendingPermissions = [PendingPermission(toolName: "Write", toolInput: [:], cwd: "/tmp", responder: { _ in })]
        }
        live.sessions[session.id] = session
        let viewModel = model(live)
        #expect(!viewModel.canStartDemo)
        #expect(!viewModel.startDemo())
        #expect(viewModel.presentationStore === live)
    }

    @Test func livePermissionInterruptsDemoWithoutAnsweringTheRealBridge() async throws {
        let live = SessionStore()
        let viewModel = model(live)
        #expect(viewModel.startDemo())
        let response = Box<BridgeResponse>()
        let pending = PendingPermission(toolName: "Write", toolInput: [:], cwd: "/tmp", responder: { response.value = $0 })
        live.handlePermissionRequest(sessionId: "real", permission: pending)
        let deadline = ContinuousClock.now + .seconds(10)
        while viewModel.isDemoActive, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!viewModel.isDemoActive)
        #expect(viewModel.presentationStore === live)
        #expect(response.value == nil)
        viewModel.approve(sessionId: "real", requestId: pending.id)
        guard case .permission = response.value else { Issue.record("Real permission was lost"); return }
    }

    @Test func demoActionsAndTerminalClicksNeverTouchLiveSessions() throws {
        let live = SessionStore()
        live.handleEvent(BridgeEvent(bridgeEvent: "SessionStart", sessionId: "real", cwd: "/tmp"))
        let viewModel = model(live)
        #expect(viewModel.startDemo())
        let fake = try #require(viewModel.presentationStore.sessions["zackeyes-demo-docs"])
        let pending = try #require(fake.pendingPermission)
        viewModel.approve(sessionId: fake.id, requestId: pending.id)
        #expect(viewModel.presentationStore.sessions[fake.id]?.pendingPermission == nil)
        #expect(live.sessions.count == 1)
        viewModel.activateTerminal(for: fake)
        #expect(live.sessions[fake.id] == nil)
        viewModel.demoController.advance(at: Date())
        let question = try #require(viewModel.presentationStore.sessions["zackeyes-demo-storefront"]?.pendingPermission)
        #expect(viewModel.submitAskUQAnswer(sessionId: "zackeyes-demo-storefront", requestId: question.id,
            answers: ["Which layout should we use?": "Grid"]))
        #expect(live.sessions.count == 1)
        viewModel.stopDemo()
    }

    @Test func forwardsDemoChangesAndNotifiesEachModeTransitionOnce() {
        let viewModel = model()
        let count = Box<Int>(); count.value = 0
        let modes = Box<[Bool]>(); modes.value = []
        let subscription = viewModel.objectWillChange.sink { count.value = (count.value ?? 0) + 1 }
        viewModel.onDemoChanged = { modes.value?.append($0) }
        #expect(viewModel.startDemo())
        #expect(viewModel.startDemo())
        let before = count.value ?? 0
        viewModel.demoController.advance(at: Date())
        #expect((count.value ?? 0) > before)
        viewModel.stopDemo(); viewModel.stopDemo()
        #expect(modes.value == [true, false])
        withExtendedLifetime(subscription) {}
    }
}
