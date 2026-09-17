import Foundation

public struct GeminiAdapter: HookAdapter {
    public let agent = "gemini"
    public init() {}

    public func map(payload: [String: Any], context: AdapterContext) -> AlarmEvent? {
        guard let sessionId = payload.string("session_id"), !sessionId.isEmpty,
              let hookName = payload.string("hook_event_name") else { return nil }
        let kind: EventKind
        var message: String?
        switch hookName {
        case "AfterAgent":
            kind = .turnComplete
            if let response = payload.string("prompt_response"), !response.isEmpty {
                message = TextTruncation.truncate(response, to: 200)
            }
        case "Notification":
            kind = .needsPermission
            message = payload.string("message").map { TextTruncation.truncate($0, to: 200) }
        case "BeforeAgent":
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
            message: message,
            host: context.host, timestamp: context.now,
            source: EventSource(hookEventName: hookName,
                                notificationType: payload.string("notification_type")))
    }
}
