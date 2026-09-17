import Foundation
import Testing
@testable import AgentAlarmCore

@Suite struct AlertPolicyTests {
    let t0 = Date(timeIntervalSince1970: 1_789_600_000)
    let idle = ActivityState(frontmostBundleId: "com.apple.finder", secondsSinceUserInput: 120)
    let host = HostInfo(bundleId: "com.anthropic.claudefordesktop", pid: 1, name: "Claude")

    func event(_ kind: EventKind, session: String = "S1", host: HostInfo? = nil) -> AlarmEvent {
        AlarmEvent(agent: "claude", kind: kind, sessionId: session, host: host)
    }

    @Test func nonAlertingKindsAreSilent() {
        var policy = AlertPolicy()
        #expect(policy.decide(event(.resumed), activity: idle, now: t0) == .silent(.nonAlertingKind))
        #expect(policy.decide(event(.ended), activity: idle, now: t0) == .silent(.nonAlertingKind))
    }

    @Test func duplicateWithinThreeSecondsThenCooldownTenSeconds() {
        var policy = AlertPolicy()
        #expect(policy.decide(event(.turnComplete), activity: idle, now: t0) == .alert(speak: true))
        #expect(policy.decide(event(.turnComplete), activity: idle, now: t0.addingTimeInterval(2)) == .silent(.duplicate))
        #expect(policy.decide(event(.needsPermission), activity: idle, now: t0.addingTimeInterval(5)) == .silent(.cooldown))
        #expect(policy.decide(event(.needsPermission), activity: idle, now: t0.addingTimeInterval(11)) == .alert(speak: true))
        #expect(policy.decide(event(.turnComplete, session: "S2"), activity: idle, now: t0.addingTimeInterval(1)) == .alert(speak: true), "不同会话互不影响")
    }

    @Test func reminderSwitch() {
        var policy = AlertPolicy()
        #expect(policy.decide(event(.idleReminder), activity: idle, now: t0) == .alert(speak: true))
        policy.settings.repeatReminders = false
        #expect(policy.decide(event(.idleReminder, session: "S2"), activity: idle, now: t0) == .silent(.reminderDisabled))
    }

    @Test func pauseForDurationAndUntilResumed() {
        var policy = AlertPolicy()
        policy.pause(for: 900, now: t0)
        #expect(policy.isPaused(at: t0.addingTimeInterval(899)))
        #expect(policy.decide(event(.turnComplete), activity: idle, now: t0) == .silent(.paused))
        #expect(!policy.isPaused(at: t0.addingTimeInterval(901)))
        #expect(policy.decide(event(.turnComplete, session: "S2"), activity: idle, now: t0.addingTimeInterval(901)) == .alert(speak: true))
        policy.pause(for: nil, now: t0)
        #expect(policy.isPaused(at: t0.addingTimeInterval(1_000_000)))
        policy.resume()
        #expect(!policy.isPaused(at: t0))
    }

    @Test func quietHoursWrapMidnight() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        var policy = AlertPolicy()
        policy.settings.quietHours = QuietHours(startMinute: 23 * 60, endMinute: 7 * 60)
        let lateNight = utc.date(from: DateComponents(year: 2026, month: 9, day: 17, hour: 23, minute: 30))!
        let morning = utc.date(from: DateComponents(year: 2026, month: 9, day: 18, hour: 6, minute: 59))!
        let noon = utc.date(from: DateComponents(year: 2026, month: 9, day: 18, hour: 12, minute: 0))!
        #expect(policy.decide(event(.turnComplete, session: "A"), activity: idle, now: lateNight, calendar: utc) == .silent(.quietHours))
        #expect(policy.decide(event(.turnComplete, session: "B"), activity: idle, now: morning, calendar: utc) == .silent(.quietHours))
        #expect(policy.decide(event(.turnComplete, session: "C"), activity: idle, now: noon, calendar: utc) == .alert(speak: true))
        #expect(!QuietHours(startMinute: 600, endMinute: 600).contains(minuteOfDay: 600))
    }

    @Test func speechSuppressedOnlyWhenHostFrontmostAndUserActive() {
        var policy = AlertPolicy()
        let active = ActivityState(frontmostBundleId: host.bundleId, secondsSinceUserInput: 3)
        #expect(policy.decide(event(.turnComplete, session: "A", host: host), activity: active, now: t0) == .alert(speak: false))
        #expect(policy.decide(event(.turnComplete, session: "B", host: nil), activity: active, now: t0) == .alert(speak: true))
        let otherApp = ActivityState(frontmostBundleId: "com.googlecode.iterm2", secondsSinceUserInput: 3)
        #expect(policy.decide(event(.turnComplete, session: "C", host: host), activity: otherApp, now: t0) == .alert(speak: true))
        let awayFromKeyboard = ActivityState(frontmostBundleId: host.bundleId, secondsSinceUserInput: 30)
        #expect(policy.decide(event(.turnComplete, session: "D", host: host), activity: awayFromKeyboard, now: t0) == .alert(speak: true))
        policy.settings.suppressSpeechWhenHostActive = false
        #expect(policy.decide(event(.turnComplete, session: "E", host: host), activity: active, now: t0) == .alert(speak: true))
    }
}
