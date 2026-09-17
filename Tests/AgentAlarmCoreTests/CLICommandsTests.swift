import Foundation
import Testing
@testable import AgentAlarmCore

final class OutputSink: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var lines: [String] = []
    private(set) var logs: [String] = []
    func out(_ s: String) { lock.lock(); lines.append(s); lock.unlock() }
    func log(_ s: String) { lock.lock(); logs.append(s); lock.unlock() }
}

@Suite(.serialized) struct CLICommandsTests {
    func environment(_ args: [String], socket: String, stdin: Data = Data(), sink: OutputSink) -> CLIEnvironment {
        CLIEnvironment(arguments: args, environment: ["CLAUDE_CODE_ENTRYPOINT": "cli"], socketPath: socket,
                       detectHost: { HostInfo(bundleId: "com.example.host", pid: 1, name: "Host") },
                       readStdin: { stdin }, log: { sink.log($0) }, stdout: { sink.out($0) })
    }

    @Test func optionsParsing() {
        let opts = CLICommands.options(["--agent", "MyBot", "--title", "Hello world", "--flag"])
        #expect(opts["agent"] == "MyBot")
        #expect(opts["title"] == "Hello world")
        #expect(opts["flag"] == "")
    }

    @Test func hookSendsMappedEventAndAlwaysExitsZero() throws {
        let path = "/tmp/aa-\(UUID().uuidString.prefix(8)).sock"
        let collector = Collector()
        let server = SocketServer(path: path) { collector.append($0) }
        try server.start()
        defer { server.stop() }
        let sink = OutputSink()
        let code = CLICommands.run(environment(["hook", "claude"], socket: path, stdin: try fixtureData("claude-stop.json"), sink: sink))
        #expect(code == 0)
        #expect(collector.semaphore.wait(timeout: .now() + 2) == .success)
        let event = try EventCoding.decode(collector.received[0])
        #expect(event.agent == "claude")
        #expect(event.kind == .turnComplete)
        #expect(event.host?.bundleId == "com.example.host")
        #expect(event.source.entrypoint == "cli")
        #expect(sink.lines.isEmpty, "hook 不能有 stdout")

        #expect(CLICommands.run(environment(["hook", "claude"], socket: path, stdin: Data("not json".utf8), sink: sink)) == 0)
        #expect(CLICommands.run(environment(["hook", "cursor"], socket: path, stdin: Data("{}".utf8), sink: sink)) == 0)
        var ignored = try fixtureJSON("claude-stop.json")
        ignored["hook_event_name"] = "PreToolUse"
        let ignoredData = try JSONSerialization.data(withJSONObject: ignored)
        #expect(CLICommands.run(environment(["hook", "claude"], socket: path, stdin: ignoredData, sink: sink)) == 0)
        #expect(collector.received.count == 1)
        #expect(sink.lines.isEmpty)
    }

    @Test func hookAcceptsPayloadOption() throws {
        let path = "/tmp/aa-\(UUID().uuidString.prefix(8)).sock"
        let collector = Collector()
        let server = SocketServer(path: path) { collector.append($0) }
        try server.start()
        defer { server.stop() }
        let payload = String(decoding: try fixtureData("opencode-idle.json"), as: UTF8.self)
        let code = CLICommands.run(environment(["hook", "opencode", "--payload", payload], socket: path, sink: OutputSink()))
        #expect(code == 0)
        #expect(collector.semaphore.wait(timeout: .now() + 2) == .success)
        #expect(try EventCoding.decode(collector.received[0]).title == "Add login page")
    }

    @Test func notifyBuildsGenericEvent() throws {
        let path = "/tmp/aa-\(UUID().uuidString.prefix(8)).sock"
        let collector = Collector()
        let server = SocketServer(path: path) { collector.append($0) }
        try server.start()
        defer { server.stop() }
        let sink = OutputSink()
        let code = CLICommands.run(environment(["notify", "--agent", "MyBot", "--kind", "needs_input", "--title", "Deploy?", "--cwd", "/x/Proj"], socket: path, sink: sink))
        #expect(code == 0)
        #expect(collector.semaphore.wait(timeout: .now() + 2) == .success)
        let event = try EventCoding.decode(collector.received[0])
        #expect(event.agent == "MyBot")
        #expect(event.kind == .needsInput)
        #expect(event.title == "Deploy?")
        #expect(event.cwd == "/x/Proj")
        #expect(event.sessionId.hasPrefix("notify-"))
        #expect(CLICommands.run(environment(["notify"], socket: path, sink: sink)) == 0, "缺少 --agent 也退出 0")
    }

    @Test func statusTestVersionAndUsage() throws {
        let missing = "/tmp/aa-\(UUID().uuidString.prefix(8)).sock"
        let sink = OutputSink()
        #expect(CLICommands.run(environment(["status"], socket: missing, sink: sink)) == 1)
        #expect(sink.lines.last?.hasPrefix("unreachable") == true)
        #expect(CLICommands.run(environment(["test"], socket: missing, sink: sink)) == 1)
        #expect(CLICommands.run(environment(["--version"], socket: missing, sink: sink)) == 0)
        #expect(sink.lines.last == "agentalarm \(CLICommands.version)")
        #expect(CLICommands.run(environment([], socket: missing, sink: sink)) == 2)
        #expect(CLICommands.run(environment(["bogus"], socket: missing, sink: sink)) == 2)

        let path = "/tmp/aa-\(UUID().uuidString.prefix(8)).sock"
        let collector = Collector()
        let server = SocketServer(path: path) { collector.append($0) }
        try server.start()
        defer { server.stop() }
        #expect(CLICommands.run(environment(["status"], socket: path, sink: sink)) == 0)
        #expect(CLICommands.run(environment(["test", "--agent", "codex"], socket: path, sink: sink)) == 0)
        #expect(collector.semaphore.wait(timeout: .now() + 2) == .success)
        let event = try EventCoding.decode(collector.received[0])
        #expect(event.agent == "codex")
        #expect(event.title == "测试提醒")
        #expect(sink.lines.last == "已送达 AgentAlarm")
    }
}
