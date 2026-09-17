import Foundation
import Testing
@testable import AgentAlarmCore

@Suite(.serialized) struct CLISettingsCommandTests {
    func environment(_ args: [String], socket: String, sink: OutputSink) -> CLIEnvironment {
        CLIEnvironment(arguments: args, environment: [:], socketPath: socket,
                       detectHost: { nil }, readStdin: { Data() },
                       log: { sink.log($0) }, stdout: { sink.out($0) })
    }

    @Test func settingsSendsOpenSettingsControlMessage() throws {
        let path = "/tmp/aa-\(UUID().uuidString.prefix(8)).sock"
        let collector = Collector()
        let server = SocketServer(path: path) { collector.append($0) }
        try server.start()
        defer { server.stop() }
        let sink = OutputSink()
        #expect(CLICommands.run(environment(["settings"], socket: path, sink: sink)) == 0)
        #expect(collector.semaphore.wait(timeout: .now() + 2) == .success)
        #expect(ControlCoding.decode(collector.received[0]) == ControlMessage(control: .openSettings))
        #expect(sink.lines.last == "已请求 AgentAlarm 打开设置")
    }

    @Test func settingsWhenAppUnavailableExitsOne() {
        let sink = OutputSink()
        let missing = "/tmp/aa-\(UUID().uuidString.prefix(8)).sock"
        #expect(CLICommands.run(environment(["settings"], socket: missing, sink: sink)) == 1)
        #expect(sink.lines.last?.hasPrefix("AgentAlarm 未运行或未响应") == true)
        #expect(CLICommands.usage.contains("agentalarm settings"))
    }
}
