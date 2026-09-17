import Foundation

/// CLI 的全部行为都通过这个环境注入，便于测试。
public struct CLIEnvironment: Sendable {
    public var arguments: [String]
    public var environment: [String: String]
    public var socketPath: String
    public var detectHost: @Sendable () -> HostInfo?
    public var readStdin: @Sendable () -> Data
    public var log: @Sendable (String) -> Void
    public var stdout: @Sendable (String) -> Void

    public init(arguments: [String], environment: [String: String], socketPath: String,
                detectHost: @escaping @Sendable () -> HostInfo?,
                readStdin: @escaping @Sendable () -> Data,
                log: @escaping @Sendable (String) -> Void,
                stdout: @escaping @Sendable (String) -> Void) {
        self.arguments = arguments; self.environment = environment; self.socketPath = socketPath
        self.detectHost = detectHost; self.readStdin = readStdin; self.log = log; self.stdout = stdout
    }
}

public enum CLICommands {
    public static let version = "0.1.0"

    public static let usage = """
    usage: agentalarm hook <claude|codex|gemini|opencode> [--payload <json>]
           agentalarm notify --agent <name> [--kind <kind>] [--title <text>] [--session-id <id>] [--cwd <dir>] [--message <text>]
           agentalarm test [--agent <name>]
           agentalarm status
           agentalarm settings
           agentalarm --version
    """

    public static func run(_ env: CLIEnvironment) -> Int32 {
        guard let command = env.arguments.first else { env.stdout(usage); return 2 }
        let rest = Array(env.arguments.dropFirst())
        switch command {
        case "--version", "version":
            env.stdout("agentalarm \(version)")
            return 0
        case "hook":
            runHook(rest, env)
            return 0
        case "notify":
            runNotify(rest, env)
            return 0
        case "test":
            return runTest(rest, env)
        case "status":
            return runStatus(env)
        case "settings":
            return runSettings(env)
        default:
            env.stdout(usage)
            return 2
        }
    }

    /// `--key value` 与 `--flag`（值为空串）。
    public static func options(_ args: [String]) -> [String: String] {
        var result: [String: String] = [:]
        var index = 0
        while index < args.count {
            let token = args[index]
            guard token.hasPrefix("--") else { index += 1; continue }
            let key = String(token.dropFirst(2))
            let next = index + 1 < args.count ? args[index + 1] : nil
            if let next, !next.hasPrefix("--") {
                result[key] = next
                index += 2
            } else {
                result[key] = ""
                index += 1
            }
        }
        return result
    }

    static func runHook(_ args: [String], _ env: CLIEnvironment) {
        guard let agent = args.first, let adapter = AdapterRegistry.adapter(for: agent) else {
            env.log("hook: unknown agent \(args.first ?? "<none>")")
            return
        }
        let opts = options(Array(args.dropFirst()))
        let raw = opts["payload"].map { Data($0.utf8) } ?? env.readStdin()
        guard let payload = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] else {
            env.log("hook: payload is not a JSON object")
            return
        }
        let context = AdapterContext(environment: env.environment, host: env.detectHost(), now: Date())
        guard let event = adapter.map(payload: payload, context: context) else {
            env.log("hook: no mapping for \(payload["hook_event_name"] ?? payload["kind"] ?? "?")")
            return
        }
        send(event, env)
    }

    static func runNotify(_ args: [String], _ env: CLIEnvironment) {
        let opts = options(args)
        guard let agent = opts["agent"], !agent.isEmpty else {
            env.log("notify: --agent is required")
            return
        }
        let kind = opts["kind"].flatMap(EventKind.init(rawValue:)) ?? .turnComplete
        let event = AlarmEvent(
            agent: agent, kind: kind,
            sessionId: opts["session-id"].flatMap { $0.isEmpty ? nil : $0 } ?? "notify-\(UUID().uuidString)",
            cwd: opts["cwd"] ?? FileManager.default.currentDirectoryPath,
            title: opts["title"], message: opts["message"],
            host: env.detectHost(),
            source: EventSource(hookEventName: "notify"))
        send(event, env)
    }

    static func runTest(_ args: [String], _ env: CLIEnvironment) -> Int32 {
        let opts = options(args)
        let event = AlarmEvent(
            agent: opts["agent"].flatMap { $0.isEmpty ? nil : $0 } ?? "claude",
            kind: .turnComplete,
            sessionId: "test-\(UUID().uuidString)",
            cwd: FileManager.default.currentDirectoryPath,
            title: "测试提醒",
            host: env.detectHost(),
            source: EventSource(hookEventName: "test"))
        let result = send(event, env)
        if result == .delivered {
            env.stdout("已送达 AgentAlarm")
            return 0
        }
        env.stdout("AgentAlarm 未运行或未响应（\(result)），socket: \(env.socketPath)")
        return 1
    }

    /// 请求运行中的 App 打开设置窗口；菜单栏图标被系统隐藏时这是唯一入口。
    static func runSettings(_ env: CLIEnvironment) -> Int32 {
        guard let data = try? ControlCoding.encode(ControlMessage(control: .openSettings)) else {
            env.stdout("内部错误：无法编码控制消息")
            return 1
        }
        let result = SocketClient(path: env.socketPath).send(data)
        env.log("settings -> \(result)")
        if result == .delivered {
            env.stdout("已请求 AgentAlarm 打开设置")
            return 0
        }
        env.stdout("AgentAlarm 未运行或未响应（\(result)），socket: \(env.socketPath)")
        return 1
    }

    static func runStatus(_ env: CLIEnvironment) -> Int32 {
        let reachable = SocketClient(path: env.socketPath).probe()
        env.stdout("\(reachable ? "reachable" : "unreachable"): \(env.socketPath)")
        return reachable ? 0 : 1
    }

    @discardableResult
    static func send(_ event: AlarmEvent, _ env: CLIEnvironment) -> SocketClient.SendResult {
        guard let data = try? EventCoding.encode(event) else {
            env.log("encode failed")
            return .unavailable
        }
        let result = SocketClient(path: env.socketPath).send(data)
        env.log("send \(event.agent)/\(event.kind.rawValue) -> \(result)")
        return result
    }
}
