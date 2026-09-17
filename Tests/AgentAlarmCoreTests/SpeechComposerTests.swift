import Testing
@testable import AgentAlarmCore

@Suite struct SpeechComposerTests {
    @Test func singleSentencesFollowTemplate() {
        #expect(SpeechComposer.sentence(for: SpeechItem(agent: "claude", title: "AgentAlarm 设计", kind: .turnComplete)) == "Claude Code，AgentAlarm 设计，已完成")
        #expect(SpeechComposer.sentence(for: SpeechItem(agent: "codex", title: "登录页", kind: .needsPermission)) == "Codex，登录页，需要授权")
        #expect(SpeechComposer.sentence(for: SpeechItem(agent: "gemini", title: "迁移", kind: .needsInput)) == "Gemini CLI，迁移，有问题要问你")
        #expect(SpeechComposer.sentence(for: SpeechItem(agent: "opencode", title: "重构", kind: .idleReminder)) == "OpenCode，重构，还在等你")
    }

    @Test func longTitleTruncatedTo40ForSpeech() {
        let item = SpeechItem(agent: "claude", title: String(repeating: "长", count: 60), kind: .turnComplete)
        let sentence = SpeechComposer.sentence(for: item)
        #expect(sentence == "Claude Code，" + String(repeating: "长", count: 40) + "…，已完成")
    }

    @Test func batchesCoalesce() {
        let items = (1...4).map { SpeechItem(agent: "claude", title: "会话\($0)", kind: .turnComplete) }
        #expect(SpeechComposer.sentence(for: Array(items.prefix(1))) == "Claude Code，会话1，已完成")
        #expect(SpeechComposer.sentence(for: Array(items.prefix(2))) == "有 2 个会话在等待：会话1，会话2")
        #expect(SpeechComposer.sentence(for: Array(items.prefix(3))) == "有 3 个会话在等待：会话1，会话2，会话3")
        #expect(SpeechComposer.sentence(for: items) == "有 4 个会话在等待：会话1，会话2，会话3等")
        #expect(SpeechComposer.sentence(for: []) == "")
    }
}
