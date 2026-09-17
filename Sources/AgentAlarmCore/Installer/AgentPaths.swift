import Foundation

/// 所有依赖 HOME 的路径集中在这里，测试时用临时目录替换。
public struct AgentPaths: Sendable, Equatable {
    public var home: URL
    public var claudeSettings: URL
    public var codexHome: URL
    public var codexHooks: URL
    public var geminiSettings: URL
    public var openCodePlugins: URL
    public var cliLink: URL
    public var appSupport: URL
    public var socket: URL
    public var backups: URL

    public init(home: URL) {
        self.home = home
        claudeSettings = home.appendingPathComponent(".claude/settings.json")
        codexHome = home.appendingPathComponent(".codex")
        codexHooks = codexHome.appendingPathComponent("hooks.json")
        geminiSettings = home.appendingPathComponent(".gemini/settings.json")
        openCodePlugins = home.appendingPathComponent(".config/opencode/plugins")
        cliLink = home.appendingPathComponent(".local/bin/agentalarm")
        appSupport = home.appendingPathComponent("Library/Application Support/AgentAlarm")
        socket = appSupport.appendingPathComponent("agentalarm.sock")
        backups = appSupport.appendingPathComponent("backups")
    }

    public static var standard: AgentPaths {
        AgentPaths(home: FileManager.default.homeDirectoryForCurrentUser)
    }
}
