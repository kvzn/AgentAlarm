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
// 整体自我超时 1 秒：无论卡在 stdin 还是 socket，都以 0 退出，绝不拖住 Agent。
if finished.wait(timeout: .now() + 1.0) == .timedOut {
    cliEnvironment.log("timed out after 1s, exiting 0")
    exit(0)
}
exit(exitCode.value)
