import AgentAlarmCore
import SwiftUI

struct GeneralTab: View {
    @Environment(AppModel.self) private var model
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section("启动") {
                Toggle("登录时自动启动 AgentAlarm", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            try LoginItem.setEnabled(enabled)
                            loginError = nil
                        } catch {
                            loginError = "设置失败：\(error.localizedDescription)"
                            launchAtLogin = LoginItem.isEnabled
                        }
                    }
                if let loginError { Text(loginError).foregroundStyle(.red) }
                if let error = model.lastError { Text(error).foregroundStyle(.red) }
            }
            Section("最近事件（最多 100 条）") {
                if model.log.isEmpty {
                    Text("还没有收到事件").foregroundStyle(.secondary)
                }
                ForEach(model.log) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(entry.date.formatted(date: .omitted, time: .standard))  \(AgentNames.displayName(for: entry.agent)) · \(entry.kind.rawValue)")
                        Text("\(entry.title)  →  \(entry.outcome)").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
