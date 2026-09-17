import Foundation
import Testing
@testable import AgentAlarmCore

enum TestSupportError: Error { case fixtureMissing(String) }

func fixtureURL(_ name: String) throws -> URL {
    guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures") else {
        throw TestSupportError.fixtureMissing(name)
    }
    return url
}

func fixtureData(_ name: String) throws -> Data {
    try Data(contentsOf: fixtureURL(name))
}

func fixtureJSON(_ name: String) throws -> [String: Any] {
    let object = try JSONSerialization.jsonObject(with: fixtureData(name))
    return try #require(object as? [String: Any])
}

func makeTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("agentalarm-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
