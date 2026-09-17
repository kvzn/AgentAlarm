import AppKit
import OSLog

/// 检测 MenuBarExtra 的状态项是否被系统隐藏：菜单栏放不下时 macOS 会整体隐藏溢出的状态项，
/// 用户会以为 App 没有运行。探针实测：被隐藏的状态项窗口仍在 NSApp.windows 中，
/// 但 occlusionState 不含 .visible 且 isOnActiveSpace 为 false。
@MainActor
final class MenuBarVisibilityMonitor {
    enum State: Equatable { case unknown, visible, hidden }

    private(set) var state: State = .unknown
    var onChange: ((State) -> Void)?

    private let logger = Logger(subsystem: "com.jack.agentalarm", category: "output")
    private var timer: Timer?
    private var screenObserver: NSObjectProtocol?
    private var consecutiveOccluded = 0

    func start(initialDelay: TimeInterval = 3, interval: TimeInterval = 60) {
        DispatchQueue.main.asyncAfter(deadline: .now() + initialDelay) { [weak self] in
            self?.check()
        }
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.check() }
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.check() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
    }

    func check() {
        let classes = NSApp.windows.map { String(describing: type(of: $0)) }.joined(separator: ",")
        logger.info("windows: \(classes, privacy: .public)")
        guard let window = NSApp.windows.first(where: { String(describing: type(of: $0)).contains("StatusBarWindow") }) else {
            update(.unknown)
            return
        }
        let occluded = !window.occlusionState.contains(.visible)
        // 被刘海挤掉的状态项会被系统摆到刘海区域内；全屏 Space 里菜单栏整体隐藏时位置不变。
        // 有刘海：被遮挡且位于刘海区域 → 隐藏；无刘海：连续两次被遮挡才算隐藏，避免全屏误判。
        var inNotchGap = false
        if let screen = window.screen ?? NSScreen.main,
           let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            let midX = window.frame.midX - screen.frame.minX
            inNotchGap = midX > left.maxX && midX < right.minX
            logger.info("status item frame=\(String(describing: window.frame), privacy: .public) occluded=\(occluded) notchGap=\(left.maxX)...\(right.minX) inNotchGap=\(inNotchGap)")
        } else {
            logger.info("status item frame=\(String(describing: window.frame), privacy: .public) occluded=\(occluded) noNotch")
        }
        consecutiveOccluded = occluded ? consecutiveOccluded + 1 : 0
        let hidden = occluded && (inNotchGap || consecutiveOccluded >= 2)
        update(hidden ? .hidden : .visible)
    }

    private func update(_ newState: State) {
        guard newState != state else { return }
        state = newState
        logger.info("menu bar icon state -> \(String(describing: newState), privacy: .public)")
        onChange?(newState)
    }
}
