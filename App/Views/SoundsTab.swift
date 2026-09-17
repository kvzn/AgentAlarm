import AgentAlarmCore
import SwiftUI

struct SoundsTab: View {
    @Environment(AppModel.self) private var model
    private let sounds = SoundPlayer.systemSoundNames()
    private let voices = SpeechQueue.availableVoices()

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section("提示音") {
                soundRow("完成", $settings.soundComplete)
                soundRow("需要授权", $settings.soundPermission)
                soundRow("向你提问", $settings.soundInput)
                Slider(value: $settings.soundVolume, in: 0...1) { Text("音量") }
            }
            Section("语音") {
                Picker("语音", selection: $settings.speechVoice) {
                    Text("自动（中文）").tag("")
                    ForEach(voices, id: \.id) { voice in Text(voice.label).tag(voice.id) }
                }
                Slider(value: $settings.speechRate, in: 0.3...0.7) { Text("语速") }
                Button("试听语音") {
                    model.previewSpeech(SpeechComposer.sentence(for: SpeechItem(agent: "claude", title: "AgentAlarm 设计", kind: .turnComplete)))
                }
            }
            Section("系统横幅") {
                Toggle("发送系统通知横幅，点击横幅跳回宿主应用", isOn: $settings.bannerEnabled)
                if !model.bannerAuthorized {
                    Text("系统通知权限未授予，横幅不会显示；请在 系统设置 → 通知 中允许 AgentAlarm。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func soundRow(_ label: String, _ selection: Binding<String>) -> some View {
        HStack {
            Picker(label, selection: selection) {
                ForEach(sounds, id: \.self) { Text($0).tag($0) }
            }
            Button("试听") { model.previewSound(selection.wrappedValue) }
        }
    }
}
