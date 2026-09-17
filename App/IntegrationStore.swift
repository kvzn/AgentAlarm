import AgentAlarmCore
import Foundation
import Observation
import OSLog

@MainActor @Observable
final class IntegrationStore {
    private(set) var statuses: [String: AgentIntegrationStatus] = [:]
    private(set) var symlinkStatus: SymlinkStatus = .missing
    var lastError: String?

    @ObservationIgnored let manager: AgentIntegrationManager
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let symlinks = SymlinkInstaller()
    @ObservationIgnored private let logger = Logger(subsystem: "com.jack.agentalarm", category: "installer")

    // CLI 嵌在 Contents/Helpers/：大小写不敏感的卷上 Contents/MacOS/agentalarm 会和 App 可执行文件撞名。
    var cliTarget: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/agentalarm") }

    init(manager: AgentIntegrationManager, settings: AppSettings) {
        self.manager = manager
        self.settings = settings
    }

    func refresh() {
        for agent in AgentNames.supported {
            statuses[agent] = manager.status(agent, verified: settings.isVerified(agent))
        }
        symlinkStatus = symlinks.status(link: manager.paths.cliLink, expectedTarget: cliTarget)
    }

    func repairSymlink() {
        do {
            if try symlinks.ensure(link: manager.paths.cliLink, target: cliTarget) {
                logger.info("symlink repaired -> \(self.cliTarget.path, privacy: .public)")
            }
        } catch {
            lastError = "无法创建 ~/.local/bin/agentalarm：\(error)"
            logger.error("symlink failed: \(String(describing: error), privacy: .public)")
        }
        refresh()
    }

    func setEnabled(_ agent: String, _ enabled: Bool) {
        let name = AgentNames.displayName(for: agent)
        do {
            if enabled {
                try manager.install(agent)
                logger.info("installed \(agent, privacy: .public)")
            } else {
                try manager.uninstall(agent)
                settings.clearVerified(agent)
                logger.info("uninstalled \(agent, privacy: .public)")
            }
            lastError = nil
        } catch InstallerError.containsComments {
            lastError = "\(name) 的配置文件含注释，请用下方片段手动添加"
        } catch {
            lastError = "\(name) 接入失败：\(error)，原文件未改动，备份目录 \(manager.paths.backups.path)"
            logger.error("install \(agent, privacy: .public) failed: \(String(describing: error), privacy: .public)")
        }
        refresh()
    }

    func isEnabled(_ agent: String) -> Bool {
        switch statuses[agent] {
        case .installed, .awaitingTrust, .verified: return true
        default: return false
        }
    }

    func snippet(_ agent: String) -> String { manager.manualSnippet(agent) }

    func configPath(_ agent: String) -> String { manager.configFile(agent)?.path ?? "" }
}
