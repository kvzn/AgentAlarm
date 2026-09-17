import Foundation

/// 从 Gemini CLI 的 chats/session-*.json 读取 summary，退化到首条用户消息。
public struct GeminiTitleResolver: Sendable {
    public init() {}

    public func resolve(_ event: AlarmEvent) -> TitleResolution {
        guard let path = event.transcriptPath,
              let data = FileManager.default.contents(atPath: path),
              let record = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return FallbackTitle.resolve(event)
        }
        if let summary = record.string("summary")?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
            return TitleResolution(title: TextTruncation.truncate(summary, to: 40), origin: .summary)
        }
        for item in record.array("messages") ?? [] {
            guard let message = item as? [String: Any], message.string("type") == "user" else { continue }
            let first = TextTruncation.firstLine(Self.text(of: message["content"]))
            if !first.isEmpty {
                return TitleResolution(title: TextTruncation.truncate(first, to: 40), origin: .firstMessage)
            }
        }
        return FallbackTitle.resolve(event)
    }

    static func text(of content: Any?) -> String {
        if let string = content as? String { return string }
        if let parts = content as? [Any] {
            return parts.compactMap { part -> String? in
                if let string = part as? String { return string }
                return (part as? [String: Any])?.string("text")
            }.joined(separator: " ")
        }
        return ""
    }
}
