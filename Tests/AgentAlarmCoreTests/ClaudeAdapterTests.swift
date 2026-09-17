import Foundation
import Testing
@testable import AgentAlarmCore

@Suite struct ClaudeAdapterTests {
    let adapter = ClaudeAdapter()
    let context = AdapterContext(
        environment: ["CLAUDE_CODE_ENTRYPOINT": "claude-desktop"],
        host: HostInfo(bundleId: "com.anthropic.claudefordesktop", pid: 7, name: "Claude"),
        now: Date(timeIntervalSince1970: 1_789_600_000))

    @Test func stopBecomesTurnComplete() throws {
        let event = try #require(adapter.map(payload: try fixtureJSON("claude-stop.json"), context: context))
        #expect(event.agent == "claude")
        #expect(event.kind == .turnComplete)
        #expect(event.sessionId == "684ec27a-38f2-4acd-8ac6-fa79aaaa0001")
        #expect(event.cwd == "/Users/jack/Workspaces/AgentAlarm")
        #expect(event.transcriptPath?.hasSuffix(".jsonl") == true)
        #expect(event.host?.bundleId == "com.anthropic.claudefordesktop")
        #expect(event.timestamp == context.now)
        #expect(event.source.hookEventName == "Stop")
        #expect(event.source.entrypoint == "claude-desktop")
        #expect(event.title == nil)
        #expect(event.message == nil)
    }

    @Test func subagentStopIsIgnored() throws {
        var payload = try fixtureJSON("claude-stop.json")
        payload["agent_id"] = "agent-123"
        payload["agent_type"] = "Explore"
        #expect(adapter.map(payload: payload, context: context) == nil)
    }

    @Test func notificationTypesMap() throws {
        let base = try fixtureJSON("claude-notification-permission.json")
        let expectations: [(String, EventKind?)] = [
            ("permission_prompt", .needsPermission),
            ("idle_prompt", .idleReminder),
            ("elicitation_dialog", .needsInput),
            ("elicitation_url_dialog", .needsInput),
            ("agent_needs_input", .needsInput),
            ("auth_success", nil),
            ("agent_completed", nil),
        ]
        for (type, kind) in expectations {
            var payload = base
            payload["notification_type"] = type
            let event = adapter.map(payload: payload, context: context)
            #expect(event?.kind == kind, "notification_type \(type)")
            if kind != nil { #expect(event?.source.notificationType == type) }
        }
    }

    @Test func promptSubmitAndSessionEndAreNonAlerting() throws {
        let submit = try #require(adapter.map(payload: try fixtureJSON("claude-user-prompt-submit.json"), context: context))
        #expect(submit.kind == .resumed)
        var end = try fixtureJSON("claude-stop.json")
        end["hook_event_name"] = "SessionEnd"
        end["reason"] = "exit"
        #expect(adapter.map(payload: end, context: context)?.kind == .ended)
    }

    @Test func unknownHookOrMissingSessionIsIgnored() throws {
        var payload = try fixtureJSON("claude-stop.json")
        payload["hook_event_name"] = "PreToolUse"
        #expect(adapter.map(payload: payload, context: context) == nil)
        payload = try fixtureJSON("claude-stop.json")
        payload["session_id"] = nil
        #expect(adapter.map(payload: payload, context: context) == nil)
    }
}
