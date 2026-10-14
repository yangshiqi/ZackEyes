import Testing
import Foundation
import Shared
@testable import AppLib

@MainActor
struct DemoSessionControllerTests {
    @Test func initialFleetHasBothAgentsAndEveryGroup() {
        let demo = DemoSessionController(cycleInterval: .seconds(3600))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        demo.start(at: now)
        #expect(demo.isActive)
        #expect(demo.store.sessions.count == 4)
        #expect(Set(demo.store.sessions.values.map(\.agent)) == [.claude, .codex])
        #expect(demo.store.sessions.values.allSatisfy { $0.source == .demo })
        #expect(Set(demo.store.sessions.values.map(\.state)) == [.working, .waiting, .idle])
        #expect(demo.store.sessions.values.allSatisfy { $0.claudePid == nil && $0.transcriptPath == nil })
        demo.stop()
    }

    @Test func phasesExposeAnAnswerableChoiceAndReturnToInitialState() {
        let demo = DemoSessionController(cycleInterval: .seconds(3600))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        demo.start(at: now)
        demo.advance(at: now.addingTimeInterval(6))
        let choice = demo.store.sessions.values.flatMap(\.pendingPermissions).first { $0.isAskUserQuestion }
        #expect(choice?.answerableFromNotch == true)
        #expect(choice?.questions.count == 1)
        demo.advance(at: now.addingTimeInterval(12))
        #expect(demo.store.sessions.values.contains { $0.agent == .codex && $0.state == .waiting })
        demo.advance(at: now.addingTimeInterval(18))
        #expect(demo.store.sessions["zackeyes-demo-docs"]?.pendingPermission?.toolName == "Write")
        demo.stop()
    }

    @Test func stopDiscardsRequestsAndLatePhasesCannotResurrectThem() {
        let demo = DemoSessionController(cycleInterval: .seconds(3600))
        demo.start()
        let oldRequest = demo.store.sessions["zackeyes-demo-docs"]?.pendingPermission?.id
        demo.start()
        #expect(demo.store.sessions["zackeyes-demo-docs"]?.pendingPermission?.id == oldRequest)
        demo.stop()
        demo.advance(at: Date())
        #expect(!demo.isActive)
        #expect(demo.store.sessions.isEmpty)
        demo.start()
        #expect(demo.store.sessions["zackeyes-demo-docs"]?.pendingPermission?.id != oldRequest)
        demo.stop()
    }
}
