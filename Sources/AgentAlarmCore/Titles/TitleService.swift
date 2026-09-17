import Foundation

/// 按 agent 分发到对应解析器；Claude 与 Gemini 结果按 transcript 修改时间缓存。
public final class TitleService: @unchecked Sendable {
    private let claude: ClaudeTitleResolver
    private let codex: CodexTitleResolver
    private let gemini: GeminiTitleResolver
    private let lock = NSLock()
    private var cache: [String: (modified: Date, resolution: TitleResolution)] = [:]

    public init(claude: ClaudeTitleResolver, codex: CodexTitleResolver, gemini: GeminiTitleResolver) {
        self.claude = claude; self.codex = codex; self.gemini = gemini
    }

    public func resolve(_ event: AlarmEvent) -> TitleResolution {
        // 发送方已带标题（OpenCode 插件、notify、test）时直接采用，不再回查文件。
        if let provided = event.title?.trimmingCharacters(in: .whitespacesAndNewlines), !provided.isEmpty {
            return TitleResolution(title: provided, origin: .provided)
        }
        switch event.agent {
        case "claude": return cached(event) { claude.resolve($0) }
        case "gemini": return cached(event) { gemini.resolve($0) }
        case "codex": return codex.resolve(event)
        default: return ProvidedTitleResolver.resolve(event)
        }
    }

    private func cached(_ event: AlarmEvent, _ resolve: (AlarmEvent) -> TitleResolution) -> TitleResolution {
        let key = "\(event.agent):\(event.sessionId)"
        let modified = event.transcriptPath.flatMap {
            (try? FileManager.default.attributesOfItem(atPath: $0))?[.modificationDate] as? Date
        }
        lock.lock(); defer { lock.unlock() }
        if let modified, let entry = cache[key], entry.modified == modified {
            return entry.resolution
        }
        let resolution = resolve(event)
        if let modified { cache[key] = (modified, resolution) }
        return resolution
    }
}
