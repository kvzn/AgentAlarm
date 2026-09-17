import Foundation

public enum EventKind: String, Codable, Sendable, CaseIterable {
    case turnComplete = "turn_complete"
    case needsPermission = "needs_permission"
    case needsInput = "needs_input"
    case idleReminder = "idle_reminder"
    case resumed
    case ended

    public var isAlerting: Bool {
        switch self {
        case .resumed, .ended: return false
        default: return true
        }
    }
}

public struct HostInfo: Codable, Sendable, Equatable {
    public var bundleId: String
    public var pid: Int32
    public var name: String
    public init(bundleId: String, pid: Int32, name: String) {
        self.bundleId = bundleId; self.pid = pid; self.name = name
    }
}

public struct EventSource: Codable, Sendable, Equatable {
    public var hookEventName: String?
    public var notificationType: String?
    public var entrypoint: String?
    public init(hookEventName: String? = nil, notificationType: String? = nil, entrypoint: String? = nil) {
        self.hookEventName = hookEventName; self.notificationType = notificationType; self.entrypoint = entrypoint
    }
}

public struct AlarmEvent: Codable, Sendable, Equatable {
    public var v: Int
    public var id: String
    public var agent: String
    public var kind: EventKind
    public var sessionId: String
    public var turnId: String?
    public var cwd: String?
    public var transcriptPath: String?
    public var title: String?
    public var message: String?
    public var host: HostInfo?
    public var timestamp: Date
    public var source: EventSource

    public init(id: String = UUID().uuidString,
                agent: String,
                kind: EventKind,
                sessionId: String,
                turnId: String? = nil,
                cwd: String? = nil,
                transcriptPath: String? = nil,
                title: String? = nil,
                message: String? = nil,
                host: HostInfo? = nil,
                timestamp: Date = Date(),
                source: EventSource = EventSource()) {
        self.v = 1
        self.id = id; self.agent = agent; self.kind = kind; self.sessionId = sessionId
        self.turnId = turnId; self.cwd = cwd; self.transcriptPath = transcriptPath
        self.title = title; self.message = message; self.host = host
        self.timestamp = timestamp; self.source = source
    }
}

public enum EventCoding {
    public static func encode(_ event: AlarmEvent) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(event)
    }

    public static func decode(_ data: Data) throws -> AlarmEvent {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(AlarmEvent.self, from: data)
    }
}
