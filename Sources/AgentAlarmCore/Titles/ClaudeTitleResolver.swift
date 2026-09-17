import Foundation

/// 从 Claude Code transcript JSONL 的尾部解析会话标题，并检测最后一条回复是否在向用户提问。
public struct ClaudeTitleResolver: Sendable {
    public var maxTailBytes: Int
    public init(maxTailBytes: Int = 512 * 1024) { self.maxTailBytes = maxTailBytes }

    public func resolve(_ event: AlarmEvent) -> TitleResolution {
        guard let path = event.transcriptPath,
              let lines = Self.tailLines(path: path, maxBytes: maxTailBytes) else {
            return FallbackTitle.resolve(event)
        }
        var found: TitleResolution?
        var reclassified: EventKind?
        var sawAssistant = false
        for line in lines.reversed() {
            if found == nil, line.contains("custom-title"),
               let record = Self.parse(line), record.string("type") == "custom-title",
               let title = record.string("customTitle")?.trimmingCharacters(in: .whitespacesAndNewlines),
               !title.isEmpty {
                found = TitleResolution(title: title, origin: .customTitle)
            }
            if !sawAssistant, line.contains("assistant"),
               let record = Self.parse(line), record.string("type") == "assistant" {
                sawAssistant = true
                if Self.containsAskUserQuestion(record) { reclassified = .needsInput }
            }
            if found != nil, sawAssistant { break }
        }
        if found == nil {
            for line in lines.reversed() where line.contains("last-prompt") {
                guard let record = Self.parse(line), record.string("type") == "last-prompt",
                      let prompt = record.string("lastPrompt") else { continue }
                let first = TextTruncation.firstLine(prompt)
                if !first.isEmpty {
                    found = TitleResolution(title: TextTruncation.truncate(first, to: 40), origin: .lastPrompt)
                    break
                }
            }
        }
        var result = found ?? FallbackTitle.resolve(event)
        result.reclassifiedKind = reclassified
        return result
    }

    /// 读取文件末尾最多 maxBytes，按行拆分；若从中间开始读则丢弃第一段不完整的行。
    static func tailLines(path: String, maxBytes: Int) -> [String]? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.readToEnd() else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        if start > 0, !lines.isEmpty { lines.removeFirst() }
        return lines
    }

    static func parse(_ line: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
    }

    static func containsAskUserQuestion(_ record: [String: Any]) -> Bool {
        guard let message = record.dictionary("message"), let content = message.array("content") else { return false }
        return content.contains { item in
            guard let block = item as? [String: Any] else { return false }
            return block.string("type") == "tool_use" && block.string("name") == "AskUserQuestion"
        }
    }
}
