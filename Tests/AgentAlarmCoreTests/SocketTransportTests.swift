import Foundation
import Testing
@testable import AgentAlarmCore

final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Data] = []
    let semaphore = DispatchSemaphore(value: 0)
    func append(_ data: Data) { lock.lock(); items.append(data); lock.unlock(); semaphore.signal() }
    var received: [Data] { lock.lock(); defer { lock.unlock() }; return items }
}

@Suite(.serialized) struct SocketTransportTests {
    func shortSocketPath() -> String { "/tmp/aa-\(UUID().uuidString.prefix(8)).sock" }

    @Test func roundTripDeliversOneEventPerConnection() throws {
        let path = shortSocketPath()
        let collector = Collector()
        let server = SocketServer(path: path) { collector.append($0) }
        try server.start()
        defer { server.stop() }
        let event = AlarmEvent(id: "E1", agent: "claude", kind: .turnComplete, sessionId: "S1", timestamp: Date(timeIntervalSince1970: 1_789_600_000))
        let client = SocketClient(path: path)
        #expect(client.send(try EventCoding.encode(event)) == .delivered)
        #expect(client.send(try EventCoding.encode(event)) == .delivered)
        #expect(collector.semaphore.wait(timeout: .now() + 2) == .success)
        #expect(collector.semaphore.wait(timeout: .now() + 2) == .success)
        #expect(collector.received.count == 2)
        #expect(try EventCoding.decode(collector.received[0]) == event)
        #expect(client.probe())
        var mode = stat()
        stat(path, &mode)
        #expect(mode.st_mode & 0o777 == 0o600)
    }

    @Test func serverKeepsOnlyFirstLineAndDropsOversized() throws {
        let path = shortSocketPath()
        let collector = Collector()
        let server = SocketServer(path: path, maxMessageBytes: 1024) { collector.append($0) }
        try server.start()
        defer { server.stop() }
        let client = SocketClient(path: path, maxMessageBytes: 1024)
        #expect(client.send(Data("{\"a\":1}\n{\"b\":2}\n".utf8)) == .delivered)
        #expect(collector.semaphore.wait(timeout: .now() + 2) == .success)
        #expect(String(decoding: collector.received[0], as: UTF8.self) == "{\"a\":1}")
        #expect(client.send(Data(repeating: 0x41, count: 2048)) == .tooLarge)
        #expect(collector.received.count == 1)
    }

    @Test func unavailableServerFailsFast() {
        let client = SocketClient(path: shortSocketPath())
        let started = Date()
        #expect(client.send(Data("{}".utf8)) == .unavailable)
        #expect(!client.probe())
        #expect(Date().timeIntervalSince(started) < 0.5)
    }

    @Test func tooLongPathIsRejected() {
        let long = "/tmp/" + String(repeating: "x", count: 120) + ".sock"
        #expect(throws: (any Error).self) { try SocketServer(path: long) { _ in }.start() }
        #expect(SocketClient(path: long).send(Data("{}".utf8)) == .unavailable)
    }
}
