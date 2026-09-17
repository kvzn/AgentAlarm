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

/// `resolveWithBudget` 是 nonisolated static，用文件作用域 logger 而不是类型成员。
private let titleLogger = Logger(subsystem: "com.jack.agentalarm", category: "title")

/// 标题解析专用队列：同步文件/SQLite 读取不占用 Swift 协作线程池。
private let titleResolutionQueue = DispatchQueue(label: "com.jack.agentalarm.titles", qos: .userInitiated, attributes: .concurrent)

/// 只把 continuation 恢复一次，供解析结果与超时兜底竞争。
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<TitleResolution, Never>?
    init(_ continuation: CheckedContinuation<TitleResolution, Never>) { self.continuation = continuation }
    /// 返回 true 表示这次调用真的恢复了 continuation（即它赢得了与对手的竞争）。
    @discardableResult func resume(with value: TitleResolution) -> Bool {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
        return pending != nil
    }
}

/// 按到达顺序串行处理事件：在 socket 投递队列上同步构建任务链，主线程逐个执行。
private final class EventSequencer: @unchecked Sendable {
    private let lock = NSLock()
    private var tail: Task<Void, Never>?
    func enqueue(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        let previous = tail
        tail = Task { @MainActor in
            await previous?.value
            await AppModel.shared.handle(data)
        }
    }
}
private let eventSequencer = EventSequencer()

/// 事件管线：socket → 标题解析 → 等待列表 → 策略 → 声音/语音/日志。
@MainActor @Observable
final class AppModel {
    static let shared = AppModel()

    private(set) var waiting = WaitingList()
    private(set) var log: [LogEntry] = []
    private(set) var policy: AlertPolicy
    var lastError: String?
    /// 菜单栏图标是否被系统隐藏（菜单栏已满）；设置页据此显示提示。
    private(set) var menuBarIconHidden = false

    let settings: AppSettings
    let paths: AgentPaths
    let integrations: IntegrationStore

    @ObservationIgnored private let titleService: TitleService
    @ObservationIgnored private var server: SocketServer?
    @ObservationIgnored private let sound = SoundPlayer()
    @ObservationIgnored private let speech = SpeechQueue()
    @ObservationIgnored private let banner = BannerCenter()
    @ObservationIgnored private let menuBarMonitor = MenuBarVisibilityMonitor()
    @ObservationIgnored private let settingsWindow = SettingsWindowController()
    @ObservationIgnored private var didNotifyHiddenIcon = false
    @ObservationIgnored private let outputLogger = Logger(subsystem: "com.jack.agentalarm", category: "output")
    @ObservationIgnored private let logger = Logger(subsystem: "com.jack.agentalarm", category: "policy")
    @ObservationIgnored private let socketLogger = Logger(subsystem: "com.jack.agentalarm", category: "socket")

    var isPaused: Bool { policy.isPaused(at: Date()) }

    init(settings: AppSettings = .shared, paths: AgentPaths = .standard) {
        self.settings = settings
        self.paths = paths
        integrations = IntegrationStore(manager: AgentIntegrationManager(paths: paths), settings: settings)
        policy = AlertPolicy(settings: settings.policySettings)
        titleService = TitleService(claude: ClaudeTitleResolver(),
                                    codex: CodexTitleResolver(codexHome: paths.codexHome),
                                    gemini: GeminiTitleResolver())
    }

