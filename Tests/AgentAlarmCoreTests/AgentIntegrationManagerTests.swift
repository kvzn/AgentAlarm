import Foundation
import Testing
@testable import AgentAlarmCore

@Suite struct AgentIntegrationManagerTests {
    @Test func pathsDeriveFromHome() {
        let paths = AgentPaths(home: URL(fileURLWithPath: "/Users/jack"))
        #expect(paths.claudeSettings.path == "/Users/jack/.claude/settings.json")
        #expect(paths.codexHome.path == "/Users/jack/.codex")
        #expect(paths.codexHooks.path == "/Users/jack/.codex/hooks.json")
        #expect(paths.geminiSettings.path == "/Users/jack/.gemini/settings.json")
        #expect(paths.openCodePlugins.path == "/Users/jack/.config/opencode/plugins")
        #expect(paths.cliLink.path == "/Users/jack/.local/bin/agentalarm")
        #expect(paths.appSupport.path == "/Users/jack/Library/Application Support/AgentAlarm")
        #expect(paths.socket.path == "/Users/jack/Library/Application Support/AgentAlarm/agentalarm.sock")
        #expect(paths.backups.path == "/Users/jack/Library/Application Support/AgentAlarm/backups")
    }

    @Test func installsAndUninstallsEveryAgent() throws {
        let home = try makeTempDirectory()
        let manager = AgentIntegrationManager(paths: AgentPaths(home: home))
        for agent in AgentNames.supported {
            #expect(manager.status(agent, verified: false) == .notInstalled, "\(agent)")
            try manager.install(agent)
            let expected: AgentIntegrationStatus = agent == "codex" ? .awaitingTrust : .installed
            #expect(manager.status(agent, verified: false) == expected, "\(agent)")
            #expect(manager.status(agent, verified: true) == .verified, "\(agent)")
            #expect(manager.configFile(agent).map { FileManager.default.fileExists(atPath: $0.path) } == true, "\(agent)")
        }
        let claude = try String(contentsOf: manager.paths.claudeSettings, encoding: .utf8)
        #expect(claude.contains("\(home.path)/.local/bin/agentalarm hook claude"))
        for agent in AgentNames.supported {
            try manager.uninstall(agent)
            #expect(manager.status(agent, verified: true) == .notInstalled, "\(agent)")
        }
        #expect(!FileManager.default.fileExists(atPath: manager.paths.openCodePlugins.appendingPathComponent("agentalarm.ts").path))
    }

    @Test func commentedConfigRequiresManualEditAndSnippetIsUsable() throws {
        let home = try makeTempDirectory()
        let manager = AgentIntegrationManager(paths: AgentPaths(home: home))
        try FileManager.default.createDirectory(at: manager.paths.geminiSettings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "{\n  // my settings\n  \"theme\": \"dark\"\n}".write(to: manager.paths.geminiSettings, atomically: true, encoding: .utf8)
        guard case .manualRequired = manager.status("gemini", verified: false) else {
            Issue.record("expected manualRequired"); return
        }
        #expect(throws: InstallerError.containsComments) { try manager.install("gemini") }
        let snippet = manager.manualSnippet("gemini")
        let parsed = try JSONSerialization.jsonObject(with: Data(snippet.utf8)) as? [String: Any]
        #expect((parsed?["hooks"] as? [String: Any])?["AfterAgent"] != nil)
        #expect(manager.manualSnippet("opencode").hasPrefix(OpenCodePluginInstaller.markerLine))
    }

    @Test func unsupportedAgentThrows() throws {
        let manager = AgentIntegrationManager(paths: AgentPaths(home: try makeTempDirectory()))
        #expect(throws: IntegrationError.unsupportedAgent("cursor")) { try manager.install("cursor") }
        #expect(manager.status("cursor", verified: false) == .notInstalled)
        #expect(manager.configFile("cursor") == nil)
    }
}
