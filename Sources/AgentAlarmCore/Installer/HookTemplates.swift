import Foundation

/// 各 Agent 的 hook 配置模板。返回值是要写入配置文件 "hooks" 键下的字典。
public enum HookTemplates {
    public static func marker(agent: String) -> String { "/.local/bin/agentalarm hook \(agent)" }

    public static func command(cliPath: String, agent: String) -> String {
        "\(shellQuoted(cliPath)) hook \(agent)"
    }

    static func shellQuoted(_ path: String) -> String {
        let safe = path.allSatisfy { $0.isLetter || $0.isNumber || "/._-".contains($0) }
        if safe { return path }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static func claude(cliPath: String) -> [String: Any] {
        let cmd = command(cliPath: cliPath, agent: "claude")
        let asyncHook: [String: Any] = ["type": "command", "command": cmd, "async": true, "timeout": 5]
        let endHook: [String: Any] = ["type": "command", "command": cmd, "timeout": 1]
        return [
            "Stop": [["matcher": "", "hooks": [asyncHook]]],
            "Notification": [["matcher": "permission_prompt|idle_prompt|elicitation_dialog|elicitation_url_dialog|agent_needs_input",
                              "hooks": [asyncHook]]],
            "UserPromptSubmit": [["matcher": "", "hooks": [asyncHook]]],
            "SessionEnd": [["matcher": "", "hooks": [endHook]]],
        ]
    }

    /// Codex 0.146 实测会跳过带 `async` 的 hook（"async hooks are not supported yet"），
    /// 所以全部同步执行；CLI 本身在几十毫秒内返回，不会拖住回合。
    /// 不安装 PermissionRequest：Codex Desktop 0.155 对每次工具调用都触发它（含只读命令），
    /// 与是否弹窗无关，会产生大量误报的"需要授权"。
    public static func codex(cliPath: String) -> [String: Any] {
        let cmd = command(cliPath: cliPath, agent: "codex")
        let syncHook: [String: Any] = ["type": "command", "command": cmd, "timeout": 5]
        let endHook: [String: Any] = ["type": "command", "command": cmd, "timeout": 2]
        return [
            "Stop": [["hooks": [syncHook]]],
            "UserPromptSubmit": [["hooks": [syncHook]]],
            "SessionEnd": [["hooks": [endHook]]],
        ]
    }

    public static func gemini(cliPath: String) -> [String: Any] {
        let cmd = command(cliPath: cliPath, agent: "gemini")
        let hook: [String: Any] = ["type": "command", "command": cmd, "timeout": 3000]
        var result: [String: Any] = [:]
        for event in ["AfterAgent", "Notification", "BeforeAgent", "SessionEnd"] {
            result[event] = [["hooks": [hook]]]
        }
        return result
    }

    public static func template(agent: String, cliPath: String) -> [String: Any]? {
        switch agent {
        case "claude": return claude(cliPath: cliPath)
        case "codex": return codex(cliPath: cliPath)
        case "gemini": return gemini(cliPath: cliPath)
        default: return nil
        }
    }
}
