import Foundation
import Testing
@testable import AgentAlarmCore

@Suite struct HookTemplatesTests {
    let cli = "/Users/jack/.local/bin/agentalarm"

    func hooks(_ dict: [String: Any], _ event: String) -> [[String: Any]] {
        let groups = dict[event] as? [[String: Any]] ?? []
        return groups.flatMap { $0["hooks"] as? [[String: Any]] ?? [] }
    }

    @Test func claudeTemplate() {
        let t = HookTemplates.claude(cliPath: cli)
        #expect(Set(t.keys) == ["Stop", "Notification", "UserPromptSubmit", "SessionEnd"])
        let stop = hooks(t, "Stop")[0]
        #expect(stop["command"] as? String == "/Users/jack/.local/bin/agentalarm hook claude")
        #expect(stop["async"] as? Bool == true)
        #expect(stop["timeout"] as? Int == 5)
        let notif = (t["Notification"] as? [[String: Any]])?[0]
        #expect(notif?["matcher"] as? String == "permission_prompt|idle_prompt|elicitation_dialog|elicitation_url_dialog|agent_needs_input")
        let end = hooks(t, "SessionEnd")[0]
        #expect(end["timeout"] as? Int == 1)
        #expect(end["async"] == nil)
    }

    @Test func codexTemplate() {
        let t = HookTemplates.codex(cliPath: cli)
        #expect(Set(t.keys) == ["Stop", "PermissionRequest", "UserPromptSubmit", "SessionEnd"])
        // Codex 0.146 不支持 async hooks，模板必须全部同步
        for event in ["Stop", "PermissionRequest", "UserPromptSubmit", "SessionEnd"] {
            #expect(hooks(t, event)[0]["async"] == nil, "\(event)")
        }
        #expect(hooks(t, "Stop")[0]["timeout"] as? Int == 5)
        #expect(hooks(t, "SessionEnd")[0]["timeout"] as? Int == 2)
        #expect((t["Stop"] as? [[String: Any]])?[0]["matcher"] == nil)
    }

    @Test func geminiTemplateUsesMilliseconds() {
        let t = HookTemplates.gemini(cliPath: cli)
        #expect(Set(t.keys) == ["AfterAgent", "Notification", "BeforeAgent", "SessionEnd"])
        for event in t.keys {
            #expect(hooks(t, event)[0]["timeout"] as? Int == 3000)
            #expect(hooks(t, event)[0]["command"] as? String == "/Users/jack/.local/bin/agentalarm hook gemini")
        }
    }

    @Test func markerAndQuoting() {
        #expect(HookTemplates.marker(agent: "codex") == "/.local/bin/agentalarm hook codex")
        #expect(HookTemplates.command(cliPath: "/Users/some one/.local/bin/agentalarm", agent: "claude") == "'/Users/some one/.local/bin/agentalarm' hook claude")
        #expect(HookTemplates.template(agent: "opencode", cliPath: cli) == nil)
        #expect(HookTemplates.template(agent: "gemini", cliPath: cli)?.count == 4)
    }
}
