import Foundation

public enum AgentIntegrationStatus: Equatable, Sendable {
    case notInstalled
    case installed
    case awaitingTrust
    case verified
    case manualRequired(String)
}

public enum IntegrationError: Error, Equatable {
    case unsupportedAgent(String)
}

/// 每个 Agent 的接入、卸载、状态判定与手动片段。
public struct AgentIntegrationManager {
    public var paths: AgentPaths
    private let jsonInstaller: JSONHookInstaller
    private let pluginInstaller: OpenCodePluginInstaller
    private let fileManager: FileManager

    public init(paths: AgentPaths, fileManager: FileManager = .default, timeSource: any TimeSource = SystemTimeSource()) {
        self.paths = paths
        self.fileManager = fileManager
        jsonInstaller = JSONHookInstaller(backupDirectory: paths.backups, fileManager: fileManager, timeSource: timeSource)
        pluginInstaller = OpenCodePluginInstaller(fileManager: fileManager)
    }

    public var cliPath: String { paths.cliLink.path }

    public func configFile(_ agent: String) -> URL? {
        switch agent {
        case "claude": return paths.claudeSettings
        case "codex": return paths.codexHooks
        case "gemini": return paths.geminiSettings
        case "opencode": return paths.openCodePlugins.appendingPathComponent(OpenCodePluginInstaller.fileName)
        default: return nil
        }
    }

    public func install(_ agent: String) throws {
        if agent == "opencode" {
            try pluginInstaller.install(cliPath: cliPath, pluginsDirectory: paths.openCodePlugins)
            return
        }
        guard let template = HookTemplates.template(agent: agent, cliPath: cliPath), let file = configFile(agent) else {
            throw IntegrationError.unsupportedAgent(agent)
        }
        try jsonInstaller.install(hooks: template, marker: HookTemplates.marker(agent: agent), into: file)
    }

    public func uninstall(_ agent: String) throws {
        if agent == "opencode" {
            try pluginInstaller.uninstall(pluginsDirectory: paths.openCodePlugins)
            return
        }
        guard AgentNames.supported.contains(agent), let file = configFile(agent) else {
            throw IntegrationError.unsupportedAgent(agent)
        }
        try jsonInstaller.uninstall(marker: HookTemplates.marker(agent: agent), from: file)
    }

    public func status(_ agent: String, verified: Bool) -> AgentIntegrationStatus {
        let installed: Bool
        if agent == "opencode" {
            installed = pluginInstaller.isInstalled(pluginsDirectory: paths.openCodePlugins)
        } else {
            guard AgentNames.supported.contains(agent), let file = configFile(agent) else { return .notInstalled }
            if fileManager.fileExists(atPath: file.path), jsonInstaller.requiresManualEdit(fileURL: file) {
                return .manualRequired("配置文件含注释，自动改写会丢失注释，请手动粘贴片段")
            }
            installed = jsonInstaller.isInstalled(marker: HookTemplates.marker(agent: agent), in: file)
        }
        guard installed else { return .notInstalled }
        if verified { return .verified }
        return agent == "codex" ? .awaitingTrust : .installed
    }

    public func manualSnippet(_ agent: String) -> String {
        if agent == "opencode" { return OpenCodePluginInstaller.pluginSource(cliPath: cliPath) }
        guard let template = HookTemplates.template(agent: agent, cliPath: cliPath) else { return "" }
        let data = (try? JSONSerialization.data(withJSONObject: ["hooks": template],
                                                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}
