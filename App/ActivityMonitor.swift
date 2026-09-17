import AgentAlarmCore
import AppKit
import CoreGraphics

@MainActor
enum ActivityMonitor {
    static func snapshot() -> ActivityState {
        let idle = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: ~0)!)
        return ActivityState(frontmostBundleId: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
                             secondsSinceUserInput: idle)
    }
}
