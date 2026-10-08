import Foundation
import Testing
import Shared
@testable import AppLib

@MainActor
struct ClaudeMetadataTests {
    private func send(_ type: String, _ fields: String = "", to store: SessionStore) throws {
        let text = "{\"_bridge_event\":\"\(type)\",\"session_id\":\"s\"\(fields.isEmpty ? "" : "," + fields)}"
        let event = try JSONDecoder().decode(BridgeEvent.self, from: Data(text.utf8))
        // Exercise the pending-event Codable round trip, including explicit null.
        store.handleEvent(try JSONDecoder().decode(BridgeEvent.self, from: JSONEncoder().encode(event)))
    }

    @Test func snapshotsAndPatchHooksFollowEffectiveEffort() throws {
        let store = SessionStore()
        try send("StatusLine", #""model":{"id":"claude-opus-5-5","display_name":"Opus 5.5"},"effort":{"level":"high"}"#, to: store)
        #expect(store.sessions["s"]?.reasoningEffort == "high")
        try send("PreToolUse", #""tool_name":"Read","effort":{"level":"xhigh"}"#, to: store)
        #expect(store.sessions["s"]?.reasoningEffort == "xhigh")
        try send("PostToolUse", to: store)
        #expect(store.sessions["s"]?.reasoningEffort == "xhigh")
        try send("StatusLine", #""model":{"display_name":"Opus 5.5"}"#, to: store)
        #expect(store.sessions["s"]?.reasoningEffort == nil)
        try send("Stop", #""effort":{"level":"max"}"#, to: store)
        #expect(store.sessions["s"]?.reasoningEffort == "max")
        try send("PreToolUse", #""effort":null"#, to: store)
        #expect(store.sessions["s"]?.reasoningEffort == nil)
    }

    @Test func childMetadataNeverOverwritesParentAndInvalidLevelsHide() throws {
        let store = SessionStore()
        try send("SessionStart", #""model":"claude-fable-5-1","effort":{"level":"high"}"#, to: store)
        #expect(store.sessions["s"]?.reasoningEffort == "high")
        try send("SubagentStop", #""agent_id":"child","effort":{"level":"low"},"model":{"display_name":"Sonnet 5.5"}"#, to: store)
        #expect(store.sessions["s"]?.reasoningEffort == "high")
        #expect(store.sessions["s"]?.modelDisplayName == "Fable 5.1")
        for invalid in [#"{"level":"ultra"}"#, #"{"level":99}"#, #""high""#, #"{}"#] {
            try send("PreToolUse", "\"effort\":\(invalid)", to: store)
            #expect(store.sessions["s"]?.reasoningEffort == nil)
        }
    }

    @Test func modelSwitchClearsOldEffortUntilObservedAgain() throws {
        let store = SessionStore()
        try send("StatusLine", #""model":{"display_name":"Opus 5.5"},"effort":{"level":"high"}"#, to: store)
        try send("PostModelSwitch", #""to_model":"claude-fable-5-1""#, to: store)
        #expect(store.sessions["s"]?.modelDisplayName == "Fable 5.1")
        #expect(store.sessions["s"]?.reasoningEffort == nil)
        try send("PreToolUse", #""effort":{"level":"medium"}"#, to: store)
        #expect(store.sessions["s"]?.reasoningEffort == "medium")
    }
    @Test func compactRestartPreservesObservedMetadataAndUnknownModelStillHasEffort() throws {
        let store = SessionStore()
        try send("PreToolUse", #""effort":{"level":"high"}"#, to: store)
        #expect(store.sessions["s"]?.modelDisplayName == nil)
        #expect(store.sessions["s"]?.reasoningEffort == "high")
        try send("StatusLine", #""model":{"display_name":"Opus 5.5"},"effort":{"level":"xhigh"},"cost":{"total_cost_usd":2}"#, to: store)
        try send("SessionStart", #""source":"compact""#, to: store)
        #expect(store.sessions["s"]?.modelDisplayName == "Opus 5.5")
        #expect(store.sessions["s"]?.reasoningEffort == "xhigh")
        #expect(store.sessions["s"]?.totalCostUSD == 2)
    }

}
