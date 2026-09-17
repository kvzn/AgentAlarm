import Foundation
import Testing
@testable import AgentAlarmCore

@Suite struct ClaudeTitleResolverTests {
    func event(transcript: String?, cwd: String? = "/Users/jack/Workspaces/AgentAlarm", kind: EventKind = .turnComplete) -> AlarmEvent {
        AlarmEvent(agent: "claude", kind: kind, sessionId: "S", cwd: cwd, transcriptPath: transcript)
    }

    @Test func usesLastCustomTitle() throws {
        let path = try fixtureURL("claude-transcript-titled.jsonl").path
        let r = ClaudeTitleResolver().resolve(event(transcript: path))
        #expect(r.title == "AgentAlarm 设计")
        #expect(r.origin == .customTitle)
        #expect(r.reclassifiedKind == nil)
    }

    @Test func fallsBackToLastPromptFirstLineTruncated() throws {
        let path = try fixtureURL("claude-transcript-untitled.jsonl").path
        let r = ClaudeTitleResolver().resolve(event(transcript: path))
        #expect(r.title == "修复登录页面的崩溃问题")
        #expect(r.origin == .lastPrompt)
    }

    @Test func detectsAskUserQuestionInLastAssistantRecord() throws {
        let path = try fixtureURL("claude-transcript-question.jsonl").path
        let r = ClaudeTitleResolver().resolve(event(transcript: path))
        #expect(r.title == "数据库迁移")
        #expect(r.reclassifiedKind == .needsInput)
    }

    @Test func missingFileFallsBackToCwdName() {
        let r = ClaudeTitleResolver().resolve(event(transcript: "/nonexistent/x.jsonl"))
        #expect(r.title == "AgentAlarm")
        #expect(r.origin == .cwd)
        let r2 = ClaudeTitleResolver().resolve(event(transcript: nil, cwd: nil))
        #expect(r2.title == "Claude Code")
        #expect(r2.origin == .agentName)
    }

    @Test func onlyTailIsReadAndPartialFirstLineDropped() throws {
        let dir = try makeTempDirectory()
        let file = dir.appendingPathComponent("big.jsonl")
        var text = "{\"type\":\"custom-title\",\"customTitle\":\"很早的标题\",\"sessionId\":\"S\"}\n"
        text += "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"" + String(repeating: "长", count: 300_000) + "\"},\"sessionId\":\"S\"}\n"
        text += "{\"type\":\"custom-title\",\"customTitle\":\"最新标题\",\"sessionId\":\"S\"}\n"
        try text.write(to: file, atomically: true, encoding: .utf8)
        let r = ClaudeTitleResolver(maxTailBytes: 64 * 1024).resolve(event(transcript: file.path))
        #expect(r.title == "最新标题")
        #expect(r.origin == .customTitle)
    }

    @Test func providedTitleAndFallback() {
        let with = AlarmEvent(agent: "opencode", kind: .turnComplete, sessionId: "S", cwd: "/x/Proj", title: "Add login")
        #expect(ProvidedTitleResolver.resolve(with) == TitleResolution(title: "Add login", origin: .provided))
        let without = AlarmEvent(agent: "opencode", kind: .turnComplete, sessionId: "S", cwd: "/x/Proj", title: "")
        #expect(ProvidedTitleResolver.resolve(without) == TitleResolution(title: "Proj", origin: .cwd))
    }
}
