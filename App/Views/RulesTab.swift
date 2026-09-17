import SwiftUI

struct RulesTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section("语音抑制") {
                Toggle("宿主应用在前台且我正在操作时不播报语音（仍播提示音）", isOn: $settings.suppressWhenHostActive)
                Stepper("键鼠活跃判定窗口：\(Int(settings.userActiveThreshold)) 秒", value: $settings.userActiveThreshold, in: 3...60, step: 1)
            }
            Section("重复提醒") {
                Toggle("回合结束约 60 秒仍无人回复时再提醒一次", isOn: $settings.repeatReminders)
            }
            Section("静音时段") {
                Toggle("启用静音时段（只更新列表，不出声）", isOn: $settings.quietHoursEnabled)
                DatePicker("开始", selection: minuteBinding($settings.quietStartMinute), displayedComponents: .hourAndMinute)
                DatePicker("结束", selection: minuteBinding($settings.quietEndMinute), displayedComponents: .hourAndMinute)
            }
        }
        .formStyle(.grouped)
    }

    private func minuteBinding(_ minute: Binding<Int>) -> Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(bySettingHour: minute.wrappedValue / 60, minute: minute.wrappedValue % 60, second: 0, of: Date()) ?? Date()
            },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                minute.wrappedValue = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            })
    }
}
