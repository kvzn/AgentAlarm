import Foundation

/// 适配器运行时上下文：环境变量、CLI 识别到的宿主、当前时间。
public struct AdapterContext: Sendable {
    public var environment: [String: String]
    public var host: HostInfo?
    public var now: Date
    public init(environment: [String: String] = [:], host: HostInfo? = nil, now: Date = Date()) {
        self.environment = environment; self.host = host; self.now = now
    }
}

/// 把某个 Agent 的原始 hook payload 映射为统一事件；无对应映射时返回 nil。
public protocol HookAdapter {
    var agent: String { get }
    func map(payload: [String: Any], context: AdapterContext) -> AlarmEvent?
}

public enum AdapterRegistry {
    public static func adapter(for agent: String) -> (any HookAdapter)? {
        switch agent {
        case "claude": return ClaudeAdapter()
        case "codex": return CodexAdapter()
        case "gemini": return GeminiAdapter()
        case "opencode": return OpenCodeAdapter()
        default: return nil
        }
    }
}
