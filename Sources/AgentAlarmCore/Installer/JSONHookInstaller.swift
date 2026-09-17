import Foundation

public enum InstallerError: Error, Equatable {
    case containsComments
    case rootNotObject
    case hooksNotObject
    case eventNotArray(String)
}

/// 把 hook 条目幂等地合并进 JSON 配置文件，或精确移除；写前备份，原子写入。
public struct JSONHookInstaller {
    public var backupDirectory: URL
    public var fileManager: FileManager
    public var timeSource: any TimeSource
    public var backupsToKeep = 10

    public init(backupDirectory: URL, fileManager: FileManager = .default, timeSource: any TimeSource = SystemTimeSource()) {
        self.backupDirectory = backupDirectory; self.fileManager = fileManager; self.timeSource = timeSource
    }

    // MARK: 文件操作

    public func install(hooks: [String: Any], marker: String, into fileURL: URL) throws {
        let root = try readRoot(fileURL)
        let merged = try Self.mergeChecked(hooks: hooks, into: root, marker: marker)
        if fileManager.fileExists(atPath: fileURL.path), NSDictionary(dictionary: merged) == NSDictionary(dictionary: root) { return }
        try backupIfExists(fileURL)
        try write(merged, to: fileURL)
    }

    public func uninstall(marker: String, from fileURL: URL) throws {
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        let root = try readRoot(fileURL)
        let cleaned = Self.remove(marker: marker, from: root)
        if NSDictionary(dictionary: cleaned) == NSDictionary(dictionary: root) { return }
        try backupIfExists(fileURL)
        try write(cleaned, to: fileURL)
    }

    public func isInstalled(marker: String, in fileURL: URL) -> Bool {
        guard let root = try? readRoot(fileURL) else { return false }
        return Self.containsMarker(root, marker: marker)
    }

    public func requiresManualEdit(fileURL: URL) -> Bool {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return false }
        return Self.containsComments(text)
    }

    private func readRoot(_ fileURL: URL) throws -> [String: Any] {
        guard fileManager.fileExists(atPath: fileURL.path) else { return [:] }
        let text = try String(contentsOf: fileURL, encoding: .utf8)
        if Self.containsComments(text) { throw InstallerError.containsComments }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [:] }
        guard let root = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            throw InstallerError.rootNotObject
        }
        if let hooks = root["hooks"], !(hooks is [String: Any]) { throw InstallerError.hooksNotObject }
        return root
    }

    private func write(_ root: [String: Any], to fileURL: URL) throws {
        try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        data.append(0x0A)
        try data.write(to: fileURL, options: .atomic)
    }

    private func backupIfExists(_ fileURL: URL) throws {
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        try fileManager.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let parent = fileURL.deletingLastPathComponent().lastPathComponent
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let prefix = "\(parent)-\(fileURL.lastPathComponent)"
        let target = backupDirectory.appendingPathComponent("\(prefix).\(formatter.string(from: timeSource.now))")
        if fileManager.fileExists(atPath: target.path) { try fileManager.removeItem(at: target) }
        try fileManager.copyItem(at: fileURL, to: target)
        let siblings = (try? fileManager.contentsOfDirectory(atPath: backupDirectory.path))?
            .filter { $0.hasPrefix("\(prefix).") }.sorted(by: >) ?? []
        for stale in siblings.dropFirst(backupsToKeep) {
            try? fileManager.removeItem(at: backupDirectory.appendingPathComponent(stale))
        }
    }

    // MARK: 纯函数

    /// 字符串外出现 // 或 /* 即视为含注释。
    public static func containsComments(_ text: String) -> Bool {
        var inString = false
        var escaped = false
        var previous: Character = " "
        for char in text {
            if inString {
                if escaped { escaped = false }
                else if char == "\\" { escaped = true }
                else if char == "\"" { inString = false }
            } else {
                if char == "\"" { inString = true }
                else if previous == "/" && (char == "/" || char == "*") { return true }
            }
            previous = char
        }
        return false
    }

    static func mergeChecked(hooks: [String: Any], into root: [String: Any], marker: String) throws -> [String: Any] {
        if let existing = root["hooks"], !(existing is [String: Any]) { throw InstallerError.hooksNotObject }
        let existingHooks = root["hooks"] as? [String: Any] ?? [:]
        for event in hooks.keys {
            if let value = existingHooks[event], !(value is [Any]) { throw InstallerError.eventNotArray(event) }
        }
        return merge(hooks: hooks, into: root, marker: marker)
    }

    public static func merge(hooks: [String: Any], into root: [String: Any], marker: String) -> [String: Any] {
        var result = root
        var hooksDict = root["hooks"] as? [String: Any] ?? [:]
        for (event, value) in hooks {
            if let existing = hooksDict[event], !(existing is [Any]) { continue }
            let newGroups = value as? [Any] ?? []
            var groups = hooksDict[event] as? [Any] ?? []
            if !groups.contains(where: { groupContainsMarker($0, marker: marker) }) {
                groups.append(contentsOf: newGroups)
            }
            hooksDict[event] = groups
        }
        result["hooks"] = hooksDict
        return result
    }

    public static func remove(marker: String, from root: [String: Any]) -> [String: Any] {
        var result = root
        guard var hooksDict = root["hooks"] as? [String: Any] else { return result }
        for (event, value) in hooksDict {
            guard let groups = value as? [Any] else { continue }
            let kept: [Any] = groups.compactMap { group in
                guard var dict = group as? [String: Any], let hooks = dict["hooks"] as? [Any] else { return group }
                let remaining = hooks.filter { !hookContainsMarker($0, marker: marker) }
                if remaining.isEmpty { return nil }
                dict["hooks"] = remaining
                return dict
            }
            if kept.isEmpty { hooksDict.removeValue(forKey: event) } else { hooksDict[event] = kept }
        }
        if hooksDict.isEmpty { result.removeValue(forKey: "hooks") } else { result["hooks"] = hooksDict }
        return result
    }

    public static func containsMarker(_ root: [String: Any], marker: String) -> Bool {
        guard let hooksDict = root["hooks"] as? [String: Any] else { return false }
        return hooksDict.values.contains { value in
            (value as? [Any] ?? []).contains { groupContainsMarker($0, marker: marker) }
        }
    }

    static func groupContainsMarker(_ group: Any, marker: String) -> Bool {
        guard let dict = group as? [String: Any], let hooks = dict["hooks"] as? [Any] else { return false }
        return hooks.contains { hookContainsMarker($0, marker: marker) }
    }

    static func hookContainsMarker(_ hook: Any, marker: String) -> Bool {
        guard let dict = hook as? [String: Any], let command = dict["command"] as? String else { return false }
        // cliPath 含空格时 command 会被单引号包裹，比较前去掉引号。
        return command.replacingOccurrences(of: "'", with: "").contains(marker)
    }
}
