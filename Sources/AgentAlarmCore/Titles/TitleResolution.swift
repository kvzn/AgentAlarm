import Foundation

public enum TitleOrigin: String, Sendable, Equatable {
    case customTitle, lastPrompt, threadName, threadTitle, sessionIndex, summary, firstMessage, provided, cwd, agentName
}

public struct TitleResolution: Equatable, Sendable {
    public var title: String
    public var origin: TitleOrigin
    public var reclassifiedKind: EventKind?
    public init(title: String, origin: TitleOrigin, reclassifiedKind: EventKind? = nil) {
        self.title = title; self.origin = origin; self.reclassifiedKind = reclassifiedKind
    }
}

public enum FallbackTitle {
    public static func resolve(_ event: AlarmEvent) -> TitleResolution {
        if let cwd = event.cwd, !cwd.isEmpty {
            let name = URL(fileURLWithPath: cwd).lastPathComponent
            if !name.isEmpty, name != "/" {
                return TitleResolution(title: name, origin: .cwd)
            }
        }
        return TitleResolution(title: AgentNames.displayName(for: event.agent), origin: .agentName)
    }
}

public enum ProvidedTitleResolver {
    public static func resolve(_ event: AlarmEvent) -> TitleResolution {
        if let title = event.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return TitleResolution(title: title, origin: .provided)
        }
        return FallbackTitle.resolve(event)
    }
}
