import Darwin
import Foundation
import OSLog

/// 监听 Unix socket，每个连接读取第一行 JSON 交给 handler。
/// handler 在全局队列上并发调用，且可能在 stop() 返回之后仍被调用一次。
public final class SocketServer: @unchecked Sendable {
    public enum ServerError: Error {
        case pathTooLong, create(Int32), bind(Int32), listen(Int32), permissions(Int32), alreadyStarted
    }

    private let path: String
    private let maxMessageBytes: Int
    private let handler: @Sendable (Data) -> Void
    private let queue = DispatchQueue(label: "com.jack.agentalarm.socket")
    private let logger = Logger(subsystem: "com.jack.agentalarm", category: "socket")
    private var source: DispatchSourceRead?

    public init(path: String, maxMessageBytes: Int = 65_536, handler: @escaping @Sendable (Data) -> Void) {
        self.path = path; self.maxMessageBytes = maxMessageBytes; self.handler = handler
    }

    public func start() throws {
        try queue.sync {
            guard source == nil else { throw ServerError.alreadyStarted }
            guard var address = UnixSocketAddress.make(path: path) else { throw ServerError.pathTooLong }
            unlink(path)
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw ServerError.create(errno) }
            // 用 umask 让 socket 文件一创建就是 0600，避免先 0755 再 chmod 的窗口。
            let previousMask = umask(0o077)
            let bound = UnixSocketAddress.withSockaddr(&address) { bind(fd, $0, $1) }
            let bindErrno = errno
            umask(previousMask)
            guard bound == 0 else { close(fd); throw ServerError.bind(bindErrno) }
            guard chmod(path, 0o600) == 0 else {
                let code = errno
                close(fd); unlink(path)
                throw ServerError.permissions(code)
            }
            guard listen(fd, 16) == 0 else {
                let code = errno
                close(fd); unlink(path)
                throw ServerError.listen(code)
            }
            let readSource = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            readSource.setEventHandler { [weak self] in self?.acceptOne(listenFD: fd) }
            readSource.setCancelHandler { close(fd) }
            readSource.resume()
            source = readSource
        }
    }

    /// 幂等；未 start 过时什么也不做。监听 fd 由 source 的 cancel handler 关闭。
    public func stop() {
        queue.sync {
            guard let source else { return }
            source.cancel()
            self.source = nil
            unlink(path)
        }
    }

    private func acceptOne(listenFD: Int32) {
        let client = accept(listenFD, nil, nil)
        guard client >= 0 else {
            logger.error("accept failed: errno \(errno)")
            return
        }
        var tv = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let handler = handler
        let limit = maxMessageBytes
        let logger = logger
        DispatchQueue.global(qos: .userInitiated).async {
            var data = Data()
            var chunk = [UInt8](repeating: 0, count: 4096)
            var overflow = false
            while true {
                let count = read(client, &chunk, chunk.count)
                if count <= 0 { break }
                data.append(contentsOf: chunk[0..<count])
                // +1 容纳行尾换行：恰好 limit 字节的一行加换行不算溢出。
                if data.count > limit + 1 { overflow = true; break }
            }
            close(client)
            if let newline = data.firstIndex(of: 0x0A) { data = data.prefix(upTo: newline) }
            guard !overflow, data.count <= limit else {
                logger.error("dropped oversized message: \(data.count) bytes, limit \(limit)")
                return
            }
            if !data.isEmpty { handler(data) }
        }
    }
}
