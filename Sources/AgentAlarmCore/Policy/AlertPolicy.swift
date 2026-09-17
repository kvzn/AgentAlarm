import Foundation

public struct QuietHours: Equatable, Sendable {
    public var startMinute: Int
    public var endMinute: Int
    public init(startMinute: Int, endMinute: Int) { self.startMinute = startMinute; self.endMinute = endMinute }

    public func contains(minuteOfDay minute: Int) -> Bool {
        if startMinute == endMinute { return false }
        if startMinute < endMinute { return minute >= startMinute && minute < endMinute }
        return minute >= startMinute || minute < endMinute
    }
}

public struct PolicySettings: Equatable, Sendable {
    public var dedupWindow: TimeInterval = 3
    public var sessionCooldown: TimeInterval = 10
    public var repeatReminders = true
    public var suppressSpeechWhenHostActive = true
    public var userActiveThreshold: TimeInterval = 10
    public var quietHours: QuietHours? = nil
    public init() {}
}

public struct ActivityState: Equatable, Sendable {
    public var frontmostBundleId: String?
    public var secondsSinceUserInput: TimeInterval
    public init(frontmostBundleId: String?, secondsSinceUserInput: TimeInterval) {
        self.frontmostBundleId = frontmostBundleId; self.secondsSinceUserInput = secondsSinceUserInput
    }
}

public enum SilentReason: String, Sendable, Equatable {
    case nonAlertingKind, duplicate, cooldown, reminderDisabled, paused, quietHours
}

public enum AlertDecision: Equatable, Sendable {
    case silent(SilentReason)
    case alert(speak: Bool)
}

/// 提醒策略。检查顺序：kind → 去重 → 冷却 → 重复提醒开关 → 暂停 → 静音时段 → 语音抑制。
public struct AlertPolicy: Sendable {
    public var settings: PolicySettings
    public var pausedUntil: Date?
    private var lastSeen: [String: Date] = [:]
    private var lastAlert: [String: Date] = [:]

    public init(settings: PolicySettings = PolicySettings()) { self.settings = settings }

    public func isPaused(at now: Date) -> Bool {
        guard let pausedUntil else { return false }
        return now < pausedUntil
    }

    /// duration 为 nil 表示直到手动恢复。
    public mutating func pause(for duration: TimeInterval?, now: Date) {
        pausedUntil = duration.map { now.addingTimeInterval($0) } ?? .distantFuture
    }

    public mutating func resume() { pausedUntil = nil }

    public mutating func decide(_ event: AlarmEvent, activity: ActivityState, now: Date, calendar: Calendar = .current) -> AlertDecision {
        guard event.kind.isAlerting else { return .silent(.nonAlertingKind) }
        let dedupKey = "\(event.agent):\(event.sessionId):\(event.kind.rawValue)"
        if let last = lastSeen[dedupKey], now.timeIntervalSince(last) < settings.dedupWindow {
            return .silent(.duplicate)
        }
        lastSeen[dedupKey] = now
        let sessionKey = "\(event.agent):\(event.sessionId)"
        if let last = lastAlert[sessionKey], now.timeIntervalSince(last) < settings.sessionCooldown {
            return .silent(.cooldown)
        }
        if event.kind == .idleReminder, !settings.repeatReminders { return .silent(.reminderDisabled) }
        if isPaused(at: now) { return .silent(.paused) }
        if let quiet = settings.quietHours {
            let parts = calendar.dateComponents([.hour, .minute], from: now)
            let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            if quiet.contains(minuteOfDay: minute) { return .silent(.quietHours) }
        }
        lastAlert[sessionKey] = now
        var speak = true
        if settings.suppressSpeechWhenHostActive,
           let host = event.host,
           host.bundleId == activity.frontmostBundleId,
           activity.secondsSinceUserInput < settings.userActiveThreshold {
            speak = false
        }
        return .alert(speak: speak)
    }
}
