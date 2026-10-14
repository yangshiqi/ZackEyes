import Foundation
import Combine
import Shared

/// Sample sessions never enter the live store or the app's event pipeline.
@MainActor
public final class DemoSessionController: ObservableObject {
    public let store = SessionStore()
    @Published public private(set) var isActive = false
    private let cycleInterval: Duration
    private var cycleTask: Task<Void, Never>?
    private var phase = 0
    private var generation = UUID()

    public init(cycleInterval: Duration = .seconds(6)) {
        self.cycleInterval = cycleInterval
    }

    deinit { cycleTask?.cancel() }

    public func start(at date: Date = Date()) {
        guard !isActive else { return }
        phase = 0
        generation = UUID()
        store.sessions = fixtures(at: date)
        isActive = true
        let currentGeneration = generation
        let interval = cycleInterval
        cycleTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: interval) } catch { return }
                guard !Task.isCancelled, let self, self.isActive,
                      self.generation == currentGeneration else { return }
                self.advance(at: Date())
            }
        }
    }

    public func stop() {
        guard isActive else { return }
        cycleTask?.cancel()
        cycleTask = nil
        generation = UUID()
        store.sessions = [:]
        isActive = false
    }

    func advance(at date: Date) {
        guard isActive else { return }
        phase = (phase + 1) % 3
        store.sessions = fixtures(at: date)
    }

    private func fixtures(at date: Date) -> [String: SessionInfo] {
        var storefront = session("storefront", project: "Storefront", agent: .claude,
            state: phase == 2 ? .idle : .working, at: date)
        storefront.lastUserPrompt = "Build the product collection page"
        storefront.currentToolName = "Edit"
        storefront.isToolRunning = phase == 0
        storefront.lastAssistantMessage = "The collection page is ready, including its responsive grid."
        storefront.tasks = [TaskItem(id: "layout", subject: "Build responsive product grid", status: "in_progress")]

        var api = session("api", project: "API", agent: .codex, state: .working, at: date)
        api.lastUserPrompt = "Add pagination to the catalog endpoint"
        api.currentToolName = "Bash"
        api.isToolRunning = phase != 2
        api.tasks = [TaskItem(id: "endpoint", subject: "Implement cursor pagination", status: "in_progress")]

        var docs = session("docs", project: "Docs", agent: .claude,
            state: phase == 1 ? .idle : .working, at: date)
        docs.lastUserPrompt = "Write the quick-start guide"
        docs.currentToolName = "Write"
        docs.isToolRunning = phase == 2
        docs.lastAssistantMessage = "The quick-start guide now includes setup and examples."

        var tests = session("tests", project: "Tests", agent: .codex,
            state: phase == 0 ? .idle : .working, at: date)
        tests.lastUserPrompt = "Test the catalog's empty and paginated responses"
        tests.currentToolName = phase == 0 ? nil : "Bash"
        tests.isToolRunning = phase != 0
        tests.lastAssistantMessage = "All catalog tests pass, including empty and paginated responses."
        tests.codexUsageTotals = CodexUsageTotals(input: 24_000, cached: 18_000, output: 2_400)

        if phase == 0 {
            docs.state = .waiting
            docs.pendingPermissions = [permission(tool: "Write", input: ["file_path": "/Demo/Docs/quick-start.md"])]
        } else if phase == 1 {
            storefront.state = .waiting
            storefront.isToolRunning = false
            storefront.pendingPermissions = [PendingPermission(
                toolName: "AskUserQuestion",
                toolInput: ["questions": [[
                    "question": "Which layout should we use?", "header": "Layout", "multiSelect": false,
                    "options": [
                        ["label": "Grid", "description": "Show products in a responsive grid."],
                        ["label": "List", "description": "Show product details in a vertical list."]
                    ]
                ]]], cwd: nil, responder: { _ in }, answerableFromNotch: true)]
        } else {
            api.state = .waiting
            api.pendingPermissions = [permission(tool: "Bash", input: ["command": "swift test"])]
        }
        return Dictionary(uniqueKeysWithValues: [storefront, api, docs, tests].map { ($0.id, $0) })
    }

    private func session(_ key: String, project: String, agent: AgentKind,
                         state: SessionState, at date: Date) -> SessionInfo {
        var session = SessionInfo(id: "zackeyes-demo-\(key)", cwd: "/Demo/\(project)",
            agent: agent, state: state, startedAt: date.addingTimeInterval(-240))
        session.source = .demo
        session.lastActiveAt = date
        session.modelDisplayName = agent == .claude ? "Opus 5.5" : "GPT-6.1 Sol"
        session.reasoningEffort = "medium"
        session.contextWindowSize = 200_000
        session.contextUsedPct = agent == .claude ? 42 : 28
        session.totalCostUSD = agent == .claude ? 0.18 : 0.06
        session.toolCallCount = 8 + phase * 3
        return session
    }

    private func permission(tool: String, input: [String: Any]) -> PendingPermission {
        PendingPermission(toolName: tool, toolInput: input, cwd: nil, responder: { _ in })
    }
}
