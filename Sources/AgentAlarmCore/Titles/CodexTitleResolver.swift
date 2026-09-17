import Foundation

/// 从 ~/.codex/state_N.sqlite 的 threads 表取线程名或标题，退化到 session_index.jsonl 与 cwd。
public struct CodexTitleResolver: Sendable {
    public var codexHome: URL
    public init(codexHome: URL) { self.codexHome = codexHome }

    public func resolve(_ event: AlarmEvent) -> TitleResolution {
        if let db = Self.latestStateDatabase(in: codexHome),
           let hit = Self.lookup(database: db, threadId: event.sessionId) {
            return hit
        }
        if let hit = Self.lookupSessionIndex(codexHome.appendingPathComponent("session_index.jsonl"), threadId: event.sessionId) {
            return hit
        }
        return FallbackTitle.resolve(event)
    }

    static func latestStateDatabase(in home: URL) -> URL? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: home.path) else { return nil }
        let candidates = names.compactMap { name -> (Int, String)? in
            guard name.hasPrefix("state_"), name.hasSuffix(".sqlite") else { return nil }
            let digits = name.dropFirst("state_".count).dropLast(".sqlite".count)
            guard let number = Int(digits) else { return nil }
            return (number, name)
        }
        guard let best = candidates.max(by: { $0.0 < $1.0 }) else { return nil }
        return home.appendingPathComponent(best.1)
    }

    static func lookup(database: URL, threadId: String) -> TitleResolution? {
        guard let reader = try? SQLiteReader(path: database.path),
              let row = try? reader.firstRow(sql: "SELECT name, title, first_user_message FROM threads WHERE id = ?1",
                                             bindings: [threadId]) else { return nil }
        if let name = (row["name"] ?? nil)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return TitleResolution(title: name, origin: .threadName)
        }
        let fallbacks: [(String, TitleOrigin)] = [("title", .threadTitle), ("first_user_message", .firstMessage)]
        for (column, origin) in fallbacks {
            guard let text = row[column] ?? nil else { continue }
            let first = TextTruncation.firstLine(text)
            if !first.isEmpty {
                return TitleResolution(title: TextTruncation.truncate(first, to: 40), origin: origin)
            }
        }
        return nil
    }

    static func lookupSessionIndex(_ url: URL, threadId: String) -> TitleResolution? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n").reversed() where line.contains(threadId) {
            guard let record = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  record.string("id") == threadId,
                  let name = record.string("thread_name"), !name.isEmpty else { continue }
            return TitleResolution(title: name, origin: .sessionIndex)
        }
        return nil
    }
}
