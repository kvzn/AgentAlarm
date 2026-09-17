import Darwin
import Foundation

/// 监听 Unix socket，每个连接读取第一行 JSON 交给 handler。
public final class SocketServer: @unchecked Sendable {
    public enum ServerError: Error { case pathTooLong, create(Int32), bind(Int32), listen(Int32) }

    private let path: String
    private let maxMessageBytes: Int
    private let handler: @Sendable (Data) -> Void
    private let queue = DispatchQueue(label: "com.jack.agentalarm.socket")
    private var listenFD: Int32 = -1
    private var source: DispatchSourceRead?

    public init(path: String, maxMessageBytes: Int = 65_536, handler: @escaping @Sendable (Data) -> Void) {
        self.path = path; self.maxMessageBytes = maxMessageBytes; self.handler = handler
    }

    public func start() throws {
        guard var address = UnixSocketAddress.make(path: path) else { throw ServerError.pathTooLong }
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ServerError.create(errno) }
        let bound = UnixSocketAddress.withSockaddr(&address) { bind(fd, $0, $1) }
        guard bound == 0 else { let code = errno; close(fd); throw ServerError.bind(code) }
        chmod(path, 0o600)
        guard listen(fd, 16) == 0 else { let code = errno; close(fd); throw ServerError.listen(code) }
        listenFD = fd
        let readSource = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        readSource.setEventHandler { [weak self] in self?.acceptOne() }
        readSource.resume()
        source = readSource
    }

    public func stop() {
        source?.cancel()
        source = nil
        if listenFD >= 0 { close(listenFD); listenFD = -1 }
        unlink(path)
    }

    private func acceptOne() {
        let client = accept(listenFD, nil, nil)
        guard client >= 0 else { return }
        var tv = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let handler = handler
        let limit = maxMessageBytes
        DispatchQueue.global(qos: .userInitiated).async {
            var data = Data()
            var chunk = [UInt8](repeating: 0, count: 4096)
            var overflow = false
            while true {
                let count = read(client, &chunk, chunk.count)
                if count <= 0 { break }
                data.append(contentsOf: chunk[0..<count])
                if data.count > limit { overflow = true; break }
            }
            close(client)
            guard !overflow else { return }
            if let newline = data.firstIndex(of: 0x0A) { data = data.prefix(upTo: newline) }
            if !data.isEmpty { handler(data) }
        }
    }
}
