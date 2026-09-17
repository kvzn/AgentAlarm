import AgentAlarmCore
import AppKit
import SwiftUI

enum ElapsedFormatter {
    static func string(since date: Date, now: Date = Date()) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 60 { return "刚刚" }
        if seconds < 3600 { return "\(seconds / 60) 分钟" }
        return "\(seconds / 3600) 小时"
    }
}

struct MenuContent: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.waiting.entries.isEmpty {
            Text("没有等待中的会话")
        }
        ForEach(model.waiting.entries) { entry in
            Button(label(for: entry)) { model.select(entry) }
        }
        Divider()
        Button("测试提醒") { model.sendTestAlert() }
        SettingsLink { Text("设置…") }
        Divider()
        Button("退出 AgentAlarm") { NSApp.terminate(nil) }
    }

    private func label(for entry: WaitingEntry) -> String {
        let prefix = entry.seen ? "✓ " : ""
        return "\(prefix)\(AgentNames.displayName(for: entry.agent)) · \(entry.title) · \(SpeechComposer.statusPhrase(entry.kind)) · \(ElapsedFormatter.string(since: entry.updatedAt))"
    }
}
