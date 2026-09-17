import Foundation
import Testing
@testable import AgentAlarmCore

@Suite struct GeminiAdapterTests {
    let adapter = GeminiAdapter()
    let context = AdapterContext(now: Date(timeIntervalSince1970: 1_789_600_000))

    @Test func afterAgentBecomesTurnComplete() throws {
        let event = try #require(adapter.map(payload: try fixtureJSON("gemini-after-agent.json"), context: context))
        #expect(event.agent == "gemini")
        #expect(event.kind == .turnComplete)
        #expect(event.sessionId == "session-2026-09-17T03-00-abcd1234")
        #expect(event.message == "I fixed the bug in main.swift and added a test.")
        #expect(event.transcriptPath?.hasSuffix(".json") == true)
        #expect(event.source.hookEventName == "AfterAgent")
    }

    @Test func notificationBecomesNeedsPermission() throws {
        let event = try #require(adapter.map(payload: try fixtureJSON("gemini-notification.json"), context: context))
        #expect(event.kind == .needsPermission)
        #expect(event.message == "Gemini wants to run: npm test")
        #expect(event.source.notificationType == "ToolPermission")
    }

    @Test func beforeAgentSessionEndAndUnknown() throws {
        var payload = try fixtureJSON("gemini-after-agent.json")
        payload["hook_event_name"] = "BeforeAgent"
        #expect(adapter.map(payload: payload, context: context)?.kind == .resumed)
        payload["hook_event_name"] = "SessionEnd"
        #expect(adapter.map(payload: payload, context: context)?.kind == .ended)
        payload["hook_event_name"] = "AfterTool"
        #expect(adapter.map(payload: payload, context: context) == nil)
    }
}
