import Foundation
import Testing
@testable import AgentAlarmCore

@Suite struct SymlinkInstallerTests {
    @Test func createsRepairsAndReportsStatus() throws {
        let dir = try makeTempDirectory()
        let target = dir.appendingPathComponent("AgentAlarm.app/Contents/MacOS/agentalarm")
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "binary".write(to: target, atomically: true, encoding: .utf8)
        let other = dir.appendingPathComponent("other")
        try "x".write(to: other, atomically: true, encoding: .utf8)
        let link = dir.appendingPathComponent("bin/agentalarm")
        let installer = SymlinkInstaller()

        #expect(installer.status(link: link, expectedTarget: target) == .missing)
        #expect(try installer.ensure(link: link, target: target) == true)
        #expect(installer.status(link: link, expectedTarget: target) == .ok)
        #expect(try installer.ensure(link: link, target: target) == false)

        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: other)
        #expect(installer.status(link: link, expectedTarget: target) == .wrongTarget(other.path))
        #expect(try installer.ensure(link: link, target: target) == true)
        #expect(installer.status(link: link, expectedTarget: target) == .ok)
    }

    @Test func refusesMissingTargetAndReportsDangling() throws {
        let dir = try makeTempDirectory()
        let link = dir.appendingPathComponent("bin/agentalarm")
        let target = dir.appendingPathComponent("AgentAlarm.app/Contents/Helpers/agentalarm")
        let installer = SymlinkInstaller()
        #expect(throws: SymlinkError.targetMissing) { try installer.ensure(link: link, target: target) }
        #expect(installer.status(link: link, expectedTarget: target) == .missing)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "binary".write(to: target, atomically: true, encoding: .utf8)
        #expect(try installer.ensure(link: link, target: target) == true)
        try FileManager.default.removeItem(at: target)
        #expect(installer.status(link: link, expectedTarget: target) == .dangling(target.path))
    }

    @Test func refusesToReplaceRegularFile() throws {
        let dir = try makeTempDirectory()
        let link = dir.appendingPathComponent("agentalarm")
        try "real file".write(to: link, atomically: true, encoding: .utf8)
        let target = dir.appendingPathComponent("target")
        try "t".write(to: target, atomically: true, encoding: .utf8)
        let installer = SymlinkInstaller()
        #expect(installer.status(link: link, expectedTarget: target) == .notASymlink)
        #expect(throws: SymlinkError.pathIsNotSymlink) { try installer.ensure(link: link, target: target) }
        #expect(try String(contentsOf: link, encoding: .utf8) == "real file")
    }
}
