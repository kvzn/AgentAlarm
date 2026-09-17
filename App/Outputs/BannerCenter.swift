import AgentAlarmCore
import Foundation
import OSLog
import UserNotifications

@MainActor
final class BannerCenter: NSObject, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    private(set) var authorized = false

    override init() {
        super.init()
        center.delegate = self
    }

    func requestAuthorization() {
        center.requestAuthorization(options: [.alert]) { granted, _ in
            Task { @MainActor in self.authorized = granted }
        }
    }

    func post(event: AlarmEvent, title: String) {
        guard authorized else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(AgentNames.displayName(for: event.agent)) · \(SpeechComposer.statusPhrase(event.kind))"
        content.body = title
        content.sound = nil
        if let host = event.host {
            content.userInfo = ["bundleId": host.bundleId, "pid": Int(host.pid), "name": host.name]
        }
        center.add(UNNotificationRequest(identifier: event.id, content: content, trigger: nil)) { error in
            if let error {
                Logger(subsystem: "com.jack.agentalarm", category: "output").error("banner failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let bundleId = info["bundleId"] as? String else { return }
        let pid = Int32(info["pid"] as? Int ?? 0)
        let name = info["name"] as? String ?? ""
        _ = await MainActor.run { HostActivator.activate(HostInfo(bundleId: bundleId, pid: pid, name: name)) }
    }
}
