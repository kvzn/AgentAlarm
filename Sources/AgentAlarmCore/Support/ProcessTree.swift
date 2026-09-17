import Darwin
import Foundation

/// 沿父进程链向上找到宿主 .app，用于语音抑制和跳转。
public enum ProcessTree {
    public struct Ancestor: Equatable, Sendable {
        public var pid: pid_t
        public var path: String
        public init(pid: pid_t, path: String) { self.pid = pid; self.path = path }
    }

    public static func parentPid(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let parent = info.kp_eproc.e_ppid
        return parent > 0 ? parent : nil
    }

    public static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    public static func ancestors(from pid: pid_t = getpid(), limit: Int = 32) -> [Ancestor] {
        var result: [Ancestor] = []
        var current = parentPid(of: pid)
        while let candidate = current, result.count < limit {
            if let path = executablePath(of: candidate) {
                result.append(Ancestor(pid: candidate, path: path))
            }
            if candidate == 1 { break }
            current = parentPid(of: candidate)
        }
        return result
    }

    /// 取路径中第一个 ".app/Contents/" 之前的部分，即最外层 App。
    public static func appBundlePath(in executablePath: String) -> String? {
        guard let range = executablePath.range(of: ".app/Contents/") else { return nil }
        return String(executablePath[..<range.lowerBound]) + ".app"
    }

    public static func detectHost(from ancestors: [Ancestor],
                                  bundleReader: (String) -> (bundleId: String, name: String)?) -> HostInfo? {
        guard let firstIndex = ancestors.firstIndex(where: { appBundlePath(in: $0.path) != nil }),
              let bundlePath = appBundlePath(in: ancestors[firstIndex].path),
              let info = bundleReader(bundlePath) else { return nil }
        var pid = ancestors[firstIndex].pid
        for ancestor in ancestors[(firstIndex + 1)...] where appBundlePath(in: ancestor.path) == bundlePath {
            pid = ancestor.pid
        }
        return HostInfo(bundleId: info.bundleId, pid: pid, name: info.name)
    }

    public static func detectHost() -> HostInfo? {
        detectHost(from: ancestors(), bundleReader: readBundle)
    }

    static func readBundle(_ path: String) -> (bundleId: String, name: String)? {
        guard let bundle = Bundle(path: path), let identifier = bundle.bundleIdentifier else { return nil }
        let info = bundle.infoDictionary ?? [:]
        let name = (info["CFBundleDisplayName"] as? String)
            ?? (info["CFBundleName"] as? String)
            ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        return (identifier, name)
    }
}
