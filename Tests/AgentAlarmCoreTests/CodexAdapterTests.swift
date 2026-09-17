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

    /// Codex Desktop 0.155 对每次 Bash 调用都触发 PermissionRequest（含只读命令），与是否弹窗无关，
    /// payload 里也没有可区分的字段，所以它不能作为"等待授权"的信号。
    @Test func permissionRequestIsIgnored() throws {
        #expect(adapter.map(payload: try fixtureJSON("codex-permission-request.json"), context: context) == nil)
        var payload = try fixtureJSON("codex-permission-request.json")
        payload["tool_input"] = ["command": ["git", "push", "--force"]]
        #expect(adapter.map(payload: payload, context: context) == nil)
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
