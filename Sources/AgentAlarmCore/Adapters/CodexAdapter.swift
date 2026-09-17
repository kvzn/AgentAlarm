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
            kind = .needsPermission
            message = Self.permissionSummary(payload)
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

    static func permissionSummary(_ payload: [String: Any]) -> String? {
        guard let tool = payload.string("tool_name"), !tool.isEmpty else { return nil }
        let input = payload.dictionary("tool_input") ?? [:]
        var command = input.string("command")
        if command == nil, let parts = input.array("command") as? [String] {
            command = parts.joined(separator: " ")
        }
        guard let command, !command.isEmpty else { return tool }
        return TextTruncation.truncate("\(tool): \(command)", to: 200)
    }
}
