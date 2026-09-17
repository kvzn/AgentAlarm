import Foundation
import ServiceManagement

enum LoginItemError: LocalizedError {
    case requiresApproval
    var errorDescription: String? { "需要在 系统设置 → 通用 → 登录项 中允许 AgentAlarm" }
}

@MainActor
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
            if SMAppService.mainApp.status == .requiresApproval { throw LoginItemError.requiresApproval }
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
