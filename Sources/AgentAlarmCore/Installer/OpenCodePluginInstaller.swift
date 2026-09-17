import Foundation

/// 生成并管理 ~/.config/opencode/plugins/agentalarm.ts。
public struct OpenCodePluginInstaller {
    public static let markerLine = "// AgentAlarm plugin v1, managed by AgentAlarm.app"
    public static let fileName = "agentalarm.ts"
    public var fileManager: FileManager

    public init(fileManager: FileManager = .default) { self.fileManager = fileManager }

    public static func pluginSource(cliPath: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let quotedPath = String(decoding: (try? encoder.encode(cliPath)) ?? Data("\"\"".utf8), as: UTF8.self)
        return """
        \(markerLine)
        // 由 AgentAlarm.app 生成，卸载时由 App 删除；手动修改会在下次接入时被覆盖。
        const CLI = \(quotedPath)

        export const AgentAlarmPlugin = async ({ client, $ }) => {
          const send = async (kind, sessionID, message) => {
            try {
              if (!sessionID) return
              const res = await client.session.get({ path: { id: sessionID } })
              const session = res && res.data ? res.data : null
              if (!session || session.parentID) return
              const payload = JSON.stringify({
                kind,
                sessionID,
                title: session.title ?? null,
                directory: session.directory ?? null,
                message: message ?? null,
              })
              await $`${CLI} hook opencode --payload ${payload}`.quiet().nothrow()
            } catch (_) {}
          }
          return {
            event: async ({ event }) => {
              const p = (event && event.properties) || {}
              switch (event.type) {
                case "session.idle":
                  await send("turn_complete", p.sessionID)
                  break
                case "permission.asked":
                  await send("needs_permission", p.sessionID, typeof p.permission === "string" ? p.permission : undefined)
                  break
                case "question.asked":
                  await send("needs_input", p.sessionID)
                  break
                case "session.status":
                  if (p.status && p.status.type === "busy") await send("resumed", p.sessionID)
                  break
                default:
                  break
              }
            },
          }
        }

        """
    }

    public func install(cliPath: String, pluginsDirectory: URL) throws {
        try fileManager.createDirectory(at: pluginsDirectory, withIntermediateDirectories: true)
        let file = pluginsDirectory.appendingPathComponent(Self.fileName)
        try Data(Self.pluginSource(cliPath: cliPath).utf8).write(to: file, options: .atomic)
    }

    public func uninstall(pluginsDirectory: URL) throws {
        guard isInstalled(pluginsDirectory: pluginsDirectory) else { return }
        try fileManager.removeItem(at: pluginsDirectory.appendingPathComponent(Self.fileName))
    }

    public func isInstalled(pluginsDirectory: URL) -> Bool {
        let file = pluginsDirectory.appendingPathComponent(Self.fileName)
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return false }
        return text.split(separator: "\n", omittingEmptySubsequences: false).first == Substring(Self.markerLine)
    }
}
