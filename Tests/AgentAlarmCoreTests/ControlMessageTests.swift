import Foundation
import Testing
@testable import AgentAlarmCore

@Suite struct ControlMessageTests {
    @Test func encodesAsSingleLineWithSortedKeys() throws {
        let data = try ControlCoding.encode(ControlMessage(control: .openSettings))
        #expect(String(decoding: data, as: UTF8.self) == "{\"control\":\"open_settings\",\"v\":1}")
    }

    @Test func decodesOnlyControlMessages() throws {
        let message = ControlMessage(control: .openSettings)
        #expect(ControlCoding.decode(try ControlCoding.encode(message)) == message)
        let event = AlarmEvent(agent: "claude", kind: .turnComplete, sessionId: "S1")
        #expect(ControlCoding.decode(try EventCoding.encode(event)) == nil)
        #expect(ControlCoding.decode(Data("not json".utf8)) == nil)
        #expect(ControlCoding.decode(Data("{\"v\":1,\"control\":\"reboot\"}".utf8)) == nil)
    }
}