    func start() {
        integrations.repairSymlink()
        banner.requestAuthorization()
        do {
            try FileManager.default.createDirectory(at: paths.appSupport, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let server = SocketServer(path: paths.socket.path) { data in
                eventSequencer.enqueue(data)
            }
            try server.start()
            self.server = server
            socketLogger.info("listening at \(self.paths.socket.path, privacy: .public)")
        } catch SocketServer.ServerError.addressInUse {
            lastError = "另一个 AgentAlarm 实例已在运行（socket 被占用），本实例不会接收事件"
            socketLogger.error("socket already in use at \(self.paths.socket.path, privacy: .public)")
        } catch {
            lastError = "无法监听 socket：\(error)"
            socketLogger.error("listen failed: \(String(describing: error), privacy: .public)")
        }
        menuBarMonitor.onChange = { [weak self] state in self?.menuBarStateChanged(state) }
        menuBarMonitor.start()
    }

    func stop() {
        menuBarMonitor.stop()
        server?.stop()
        server = nil
    }

    func receive(_ data: Data) {
        eventSequencer.enqueue(data)
    }

    /// 由 EventSequencer 按到达顺序在主线程调用。
    func handle(_ data: Data) async {
        if let control = ControlCoding.decode(data) {
            handleControl(control)
            return
        }
        guard let event = try? EventCoding.decode(data) else {
            socketLogger.error("undecodable event, \(data.count) bytes")
            return
        }
        // 只有真实 hook 事件且是已支持的 Agent 才算接入已验证；test 合成事件不算。
        if event.source.hookEventName != "test", AgentNames.supported.contains(event.agent), !settings.isVerified(event.agent) {
            settings.markVerified(event.agent)
            integrations.refresh()
        }
        guard event.kind.isAlerting else {
            _ = waiting.apply(event, title: "", now: Date())
            record(event, title: "", outcome: "list: \(event.kind.rawValue)")
            logger.info("\(event.agent, privacy: .public)/\(event.kind.rawValue, privacy: .public) -> list: \(event.kind.rawValue, privacy: .public)")
            return
        }
        let resolution = await AppModel.resolveWithBudget(event, service: titleService)
        process(event, resolution: resolution)
    }

    /// 标题解析预算 1 秒：解析器在专用队列上同步执行，与计时器竞争，先到者胜；慢解析器的结果丢弃。
    nonisolated static func resolveWithBudget(_ event: AlarmEvent, service: TitleService, budget: TimeInterval = 1.0) async -> TitleResolution {
        await withCheckedContinuation { (continuation: CheckedContinuation<TitleResolution, Never>) in
            let once = ResumeOnce(continuation)
            titleResolutionQueue.async { once.resume(with: service.resolve(event)) }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + budget) {
                if once.resume(with: FallbackTitle.resolve(event)) {
                    titleLogger.warning("title budget exceeded for \(event.agent, privacy: .public)/\(event.sessionId, privacy: .public), using fallback")
                }
            }
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

    static let hiddenIconNotice = "AgentAlarm 的菜单栏图标被系统隐藏了（菜单栏已满）。腾出空间后会自动出现，也可以在终端运行 agentalarm settings 打开设置。"

    private func handleControl(_ message: ControlMessage) {
        switch message.control {
        case .openSettings:
            outputLogger.info("control: open settings")
            openSettings()
        }
    }

    /// 打开设置窗口并把 App 带到前台；菜单栏图标被隐藏时由 `agentalarm settings` 或横幅触发。
    func openSettings() {
        settingsWindow.show(model: self)
    }

    private func menuBarStateChanged(_ state: MenuBarVisibilityMonitor.State) {
        menuBarIconHidden = (state == .hidden)
        guard state == .hidden, !didNotifyHiddenIcon else { return }
        didNotifyHiddenIcon = true
        outputLogger.warning("menu bar icon hidden by the system; notifying the user once")
        if banner.authorized {
            banner.postNotice(id: "menu-bar-hidden", title: "AgentAlarm 菜单栏图标被隐藏",
                              body: AppModel.hiddenIconNotice, action: .openSettings)
        } else {
            previewSpeech(AppModel.hiddenIconNotice)
        }
    }

    /// 提醒发生后的扩展点，Task 20 在这里发系统横幅。
    var bannerAuthorized: Bool { banner.authorized }

    func didAlert(_ event: AlarmEvent, title: String) {
        guard settings.bannerEnabled else { return }
        banner.post(event: event, title: title)
    }

    private func record(_ event: AlarmEvent, title: String, outcome: String) {
        log.insert(LogEntry(date: Date(), agent: event.agent, kind: event.kind, title: title, outcome: outcome), at: 0)
        if log.count > 100 { log.removeLast(log.count - 100) }
    }

    func select(_ entry: WaitingEntry) {
        waiting.markSeen(id: entry.id)
        HostActivator.activate(entry.host)
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
