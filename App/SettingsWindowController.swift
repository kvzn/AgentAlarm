import AppKit
import SwiftUI

/// 自己托管设置窗口，不依赖 SwiftUI 的 Settings 场景：这样菜单栏图标被隐藏时也能靠
/// `agentalarm settings` 或横幅打开，且窗口一定会被创建并置顶。
@MainActor
final class SettingsWindowController {
    private var window: NSWindow?

    func show(model: AppModel) {
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView().environment(model))
            let newWindow = NSWindow(contentViewController: hosting)
            newWindow.title = "AgentAlarm 设置"
            newWindow.styleMask = [.titled, .closable, .miniaturizable]
            newWindow.isReleasedWhenClosed = false
            newWindow.center()
            window = newWindow
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }
}
