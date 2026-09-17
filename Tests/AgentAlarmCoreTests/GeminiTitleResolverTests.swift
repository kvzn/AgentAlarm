import Foundation
import Testing
@testable import AgentAlarmCore

@Suite struct GeminiTitleResolverTests {
    func event(_ path: String?) -> AlarmEvent {
        AlarmEvent(agent: "gemini", kind: .turnComplete, sessionId: "S", cwd: "/Users/jack/Workspaces/Proj", transcriptPath: path)
    }

    @Test func usesSummary() throws {
        let r = GeminiTitleResolver().resolve(event(try fixtureURL("gemini-chat-summary.json").path))
        #expect(r == TitleResolution(title: "Fix login crash and add regression test", origin: .summary))
    }

    @Test func fallsBackToFirstUserMessageParts() throws {
        let r = GeminiTitleResolver().resolve(event(try fixtureURL("gemini-chat-nosummary.json").path))
        #expect(r == TitleResolution(title: "重构支付模块", origin: .firstMessage))
    }

    @Test func missingOrBrokenFileFallsBack() throws {
        #expect(GeminiTitleResolver().resolve(event("/nonexistent.json")).origin == .cwd)
        let dir = try makeTempDirectory()
        let broken = dir.appendingPathComponent("broken.json")
        try "not json".write(to: broken, atomically: true, encoding: .utf8)
        #expect(GeminiTitleResolver().resolve(event(broken.path)) == TitleResolution(title: "Proj", origin: .cwd))
    }
}
