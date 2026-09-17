import Foundation
import Testing
@testable import AgentAlarmCore

@Suite struct JSONHookInstallerTests {
    let marker = HookTemplates.marker(agent: "claude")
    let cli = "/Users/jack/.local/bin/agentalarm"

    func installer(_ dir: URL) -> JSONHookInstaller {
        JSONHookInstaller(backupDirectory: dir.appendingPathComponent("backups"),
                          timeSource: ManualTimeSource(now: Date(timeIntervalSince1970: 1_789_600_000)))
    }

    func readJSON(_ url: URL) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    @Test func commentDetectionIgnoresSlashesInsideStrings() {
        #expect(JSONHookInstaller.containsComments("{\n  // note\n  \"a\": 1\n}"))
        #expect(JSONHookInstaller.containsComments("{ \"a\": 1 /* x */ }"))
        #expect(!JSONHookInstaller.containsComments("{ \"url\": \"http://localhost:1/\", \"b\": \"a/*b\", \"c\": \"say \\\"//\\\"\" }"))
    }

    @Test func mergePreservesExistingHooksAndIsIdempotent() {
        let existing: [String: Any] = [
            "model": "opus",
            "hooks": ["Stop": [["matcher": "", "hooks": [["type": "command", "command": "echo hi"]]]]],
        ]
        let once = JSONHookInstaller.merge(hooks: HookTemplates.claude(cliPath: cli), into: existing, marker: marker)
        let twice = JSONHookInstaller.merge(hooks: HookTemplates.claude(cliPath: cli), into: once, marker: marker)
        #expect(once["model"] as? String == "opus")
        let stopGroups = (once["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]]
        #expect(stopGroups?.count == 2)
        #expect(((stopGroups?[0]["hooks"] as? [[String: Any]])?[0]["command"] as? String) == "echo hi")
        #expect(JSONHookInstaller.containsMarker(once, marker: marker))
        #expect(NSDictionary(dictionary: twice) == NSDictionary(dictionary: once))
    }

    @Test func removeIsPreciseAndCleansEmptyContainers() {
        let mixed: [String: Any] = [
            "hooks": [
                "Stop": [["matcher": "", "hooks": [
                    ["type": "command", "command": "echo hi"],
                    ["type": "command", "command": "\(cli) hook claude", "async": true],
                ]]],
                "SessionEnd": [["matcher": "", "hooks": [["type": "command", "command": "\(cli) hook claude"]]]],
            ],
            "other": true,
        ]
        let cleaned = JSONHookInstaller.remove(marker: marker, from: mixed)
        let hooks = cleaned["hooks"] as? [String: Any]
        #expect(hooks?["SessionEnd"] == nil)
        let stopHooks = ((hooks?["Stop"] as? [[String: Any]])?[0]["hooks"] as? [[String: Any]])
        #expect(stopHooks?.count == 1)
        #expect(cleaned["other"] as? Bool == true)
        let onlyOurs: [String: Any] = ["hooks": ["Stop": [["hooks": [["type": "command", "command": "\(cli) hook claude"]]]]]]
        #expect(JSONHookInstaller.remove(marker: marker, from: onlyOurs)["hooks"] == nil)
    }

    @Test func installCreatesFileBacksUpAndUninstallRestoresSemantics() throws {
        let dir = try makeTempDirectory()
        let file = dir.appendingPathComponent(".claude/settings.json")
        let inst = installer(dir)
        #expect(!inst.isInstalled(marker: marker, in: file))
        try inst.install(hooks: HookTemplates.claude(cliPath: cli), marker: marker, into: file)
        #expect(inst.isInstalled(marker: marker, in: file))
        #expect(try readJSON(file)["hooks"] != nil)
        let backupsAfterCreate = (try? FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("backups").path)) ?? []
        #expect(backupsAfterCreate.isEmpty, "文件原本不存在时没有备份")

        try "{\"model\":\"opus\",\"permissions\":{\"allow\":[\"Bash(ls)\"]}}".write(to: file, atomically: true, encoding: .utf8)
        try inst.install(hooks: HookTemplates.claude(cliPath: cli), marker: marker, into: file)
        let backups = try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("backups").path)
        #expect(backups.count == 1)
        #expect(backups[0].hasPrefix("settings.json."))
        try inst.uninstall(marker: marker, from: file)
        let restored = try readJSON(file)
        #expect(restored["hooks"] == nil)
        #expect(restored["model"] as? String == "opus")
        #expect(((restored["permissions"] as? [String: Any])?["allow"] as? [String]) == ["Bash(ls)"])
        #expect(!inst.isInstalled(marker: marker, in: file))
    }

    @Test func refusesFilesWithCommentsAndNonObjects() throws {
        let dir = try makeTempDirectory()
        let inst = installer(dir)
        let commented = dir.appendingPathComponent("c.json")
        try "{\n // hi\n \"a\": 1 }".write(to: commented, atomically: true, encoding: .utf8)
        #expect(inst.requiresManualEdit(fileURL: commented))
        #expect(throws: InstallerError.containsComments) {
            try inst.install(hooks: HookTemplates.claude(cliPath: cli), marker: marker, into: commented)
        }
        let array = dir.appendingPathComponent("a.json")
        try "[1,2]".write(to: array, atomically: true, encoding: .utf8)
        #expect(throws: InstallerError.rootNotObject) {
            try inst.install(hooks: HookTemplates.claude(cliPath: cli), marker: marker, into: array)
        }
        let badHooks = dir.appendingPathComponent("h.json")
        try "{\"hooks\": 5}".write(to: badHooks, atomically: true, encoding: .utf8)
        #expect(throws: InstallerError.hooksNotObject) {
            try inst.install(hooks: HookTemplates.claude(cliPath: cli), marker: marker, into: badHooks)
        }
    }

    @Test func backupsArePrunedToTen() throws {
        let dir = try makeTempDirectory()
        let file = dir.appendingPathComponent("settings.json")
        let clock = ManualTimeSource(now: Date(timeIntervalSince1970: 1_789_600_000))
        var inst = JSONHookInstaller(backupDirectory: dir.appendingPathComponent("backups"), timeSource: clock)
        inst.backupsToKeep = 3
        try "{}".write(to: file, atomically: true, encoding: .utf8)
        for _ in 0..<5 {
            try inst.install(hooks: HookTemplates.claude(cliPath: cli), marker: marker, into: file)
            try inst.uninstall(marker: marker, from: file)
            clock.advance(by: 1)
        }
        let backups = try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("backups").path)
        #expect(backups.count == 3)
    }
}
