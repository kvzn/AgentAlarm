import AgentAlarmCore
import AppKit
import Foundation
import Observation
import OSLog

struct LogEntry: Identifiable {
    let id = UUID()
    let date: Date
    let agent: String
    let kind: EventKind
    let title: String
    let outcome: String
}

/// 事件管线：socket → 标题解析 → 等待列表 → 策略 → 声音/语音/日志。
@MainActor @Observable
final class AppModel {
    static let shared = AppModel()

    private(set) var waiting = WaitingList()
    private(set) var log: [LogEntry] = []
    private(set) var policy: AlertPolicy
    var lastError: String?

    let settings: AppSettings
    let paths: AgentPaths

    @ObservationIgnored private let titleService: TitleService
    @ObservationIgnored private var server: SocketServer?
    @ObservationIgnored private let sound = SoundPlayer()
    @ObservationIgnored private let speech = SpeechQueue()
    @ObservationIgnored private let logger = Logger(subsystem: "com.jack.agentalarm", category: "policy")
    @ObservationIgnored private let socketLogger = Logger(subsystem: "com.jack.agentalarm", category: "socket")

    var isPaused: Bool { policy.isPaused(at: Date()) }

    init(settings: AppSettings = .shared, paths: AgentPaths = .standard) {
        self.settings = settings
        self.paths = paths
        policy = AlertPolicy(settings: settings.policySettings)
        titleService = TitleService(claude: ClaudeTitleResolver(),
                                    codex: CodexTitleResolver(codexHome: paths.codexHome),
                                    gemini: GeminiTitleResolver())
    }

    func start() {
        do {
            try FileManager.default.createDirectory(at: paths.appSupport, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let server = SocketServer(path: paths.socket.path) { data in
                Task { @MainActor in AppModel.shared.receive(data) }
            }
            try server.start()
            self.server = server
            socketLogger.info("listening at \(self.paths.socket.path, privacy: .public)")
        } catch {
            lastError = "无法监听 socket：\(error)"
            socketLogger.error("listen failed: \(String(describing: error), privacy: .public)")
        }
    }

    func stop() {
        server?.stop()
        server = nil
    }

    func receive(_ data: Data) {
        guard let event = try? EventCoding.decode(data) else {
            socketLogger.error("undecodable event, \(data.count) bytes")
            return
        }
        settings.markVerified(event.agent)
        guard event.kind.isAlerting else {
            _ = waiting.apply(event, title: "", now: Date())
            record(event, title: "", outcome: "list: \(event.kind.rawValue)")
            return
        }
        let service = titleService
        Task.detached(priority: .userInitiated) {
            let resolution = await AppModel.resolveWithBudget(event, service: service)
            await MainActor.run { AppModel.shared.process(event, resolution: resolution) }
        }
    }

    /// 标题解析预算 1 秒：先到先用，超时用退化标题，不阻塞提醒。
    nonisolated static func resolveWithBudget(_ event: AlarmEvent, service: TitleService) async -> TitleResolution {
        await withTaskGroup(of: TitleResolution.self) { group in
            group.addTask { service.resolve(event) }
            group.addTask {
                try? await Task.sleep(for: .seconds(1))
                return FallbackTitle.resolve(event)
            }
            let first = await group.next() ?? FallbackTitle.resolve(event)
            group.cancelAll()
            return first
        }
    }

    private func process(_ incoming: AlarmEvent, resolution: TitleResolution) {
        var event = incoming
        if event.kind == .turnComplete, let reclassified = resolution.reclassifiedKind { event.kind = reclassified }
        let displayTitle = TextTruncation.truncate(resolution.title, to: 80)
        _ = waiting.apply(event, title: displayTitle, now: Date())
        policy.settings = settings.policySettings
        let decision = policy.decide(event, activity: ActivityMonitor.snapshot(), now: Date())
        switch decision {
        case .silent(let reason):
            record(event, title: displayTitle, outcome: "silent: \(reason.rawValue)")
        case .alert(let speak):
            sound.play(name: settings.soundName(for: event.kind), volume: settings.soundVolume)
            if speak {
                speech.voiceIdentifier = settings.speechVoice
                speech.rate = Float(settings.speechRate)
                speech.enqueue(SpeechItem(agent: event.agent, title: resolution.title, kind: event.kind))
            }
            didAlert(event, title: displayTitle)
            record(event, title: displayTitle, outcome: speak ? "alert + speech" : "alert, speech suppressed")
        }
        logger.info("\(event.agent, privacy: .public)/\(event.kind.rawValue, privacy: .public) -> \(String(describing: decision), privacy: .public) title=\(resolution.origin.rawValue, privacy: .public)")
    }

    /// 提醒发生后的扩展点，Task 20 在这里发系统横幅。
    func didAlert(_ event: AlarmEvent, title: String) {}

    private func record(_ event: AlarmEvent, title: String, outcome: String) {
        log.insert(LogEntry(date: Date(), agent: event.agent, kind: event.kind, title: title, outcome: outcome), at: 0)
        if log.count > 100 { log.removeLast(log.count - 100) }
    }

    func select(_ entry: WaitingEntry) {
        waiting.markSeen(id: entry.id)
    }

    func pause(minutes: Int?) {
        policy.pause(for: minutes.map { Double($0) * 60 }, now: Date())
    }

    func resume() { policy.resume() }

    func sendTestAlert() {
        let event = AlarmEvent(agent: "claude", kind: .turnComplete, sessionId: "test-\(UUID().uuidString)",
                               cwd: paths.home.path, title: "测试提醒", source: EventSource(hookEventName: "test"))
        if let data = try? EventCoding.encode(event) { receive(data) }
    }

    func previewSpeech(_ text: String) {
        speech.voiceIdentifier = settings.speechVoice
        speech.rate = Float(settings.speechRate)
        speech.speakNow(text)
    }

    func previewSound(_ name: String) {
        sound.play(name: name, volume: settings.soundVolume)
    }
}
