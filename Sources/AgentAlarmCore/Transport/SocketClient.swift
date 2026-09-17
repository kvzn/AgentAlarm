import Darwin
import Foundation

enum UnixSocketAddress {
    static let maxPathBytes = 103

    static func make(path: String) -> sockaddr_un? {
        guard path.utf8.count <= maxPathBytes else { return nil }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        _ = path.withCString { strlcpy(&address.sun_path.0, $0, MemoryLayout.size(ofValue: address.sun_path)) }
        return address
    }

    static func withSockaddr<T>(_ address: inout sockaddr_un, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, length) }
        }
    }
}

/// 向 App 的 Unix socket 发送一行 JSON。
public struct SocketClient {
    /// `timedOut` 也可能出现在载荷已完整写入、只是没等到对端关闭的情况，此时事件多半已送达；调用方不得据此重试。
    public enum SendResult: Equatable, Sendable { case delivered, unavailable, timedOut, tooLarge }

    public var path: String
    public var timeout: TimeInterval
    public var maxMessageBytes: Int

    public init(path: String, timeout: TimeInterval = 0.5, maxMessageBytes: Int = 65_536) {
        self.path = path; self.timeout = timeout; self.maxMessageBytes = maxMessageBytes
    }

    public func send(_ data: Data) -> SendResult {
        guard data.count <= maxMessageBytes else { return .tooLarge }
        guard let fd = connect() else { return .unavailable }
        defer { close(fd) }
        var payload = data
        if payload.last != 0x0A { payload.append(0x0A) }
        let total = payload.count
        var offset = 0
        while offset < total {
            let written = payload.withUnsafeBytes { buffer -> Int in
                write(fd, buffer.baseAddress!.advanced(by: offset), total - offset)
            }
            if written <= 0 { return .timedOut }
            offset += written
        }
        shutdown(fd, SHUT_WR)
        var scratch = [UInt8](repeating: 0, count: 16)
        let read = Darwin.read(fd, &scratch, scratch.count)
        return read == 0 ? .delivered : .timedOut
    }

    public func probe() -> Bool {
        guard let fd = connect() else { return false }
        close(fd)
        return true
    }

    private func connect() -> Int32? {
        guard var address = UnixSocketAddress.make(path: path) else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - floor(timeout)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let rc = UnixSocketAddress.withSockaddr(&address) { Darwin.connect(fd, $0, $1) }
        guard rc == 0 else { close(fd); return nil }
        return fd
    }
}
