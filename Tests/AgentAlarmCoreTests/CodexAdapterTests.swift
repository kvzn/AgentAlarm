import Foundation
import Testing
@testable import AgentAlarmCore

@Suite struct CodexAdapterTests {
    let adapter = CodexAdapter()
    let context = AdapterContext(now: Date(timeIntervalSince1970: 1_789_600_000))

    @Test func stopCarriesLastMessageAndTurnId() throws {
        let event = try #require(adapter.map(payload: try fixtureJSON("codex-stop.json"), context: context))
        #expect(event.agent == "codex")
        #expect(event.kind == .turnComplete)
        #expect(event.sessionId == "01a0ad46-6f14-76c2-9f9e-bfc71b6ea713")
        #expect(event.turnId == "turn-0001")
        #expect(event.message == "Done. I updated the README and ran the tests.")
        #expect(event.transcriptPath?.contains("/.codex/sessions/") == true)
        #expect(event.source.hookEventName == "Stop")
    }

    @Test func longMessageIsTruncatedTo200() throws {
        var payload = try fixtureJSON("codex-stop.json")
        payload["last_assistant_message"] = String(repeating: "a", count: 500)
        let event = try #require(adapter.map(payload: payload, context: context))
        #expect(event.message?.count == 201)
        #expect(event.message?.hasSuffix("…") == true)
    }

    @Test func permissionRequestSummarisesTool() throws {
        let event = try #require(adapter.map(payload: try fixtureJSON("codex-permission-request.json"), context: context))
        #expect(event.kind == .needsPermission)
        #expect(event.message == "Bash: rm -rf build")
        #expect(event.transcriptPath == nil)
    }

    @Test func permissionRequestWithArrayCommandAndWithoutCommand() throws {
        var payload = try fixtureJSON("codex-permission-request.json")
        payload["tool_input"] = ["command": ["git", "push", "--force"]]
        #expect(adapter.map(payload: payload, context: context)?.message == "Bash: git push --force")
        payload["tool_input"] = ["path": "/tmp/x"]
        #expect(adapter.map(payload: payload, context: context)?.message == "Bash")
    }

    @Test func promptSubmitSessionEndAndUnknown() throws {
        var payload = try fixtureJSON("codex-stop.json")
        payload["hook_event_name"] = "UserPromptSubmit"
        #expect(adapter.map(payload: payload, context: context)?.kind == .resumed)
        payload["hook_event_name"] = "SessionEnd"
        #expect(adapter.map(payload: payload, context: context)?.kind == .ended)
        payload["hook_event_name"] = "SubagentStop"
        #expect(adapter.map(payload: payload, context: context) == nil)
    }
}
