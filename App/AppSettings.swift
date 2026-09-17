import AgentAlarmCore
import Foundation
import Observation

/// UserDefaults 包装，键前缀 aa.。
@MainActor @Observable
final class AppSettings {
    static let shared = AppSettings()

    @ObservationIgnored private let defaults: UserDefaults

    var soundComplete: String { didSet { defaults.set(soundComplete, forKey: "aa.sound.complete") } }
    var soundPermission: String { didSet { defaults.set(soundPermission, forKey: "aa.sound.permission") } }
    var soundInput: String { didSet { defaults.set(soundInput, forKey: "aa.sound.input") } }
    var soundVolume: Double { didSet { defaults.set(soundVolume, forKey: "aa.sound.volume") } }
    var speechVoice: String { didSet { defaults.set(speechVoice, forKey: "aa.speech.voice") } }
    var speechRate: Double { didSet { defaults.set(speechRate, forKey: "aa.speech.rate") } }
    var bannerEnabled: Bool { didSet { defaults.set(bannerEnabled, forKey: "aa.banner.enabled") } }
    var suppressWhenHostActive: Bool { didSet { defaults.set(suppressWhenHostActive, forKey: "aa.rules.suppressWhenHostActive") } }
    var userActiveThreshold: Double { didSet { defaults.set(userActiveThreshold, forKey: "aa.rules.userActiveThreshold") } }
    var repeatReminders: Bool { didSet { defaults.set(repeatReminders, forKey: "aa.rules.repeatReminders") } }
    var quietHoursEnabled: Bool { didSet { defaults.set(quietHoursEnabled, forKey: "aa.rules.quietHoursEnabled") } }
    var quietStartMinute: Int { didSet { defaults.set(quietStartMinute, forKey: "aa.rules.quietStart") } }
    var quietEndMinute: Int { didSet { defaults.set(quietEndMinute, forKey: "aa.rules.quietEnd") } }
    var verifiedAgents: [String] { didSet { defaults.set(verifiedAgents, forKey: "aa.integration.verified") } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func string(_ key: String, _ fallback: String) -> String { defaults.string(forKey: key) ?? fallback }
        func double(_ key: String, _ fallback: Double) -> Double { defaults.object(forKey: key) == nil ? fallback : defaults.double(forKey: key) }
        func bool(_ key: String, _ fallback: Bool) -> Bool { defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key) }
        func int(_ key: String, _ fallback: Int) -> Int { defaults.object(forKey: key) == nil ? fallback : defaults.integer(forKey: key) }
        soundComplete = string("aa.sound.complete", "Glass")
        soundPermission = string("aa.sound.permission", "Ping")
        soundInput = string("aa.sound.input", "Purr")
        soundVolume = double("aa.sound.volume", 0.8)
        speechVoice = string("aa.speech.voice", "")
        speechRate = double("aa.speech.rate", 0.5)
        bannerEnabled = bool("aa.banner.enabled", true)
        suppressWhenHostActive = bool("aa.rules.suppressWhenHostActive", true)
        userActiveThreshold = double("aa.rules.userActiveThreshold", 10)
        repeatReminders = bool("aa.rules.repeatReminders", true)
        quietHoursEnabled = bool("aa.rules.quietHoursEnabled", false)
        quietStartMinute = int("aa.rules.quietStart", 23 * 60)
        quietEndMinute = int("aa.rules.quietEnd", 8 * 60)
        verifiedAgents = defaults.stringArray(forKey: "aa.integration.verified") ?? []
    }

    var policySettings: PolicySettings {
        var policy = PolicySettings()
        policy.repeatReminders = repeatReminders
        policy.suppressSpeechWhenHostActive = suppressWhenHostActive
        policy.userActiveThreshold = userActiveThreshold
        policy.quietHours = quietHoursEnabled ? QuietHours(startMinute: quietStartMinute, endMinute: quietEndMinute) : nil
        return policy
    }

    func soundName(for kind: EventKind) -> String {
        switch kind {
        case .needsPermission: return soundPermission
        case .needsInput: return soundInput
        default: return soundComplete
        }
    }

    func isVerified(_ agent: String) -> Bool { verifiedAgents.contains(agent) }
    func markVerified(_ agent: String) { if !verifiedAgents.contains(agent) { verifiedAgents.append(agent) } }
    func clearVerified(_ agent: String) { verifiedAgents.removeAll { $0 == agent } }
}
