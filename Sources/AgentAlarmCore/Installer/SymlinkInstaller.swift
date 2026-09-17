import Foundation

public enum SymlinkStatus: Equatable, Sendable {
    case ok
    case missing
    case wrongTarget(String)
    case notASymlink
}

public enum SymlinkError: Error, Equatable {
    case pathIsNotSymlink
}

/// 维护 ~/.local/bin/agentalarm 指向 App 内 CLI 的软链接。
public struct SymlinkInstaller {
    public var fileManager: FileManager
    public init(fileManager: FileManager = .default) { self.fileManager = fileManager }

    public func status(link: URL, expectedTarget: URL) -> SymlinkStatus {
        guard let attributes = try? fileManager.attributesOfItem(atPath: link.path) else { return .missing }
        guard (attributes[.type] as? FileAttributeType) == .typeSymbolicLink else { return .notASymlink }
        guard let destination = try? fileManager.destinationOfSymbolicLink(atPath: link.path) else { return .missing }
        let resolved = URL(fileURLWithPath: destination, relativeTo: link.deletingLastPathComponent()).standardizedFileURL.path
        return resolved == expectedTarget.standardizedFileURL.path ? .ok : .wrongTarget(destination)
    }

    /// 返回 true 表示新建或替换了链接。
    @discardableResult
    public func ensure(link: URL, target: URL) throws -> Bool {
        switch status(link: link, expectedTarget: target) {
        case .ok:
            return false
        case .notASymlink:
            throw SymlinkError.pathIsNotSymlink
        case .missing, .wrongTarget:
            try fileManager.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            if (try? fileManager.attributesOfItem(atPath: link.path)) != nil {
                try fileManager.removeItem(at: link)
            }
            try fileManager.createSymbolicLink(at: link, withDestinationURL: target)
            return true
        }
    }
}
