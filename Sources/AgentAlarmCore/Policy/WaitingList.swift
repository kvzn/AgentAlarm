import Foundation

public struct WaitingEntry: Equatable, Sendable, Identifiable {
    public var id: String { "\(agent):\(sessionId)" }
    public var agent: String
    public var sessionId: String
    public var kind: EventKind
    public var title: String
    public var host: HostInfo?
    public var cwd: String?
    public var since: Date
    public var updatedAt: Date
    public var seen: Bool
}

/// 等待中的会话列表：按 updatedAt 降序，超期与超量自动清理。
public struct WaitingList: Sendable {
    public enum Change: Equatable, Sendable { case added, updated, removed, ignored }

    public private(set) var entries: [WaitingEntry] = []
    public var expiry: TimeInterval
    public var capacity: Int

    public init(expiry: TimeInterval = 86_400, capacity: Int = 50) {
        self.expiry = expiry; self.capacity = capacity
    }

    public var count: Int { entries.count }

    public mutating func apply(_ event: AlarmEvent, title: String, now: Date) -> Change {
        purgeExpired(now: now)
        let id = "\(event.agent):\(event.sessionId)"
        let index = entries.firstIndex { $0.id == id }
        switch event.kind {
        case .resumed, .ended:
            guard let index else { return .ignored }
            entries.remove(at: index)
            return .removed
        case .idleReminder:
            if let index {
                entries[index].updatedAt = now
                resort()
                return .updated
            }
            insert(WaitingEntry(agent: event.agent, sessionId: event.sessionId, kind: .turnComplete, title: title,
                                host: event.host, cwd: event.cwd, since: now, updatedAt: now, seen: false))
            return .added
        case .turnComplete, .needsPermission, .needsInput:
            if let index {
                var entry = entries[index]
                entry.kind = event.kind
                entry.title = title
                entry.host = event.host ?? entry.host
                entry.cwd = event.cwd ?? entry.cwd
                entry.updatedAt = now
                entry.seen = false
                entries[index] = entry
                resort()
                return .updated
            }
            insert(WaitingEntry(agent: event.agent, sessionId: event.sessionId, kind: event.kind, title: title,
                                host: event.host, cwd: event.cwd, since: now, updatedAt: now, seen: false))
            return .added
        }
    }

    public mutating func markSeen(id: String) {
        if let index = entries.firstIndex(where: { $0.id == id }) { entries[index].seen = true }
    }

    public mutating func remove(id: String) {
        entries.removeAll { $0.id == id }
    }

    public mutating func purgeExpired(now: Date) {
        entries.removeAll { now.timeIntervalSince($0.updatedAt) > expiry }
    }

    private mutating func insert(_ entry: WaitingEntry) {
        entries.append(entry)
        resort()
        if entries.count > capacity { entries.removeLast(entries.count - capacity) }
    }

    private mutating func resort() {
        entries.sort { $0.updatedAt > $1.updatedAt }
    }
}
