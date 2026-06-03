import Testing
import Foundation
@testable import AppLib

/// #78 — Codex per-session cost parity. Codex cards showed context% but no $
/// (totalCostUSD was set only on the Claude statusLine path). These pin:
///  1. the tailer surfacing cumulative token components, and
///  2. SessionStore computing per-session cost from them via an injected price.
@MainActor
struct CodexCostTests {
    private let sid = "s1"
    private let cwd = "/tmp/x"
    private let path = "/tmp/x/rollout.jsonl"

    @Test func tokenCountEventCarriesCumulativeTokens() {
        var pending = ""
        let chunk = #"{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":200,"output_tokens":100,"total_tokens":1300},"last_token_usage":{"total_tokens":50},"model_context_window":250000}}}"# + "\n"
        let events = CodexJsonlTailer.parseTaskLifecycleEvents(
            chunk: chunk, pending: &pending, sessionId: sid, cwd: cwd, transcriptPath: path)
        guard case let .tokenCount(event) = events.first else {
            Issue.record("expected token_count event"); return
        }
        #expect(event.cumulativeInput == 1000)
        #expect(event.cumulativeCached == 200)
        #expect(event.cumulativeOutput == 100)
    }

    @Test func recordsCodexPerSessionCostFromCumulativeTokens() {
        let store = SessionStore()
        store.codexPriceLookup = { model in
            model == "gpt-5.5"
                ? ModelPrice(inputPerToken: 1e-6, outputPerToken: 1e-5,
                             cacheReadPerToken: 1e-7, cacheCreatePerToken: 0)
                : nil
        }
        store.setCodexModelDisplayName(sessionId: sid, cwd: cwd, transcriptPath: nil, displayName: "gpt-5.5")
        store.recordCodexContext(
            sessionId: sid, cwd: cwd, contextUsedPct: 10, contextWindowSize: 100,
            transcriptPath: nil, observedAt: Date(),
            cumulativeInput: 1000, cumulativeCached: 200, cumulativeOutput: 100)
        // uncached = 800; 800*1e-6 + 200*1e-7 + 100*1e-5 = 0.0008 + 0.00002 + 0.001 = 0.00182
        #expect(abs((store.sessions[sid]?.totalCostUSD ?? -1) - 0.00182) < 1e-12)
    }

    @Test func codexCostStaysNilWhenModelUnpriced() {
        let store = SessionStore()
        store.codexPriceLookup = { _ in nil }
        store.setCodexModelDisplayName(sessionId: sid, cwd: cwd, transcriptPath: nil, displayName: "mystery")
        store.recordCodexContext(
            sessionId: sid, cwd: cwd, contextUsedPct: 10, contextWindowSize: 100,
            transcriptPath: nil, observedAt: Date(),
            cumulativeInput: 1000, cumulativeCached: 200, cumulativeOutput: 100)
        #expect(store.sessions[sid]?.totalCostUSD == nil)
    }
}
