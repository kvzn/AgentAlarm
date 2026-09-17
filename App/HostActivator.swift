import AgentAlarmCore
import AppKit

/// 优先按 pid 激活，进程已退出则按 bundle id 找同类运行中的应用。
@MainActor
enum HostActivator {
    @discardableResult
    static func activate(_ host: HostInfo?) -> Bool {
        guard let host else { return false }
        if let app = NSRunningApplication(processIdentifier: host.pid), app.bundleIdentifier == host.bundleId {
            return app.activate()
        }
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == host.bundleId }) {
            return app.activate()
        }
        return false
    }
}
