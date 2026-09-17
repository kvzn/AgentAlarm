import Foundation
import Testing
@testable import AgentAlarmCore

@Suite struct OpenCodeAdapterTests {
    let adapter = OpenCodeAdapter()
    let context = AdapterContext(now: Date(timeIntervalSince1970: 1_789_600_000))

    @Test func idleCarriesTitleAndDirectory() throws {
        let event = try #require(adapter.map(payload: try fixtureJSON("opencode-idle.json"), context: context))
        #expect(event.agent == "opencode")
        #expect(event.kind == .turnComplete)
        #expect(event.sessionId == "ses_7f3a1b2c")
        #expect(event.title == "Add login page")
        #expect(event.cwd == "/Users/jack/Workspaces/LovedVoice")
        #expect(event.message == nil)
        #expect(event.source.hookEventName == "plugin")
    }

    @Test func allKindsAcceptedEmptyTitleBecomesNil() throws {
        for kind in EventKind.allCases {
            var payload = try fixtureJSON("opencode-idle.json")
            payload["kind"] = kind.rawValue
            payload["title"] = ""
            let event = try #require(adapter.map(payload: payload, context: context))
            #expect(event.kind == kind)
            #expect(event.title == nil)
        }
    }

    @Test func unknownKindOrMissingSessionIgnored() throws {
        var payload = try fixtureJSON("opencode-idle.json")
        payload["kind"] = "session.idle"
        #expect(adapter.map(payload: payload, context: context) == nil)
        payload = try fixtureJSON("opencode-idle.json")
        payload["sessionID"] = nil
        #expect(adapter.map(payload: payload, context: context) == nil)
    }

    @Test func registryResolvesSupportedAgents() {
        #expect(AdapterRegistry.adapter(for: "claude")?.agent == "claude")
        #expect(AdapterRegistry.adapter(for: "codex")?.agent == "codex")
        #expect(AdapterRegistry.adapter(for: "gemini")?.agent == "gemini")
        #expect(AdapterRegistry.adapter(for: "opencode")?.agent == "opencode")
        #expect(AdapterRegistry.adapter(for: "cursor") == nil)
    }
}
