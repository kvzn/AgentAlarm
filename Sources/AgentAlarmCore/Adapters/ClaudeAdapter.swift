import Foundation

public struct ClaudeAdapter: HookAdapter {
    public let agent = "claude"
    public init() {}

    public func map(payload: [String: Any], context: AdapterContext) -> AlarmEvent? {
        guard let sessionId = payload.string("session_id"), !sessionId.isEmpty,
              let hookName = payload.string("hook_event_name") else { return nil }
        let notificationType = payload.string("notification_type")
        let kind: EventKind
        switch hookName {
        case "Stop":
            if let agentId = payload.string("agent_id"), !agentId.isEmpty { return nil }
            kind = .turnComplete
        case "Notification":
            switch notificationType {
            case "permission_prompt": kind = .needsPermission
            case "idle_prompt": kind = .idleReminder
            case "elicitation_dialog", "elicitation_url_dialog", "agent_needs_input": kind = .needsInput
            default: return nil
            }
        case "UserPromptSubmit":
            kind = .resumed
        case "SessionEnd":
            kind = .ended
        default:
            return nil
        }
        return AlarmEvent(
            agent: agent, kind: kind, sessionId: sessionId,
            cwd: payload.string("cwd"),
            transcriptPath: payload.string("transcript_path"),
            host: context.host, timestamp: context.now,
            source: EventSource(hookEventName: hookName,
                                notificationType: notificationType,
                                entrypoint: context.environment["CLAUDE_CODE_ENTRYPOINT"]))
    }
}
