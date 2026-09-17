import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppModel.shared.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.stop()
    }
}

struct MenuBarLabel: View {
    let count: Int
    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: count > 0 ? "bell.badge.fill" : "bell")
            if count > 0 { Text("\(count)") }
        }
    }
}

@main
struct AgentAlarmApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContent().environment(model)
        } label: {
            MenuBarLabel(count: model.waiting.count)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView().environment(model)
        }
    }
}
