import AgentAlarmCore
import Foundation

final class ExitCodeBox: @unchecked Sendable {
    var value: Int32 = 0
}

let debugEnabled = ProcessInfo.processInfo.environment["AGENTALARM_DEBUG"] == "1"
let cliEnvironment = CLIEnvironment(
    arguments: Array(CommandLine.arguments.dropFirst()),
    environment: ProcessInfo.processInfo.environment,
    socketPath: AgentPaths.standard.socket.path,
    detectHost: { ProcessTree.detectHost() },
    readStdin: { FileHandle.standardInput.readDataToEndOfFile() },
    log: { message in
        if debugEnabled { FileHandle.standardError.write(Data((message + "\n").utf8)) }
    },
    stdout: { line in FileHandle.standardOutput.write(Data((line + "\n").utf8)) })

let finished = DispatchSemaphore(value: 0)
let exitCode = ExitCodeBox()
DispatchQueue.global(qos: .userInitiated).async {
    exitCode.value = CLICommands.run(cliEnvironment)
    finished.signal()
}
let subcommand = cliEnvironment.arguments.first ?? ""
// 整体自我超时 1 秒：hook/notify 无论如何以 0 退出，绝不拖住 Agent；test/status 则如实报告未响应。
if finished.wait(timeout: .now() + 1.0) == .timedOut {
    cliEnvironment.log("timed out after 1s")
    if subcommand == "test" || subcommand == "status" || subcommand == "settings" {
        cliEnvironment.stdout("AgentAlarm 未响应（1 秒内无结果），socket: \(cliEnvironment.socketPath)")
        exit(1)
    }
    exit(0)
}
exit(exitCode.value)
