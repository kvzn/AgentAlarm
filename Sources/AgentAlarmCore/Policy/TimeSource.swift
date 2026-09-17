import Foundation

public protocol TimeSource: Sendable {
    var now: Date { get }
}

public struct SystemTimeSource: TimeSource {
    public init() {}
    public var now: Date { Date() }
}

/// 测试用可拨动的时钟。
public final class ManualTimeSource: TimeSource, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    public init(now: Date) { current = now }
    public var now: Date {
        lock.lock(); defer { lock.unlock() }
        return current
    }
    public func advance(by seconds: TimeInterval) {
        lock.lock(); current = current.addingTimeInterval(seconds); lock.unlock()
    }
}
