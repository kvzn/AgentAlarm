import Foundation

/// 接收 OpenCode 插件已经归一化过的 payload。
public struct OpenCodeAdapter: HookAdapter {
    public let agent = "opencode"
    public init() {}

    public func map(payload: [String: Any], context: AdapterContext) -> AlarmEvent? {
        guard let rawKind = payload.string("kind"), let kind = EventKind(rawValue: rawKind),
              let sessionId = payload.string("sessionID"), !sessionId.isEmpty else { return nil }
        let title = payload.string("title").flatMap { $0.isEmpty ? nil : $0 }
        let message = payload.string("message").flatMap { $0.isEmpty ? nil : TextTruncation.truncate($0, to: 200) }
        return AlarmEvent(
            agent: agent, kind: kind, sessionId: sessionId,
            cwd: payload.string("directory"),
            title: title, message: message,
            host: context.host, timestamp: context.now,
            source: EventSource(hookEventName: "plugin"))
    }
}
