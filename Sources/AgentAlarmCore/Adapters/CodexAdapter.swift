import Foundation

public struct CodexAdapter: HookAdapter {
    public let agent = "codex"
    public init() {}

    public func map(payload: [String: Any], context: AdapterContext) -> AlarmEvent? {
        guard let sessionId = payload.string("session_id"), !sessionId.isEmpty,
              let hookName = payload.string("hook_event_name") else { return nil }
        let kind: EventKind
        var message: String?
        switch hookName {
        case "Stop":
            kind = .turnComplete
            if let last = payload.string("last_assistant_message"), !last.isEmpty {
                message = TextTruncation.truncate(last, to: 200)
            }
        case "PermissionRequest":
            // Codex Desktop 0.155 实测对每次 Bash 调用都触发该 hook（含只读命令），与是否弹窗无关，
            // payload 里也没有可区分的字段，因此不能当作"等待授权"的信号，直接忽略。
            return nil
        case "UserPromptSubmit":
            kind = .resumed
        case "SessionEnd":
            kind = .ended
        default:
            return nil
        }
        return AlarmEvent(
            agent: agent, kind: kind, sessionId: sessionId,
            turnId: payload.string("turn_id"),
            cwd: payload.string("cwd"),
            transcriptPath: payload.string("transcript_path"),
            message: message,
            host: context.host, timestamp: context.now,
            source: EventSource(hookEventName: hookName))
    }

}
