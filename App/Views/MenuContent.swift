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
        Menu(model.isPaused ? "已暂停提醒" : "暂停提醒") {
            Button("15 分钟") { model.pause(minutes: 15) }
            Button("30 分钟") { model.pause(minutes: 30) }
            Button("60 分钟") { model.pause(minutes: 60) }
            Button("直到恢复") { model.pause(minutes: nil) }
            Divider()
            Button("恢复提醒") { model.resume() }.disabled(!model.isPaused)
        }
        Button("测试提醒") { model.sendTestAlert() }
        Button("设置…") { model.openSettings() }
        Divider()
        Button("退出 AgentAlarm") { NSApp.terminate(nil) }
    }

    private func label(for entry: WaitingEntry) -> String {
        let prefix = entry.seen ? "✓ " : ""
        return "\(prefix)\(AgentNames.displayName(for: entry.agent)) · \(entry.title) · \(SpeechComposer.statusPhrase(entry.kind)) · \(ElapsedFormatter.string(since: entry.updatedAt))"
    }
}
