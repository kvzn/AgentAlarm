import Foundation

/// CLI 发给 App 的控制消息，与提醒事件走同一条 socket，靠顶层 "control" 键区分。
public struct ControlMessage: Codable, Sendable, Equatable {
    public enum Command: String, Codable, Sendable {
        case openSettings = "open_settings"
    }

    public var v: Int
    public var control: Command

    public init(control: Command) {
        v = 1
        self.control = control
    }
}

public enum ControlCoding {
    public static func encode(_ message: ControlMessage) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(message)
    }

    /// 只有顶层含 "control" 键且命令可识别时才返回消息；提醒事件与坏数据都返回 nil。
    public static func decode(_ data: Data) -> ControlMessage? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["control"] != nil else { return nil }
        return try? JSONDecoder().decode(ControlMessage.self, from: data)
    }
}
