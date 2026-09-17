import Foundation
import SQLite3
import Testing
@testable import AgentAlarmCore

@Suite struct CodexTitleResolverTests {
    static func createDatabase(at url: URL, sql: String) {
        var db: OpaquePointer?
        sqlite3_open(url.path, &db)
        sqlite3_exec(db, sql, nil, nil, nil)
        sqlite3_close(db)
    }

    func makeCodexHome() throws -> URL {
        let home = try makeTempDirectory()
        // 旧库：故意缺少 name 列，用来验证会选编号最大的库
        Self.createDatabase(at: home.appendingPathComponent("state_4.sqlite"),
                            sql: "CREATE TABLE threads(id TEXT PRIMARY KEY, title TEXT NOT NULL); INSERT INTO threads VALUES('T1','wrong old db');")
        Self.createDatabase(at: home.appendingPathComponent("state_5.sqlite"), sql: """
            CREATE TABLE threads(id TEXT PRIMARY KEY, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL,
              cwd TEXT NOT NULL, title TEXT NOT NULL, name TEXT, first_user_message TEXT);
            INSERT INTO threads VALUES('T1',1,1,'/Users/jack/Workspaces/LovedVoice','请仔细设计如下feature','越狱 iPad 发布门禁','请仔细设计如下feature');
            INSERT INTO threads VALUES('T2',1,1,'/Users/jack/Workspaces/ATTweak',
              '本机连接了一台越狱iPad mini，请在上面进行一轮发布门禁测试，并记录所有失败项目以及对应的截图证据。\n第二行', NULL, 'x');
            INSERT INTO threads VALUES('T3',1,1,'/tmp','',NULL,'  first message only  ');
            """)
        try "{\"id\":\"T9\",\"thread_name\":\"索引里的名字\",\"updated_at\":1}\n"
            .write(to: home.appendingPathComponent("session_index.jsonl"), atomically: true, encoding: .utf8)
        return home
    }

    func event(_ id: String) -> AlarmEvent {
        AlarmEvent(agent: "codex", kind: .turnComplete, sessionId: id, cwd: "/Users/jack/Workspaces/Fallback")
    }

    @Test func prefersUserAssignedName() throws {
        let r = CodexTitleResolver(codexHome: try makeCodexHome()).resolve(event("T1"))
        #expect(r == TitleResolution(title: "越狱 iPad 发布门禁", origin: .threadName))
    }

    @Test func fallsBackToTitleFirstLineTruncated() throws {
        let r = CodexTitleResolver(codexHome: try makeCodexHome()).resolve(event("T2"))
        #expect(r.origin == .threadTitle)
        #expect(r.title.count == 41)
        #expect(r.title.hasSuffix("…"))
        #expect(!r.title.contains("\n"))
    }

    @Test func fallsBackToFirstUserMessageWhenTitleEmpty() throws {
        let r = CodexTitleResolver(codexHome: try makeCodexHome()).resolve(event("T3"))
        #expect(r == TitleResolution(title: "first message only", origin: .firstMessage))
    }

    @Test func fallsBackToSessionIndexThenCwd() throws {
        let home = try makeCodexHome()
        #expect(CodexTitleResolver(codexHome: home).resolve(event("T9")) == TitleResolution(title: "索引里的名字", origin: .sessionIndex))
        #expect(CodexTitleResolver(codexHome: home).resolve(event("T404")) == TitleResolution(title: "Fallback", origin: .cwd))
        let emptyHome = try makeTempDirectory()
        #expect(CodexTitleResolver(codexHome: emptyHome).resolve(event("T1")).origin == .cwd)
    }

    @Test func sqliteReaderIsReadOnly() throws {
        let home = try makeCodexHome()
        let reader = try SQLiteReader(path: home.appendingPathComponent("state_5.sqlite").path)
        #expect(throws: (any Error).self) {
            _ = try reader.firstRow(sql: "INSERT INTO threads(id,created_at,updated_at,cwd,title) VALUES('X',1,1,'/','t')", bindings: [])
        }
        let row = try #require(try reader.firstRow(sql: "SELECT name FROM threads WHERE id = ?1", bindings: ["T2"]))
        #expect(row["name"] == .some(nil))
    }
}
