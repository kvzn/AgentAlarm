import Foundation
import Testing
@testable import AgentAlarmCore

@Suite struct OpenCodePluginInstallerTests {
    let cli = "/Users/jack/.local/bin/agentalarm"

    @Test func sourceHasMarkerCliPathAndEvents() {
        let source = OpenCodePluginInstaller.pluginSource(cliPath: cli)
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.first == Substring(OpenCodePluginInstaller.markerLine))
        #expect(source.contains("const CLI = \"/Users/jack/.local/bin/agentalarm\""))
        for event in ["session.idle", "permission.asked", "question.asked", "session.status"] {
            #expect(source.contains("\"\(event)\""))
        }
        for kind in ["turn_complete", "needs_permission", "needs_input", "resumed"] {
            #expect(source.contains("\"\(kind)\""))
        }
        #expect(source.contains("hook opencode --payload"))
        #expect(source.contains("parentID"))
    }

    @Test func installUninstallRoundTrip() throws {
        let dir = try makeTempDirectory().appendingPathComponent("plugins")
        let installer = OpenCodePluginInstaller()
        #expect(!installer.isInstalled(pluginsDirectory: dir))
        try installer.install(cliPath: cli, pluginsDirectory: dir)
        #expect(installer.isInstalled(pluginsDirectory: dir))
        let file = dir.appendingPathComponent(OpenCodePluginInstaller.fileName)
        #expect(try String(contentsOf: file, encoding: .utf8) == OpenCodePluginInstaller.pluginSource(cliPath: cli))
        try installer.uninstall(pluginsDirectory: dir)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func uninstallKeepsForeignFile() throws {
        let dir = try makeTempDirectory().appendingPathComponent("plugins")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent(OpenCodePluginInstaller.fileName)
        try "// someone else's plugin\nexport const X = 1\n".write(to: file, atomically: true, encoding: .utf8)
        let installer = OpenCodePluginInstaller()
        #expect(!installer.isInstalled(pluginsDirectory: dir))
        try installer.uninstall(pluginsDirectory: dir)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }
}
