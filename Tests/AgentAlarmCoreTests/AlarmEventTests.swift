import Foundation
import Testing
@testable import AgentAlarmCore

@Suite struct AlarmEventTests {
    @Test func roundTripsThroughSingleLineJSON() throws {
        let event = AlarmEvent(
            id: "E1", agent: "claude", kind: .turnComplete, sessionId: "S1",
            turnId: nil, cwd: "/Users/jack/Workspaces/AgentAlarm",
            transcriptPath: "/Users/jack/.claude/projects/x/S1.jsonl",
            title: nil, message: "done",
            host: HostInfo(bundleId: "com.anthropic.claudefordesktop", pid: 42, name: "Claude"),
            timestamp: Date(timeIntervalSince1970: 1_789_603_200),
            source: EventSource(hookEventName: "Stop", notificationType: nil, entrypoint: "claude-desktop"))
        let data = try EventCoding.encode(event)
        let line = try #require(String(data: data, encoding: .utf8))
        #expect(!line.contains("\n"))
        #expect(line.hasPrefix("{\"agent\":\"claude\""))
        #expect(line.contains("\"kind\":\"turn_complete\""))
        #expect(line.contains("\"timestamp\":\"2026-09-17T"))
        let decoded = try EventCoding.decode(data)
        #expect(decoded == event)
    }

    @Test func defaultsFillIdVersionAndTimestamp() {
        let event = AlarmEvent(agent: "codex", kind: .needsPermission, sessionId: "S2")
        #expect(event.v == 1)
        #expect(!event.id.isEmpty)
        #expect(abs(event.timestamp.timeIntervalSinceNow) < 5)
        #expect(event.source == EventSource())
    }

    @Test func alertingKinds() {
        #expect(EventKind.turnComplete.isAlerting)
        #expect(EventKind.needsPermission.isAlerting)
        #expect(EventKind.needsInput.isAlerting)
        #expect(EventKind.idleReminder.isAlerting)
        #expect(!EventKind.resumed.isAlerting)
        #expect(!EventKind.ended.isAlerting)
    }

    @Test func displayNames() {
        #expect(AgentNames.displayName(for: "claude") == "Claude Code")
        #expect(AgentNames.displayName(for: "codex") == "Codex")
        #expect(AgentNames.displayName(for: "gemini") == "Gemini CLI")
        #expect(AgentNames.displayName(for: "opencode") == "OpenCode")
        #expect(AgentNames.displayName(for: "MyBot") == "MyBot")
    }

    @Test func decodeRejectsUnknownKind() {
        let bad = Data("{\"v\":1,\"id\":\"x\",\"agent\":\"a\",\"kind\":\"nope\",\"sessionId\":\"s\",\"timestamp\":\"2026-09-17T00:00:00Z\",\"source\":{}}".utf8)
        #expect(throws: (any Error).self) { try EventCoding.decode(bad) }
    }
}
