import Foundation
import Testing
@testable import AgentAlarmCore

@Suite struct TitleServiceTests {
    func makeService(codexHome: URL) -> TitleService {
        TitleService(claude: ClaudeTitleResolver(), codex: CodexTitleResolver(codexHome: codexHome), gemini: GeminiTitleResolver())
    }

    @Test func dispatchesByAgent() throws {
        let service = makeService(codexHome: try makeTempDirectory())
        let claude = AlarmEvent(agent: "claude", kind: .turnComplete, sessionId: "S1", cwd: "/a/B",
                                transcriptPath: try fixtureURL("claude-transcript-titled.jsonl").path)
        #expect(service.resolve(claude).title == "AgentAlarm 设计")
        let gemini = AlarmEvent(agent: "gemini", kind: .turnComplete, sessionId: "S2",
                                transcriptPath: try fixtureURL("gemini-chat-summary.json").path)
        #expect(service.resolve(gemini).origin == .summary)
        let codex = AlarmEvent(agent: "codex", kind: .turnComplete, sessionId: "T404", cwd: "/a/CodexProj")
        #expect(service.resolve(codex) == TitleResolution(title: "CodexProj", origin: .cwd))
        let custom = AlarmEvent(agent: "mybot", kind: .turnComplete, sessionId: "S3", title: "Custom title")
        #expect(service.resolve(custom) == TitleResolution(title: "Custom title", origin: .provided))
        let claudeProvided = AlarmEvent(agent: "claude", kind: .turnComplete, sessionId: "S9", title: "测试提醒")
        #expect(service.resolve(claudeProvided) == TitleResolution(title: "测试提醒", origin: .provided), "任何 agent 自带标题都优先")
    }

    @Test func cachesUntilTranscriptModificationTimeChanges() throws {
        let service = makeService(codexHome: try makeTempDirectory())
        let dir = try makeTempDirectory()
        let file = dir.appendingPathComponent("s.jsonl")
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        func write(_ title: String, mtime: Date) throws {
            try "{\"type\":\"custom-title\",\"customTitle\":\"\(title)\",\"sessionId\":\"S\"}\n".write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: file.path)
        }
        let event = AlarmEvent(agent: "claude", kind: .turnComplete, sessionId: "S", transcriptPath: file.path)
        try write("第一版", mtime: fixedDate)
        #expect(service.resolve(event).title == "第一版")
        try write("第二版", mtime: fixedDate)
        #expect(service.resolve(event).title == "第一版", "同一修改时间应命中缓存")
        try write("第三版", mtime: fixedDate.addingTimeInterval(60))
        #expect(service.resolve(event).title == "第三版", "修改时间变化应重新解析")
    }
}
