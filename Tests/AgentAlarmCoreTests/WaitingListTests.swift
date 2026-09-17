import Foundation
import Testing
@testable import AgentAlarmCore

@Suite struct WaitingListTests {
    let t0 = Date(timeIntervalSince1970: 1_789_600_000)

    func event(_ kind: EventKind, session: String = "S1", agent: String = "claude") -> AlarmEvent {
        AlarmEvent(agent: agent, kind: kind, sessionId: session, cwd: "/p/\(session)",
                   host: HostInfo(bundleId: "com.example.host", pid: 1, name: "Host"))
    }

    @Test func addUpdateRemove() {
        var list = WaitingList()
        #expect(list.apply(event(.turnComplete), title: "A", now: t0) == .added)
        #expect(list.count == 1)
        #expect(list.entries[0].kind == .turnComplete)
        #expect(list.entries[0].since == t0)
        #expect(list.apply(event(.needsPermission), title: "A2", now: t0.addingTimeInterval(5)) == .updated)
        #expect(list.count == 1)
        #expect(list.entries[0].kind == .needsPermission)
        #expect(list.entries[0].title == "A2")
        #expect(list.entries[0].since == t0)
        #expect(list.entries[0].updatedAt == t0.addingTimeInterval(5))
        #expect(list.apply(event(.resumed), title: "", now: t0.addingTimeInterval(6)) == .removed)
        #expect(list.count == 0)
        #expect(list.apply(event(.ended), title: "", now: t0) == .ignored)
    }

    @Test func idleReminderUpdatesOrCreates() {
        var list = WaitingList()
        #expect(list.apply(event(.idleReminder), title: "A", now: t0) == .added)
        #expect(list.entries[0].kind == .turnComplete)
        _ = list.apply(event(.needsInput), title: "A", now: t0.addingTimeInterval(1))
        #expect(list.apply(event(.idleReminder), title: "A", now: t0.addingTimeInterval(60)) == .updated)
        #expect(list.entries[0].kind == .needsInput, "idle 只更新时间不改 kind")
        #expect(list.entries[0].updatedAt == t0.addingTimeInterval(60))
    }

    @Test func seenResetsOnUpdateAndSortNewestFirst() {
        var list = WaitingList()
        _ = list.apply(event(.turnComplete, session: "S1"), title: "one", now: t0)
        _ = list.apply(event(.turnComplete, session: "S2"), title: "two", now: t0.addingTimeInterval(1))
        #expect(list.entries.map(\.sessionId) == ["S2", "S1"])
        list.markSeen(id: "claude:S1")
        #expect(list.entries[1].seen)
        _ = list.apply(event(.turnComplete, session: "S1"), title: "one again", now: t0.addingTimeInterval(2))
        #expect(list.entries.map(\.sessionId) == ["S1", "S2"])
        #expect(!list.entries[0].seen)
    }

    @Test func expiryAndCapacity() {
        var list = WaitingList(expiry: 100, capacity: 3)
        for i in 0..<5 {
            _ = list.apply(event(.turnComplete, session: "S\(i)"), title: "t", now: t0.addingTimeInterval(Double(i)))
        }
        #expect(list.count == 3)
        #expect(list.entries.map(\.sessionId) == ["S4", "S3", "S2"])
        _ = list.apply(event(.turnComplete, session: "S9"), title: "t", now: t0.addingTimeInterval(200))
        #expect(list.entries.map(\.sessionId) == ["S9"], "过期条目在下一次 apply 时清掉")
    }

    @Test func manualTimeSourceAdvances() {
        let clock = ManualTimeSource(now: t0)
        clock.advance(by: 30)
        #expect(clock.now == t0.addingTimeInterval(30))
        #expect(abs(SystemTimeSource().now.timeIntervalSinceNow) < 1)
    }
}
