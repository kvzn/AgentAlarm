import AgentAlarmCore
import SwiftUI

struct IntegrationsTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let store = model.integrations
        Form {
            if model.menuBarIconHidden {
                Section {
                    Label(AppModel.hiddenIconNotice, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
            }
            Section("Agent 接入") {
                ForEach(AgentNames.supported, id: \.self) { agent in
                    AgentRow(agent: agent, store: store)
                }
            }
            Section("命令行工具") {
                LabeledContent("软链接 ~/.local/bin/agentalarm") { Text(symlinkText(store.symlinkStatus)) }
                LabeledContent("指向") { Text(store.cliTarget.path).font(.caption).textSelection(.enabled) }
                Button("修复软链接") { store.repairSymlink() }
            }
            if let error = store.lastError {
                Text(error).foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .onAppear { store.refresh() }
    }

    private func symlinkText(_ status: SymlinkStatus) -> String {
        switch status {
        case .ok: return "正常"
        case .missing: return "缺失"
        case .wrongTarget(let target): return "指向错误：\(target)"
        case .notASymlink: return "该路径是普通文件，请先手动移走"
        case .dangling(let target): return "目标不存在：\(target)"
        }
    }
}

struct AgentRow: View {
    let agent: String
    let store: IntegrationStore

    private var status: AgentIntegrationStatus { store.statuses[agent] ?? .notInstalled }

    private var manualRequired: Bool {
        if case .manualRequired = status { return true }
        return false
    }

    /// 只有「含注释且尚未写入我们的条目」才需要手动片段；已写入的只需卸载指引。
    private var snippetNeeded: Bool {
        if case .manualRequired(_, false) = status { return true }
        return false
    }

    private var statusText: String {
        switch status {
        case .notInstalled: return "未接入"
        case .installed: return "已接入，等待收到第一条事件"
        case .awaitingTrust: return "已写入 hooks.json，待信任"
        case .verified: return "已验证"
        case .manualRequired(let reason, _): return reason
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: Binding(get: { store.isEnabled(agent) }, set: { store.setEnabled(agent, $0) })) {
                Text(AgentNames.displayName(for: agent))
            }
            .disabled(manualRequired)
            Text("\(statusText) · \(store.configPath(agent))")
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            if case .awaitingTrust = status {
                Text("在任一 Codex 终端会话中运行 /hooks 并信任 AgentAlarm；收到第一条 Codex 事件后自动变为已验证。")
                    .font(.caption)
            }
            if snippetNeeded {
                DisclosureGroup("手动配置片段") {
                    TextEditor(text: .constant(store.snippet(agent)))
                        .font(.system(.caption, design: .monospaced))
                        .frame(height: 160)
                }
            }
        }
    }
}
