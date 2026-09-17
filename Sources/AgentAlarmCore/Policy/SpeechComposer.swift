public struct SpeechItem: Equatable, Sendable {
    public var agent: String
    public var title: String
    public var kind: EventKind
    public init(agent: String, title: String, kind: EventKind) {
        self.agent = agent; self.title = title; self.kind = kind
    }
}

public enum SpeechComposer {
    public static func statusPhrase(_ kind: EventKind) -> String {
        switch kind {
        case .turnComplete: return "已完成"
        case .needsPermission: return "需要授权"
        case .needsInput: return "有问题要问你"
        case .idleReminder: return "还在等你"
        case .resumed, .ended: return ""
        }
    }

    public static func sentence(for item: SpeechItem) -> String {
        "\(AgentNames.displayName(for: item.agent))，\(TextTruncation.truncate(item.title, to: 40))，\(statusPhrase(item.kind))"
    }

    public static func sentence(for items: [SpeechItem]) -> String {
        guard items.count > 1 else { return items.first.map { sentence(for: $0) } ?? "" }
        let titles = items.prefix(3).map { TextTruncation.truncate($0.title, to: 40) }.joined(separator: "，")
        let suffix = items.count > 3 ? "等" : ""
        return "有 \(items.count) 个会话在等待：\(titles)\(suffix)"
    }
}
