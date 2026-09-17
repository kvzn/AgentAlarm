import Foundation
import SQLite3

/// 只读 SQLite 查询，只取第一行。
public final class SQLiteReader {
    public enum ReaderError: Error, Equatable { case open(Int32), prepare(String), step(String) }
    private var db: OpaquePointer?

    public init(path: String) throws {
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil)
        guard rc == SQLITE_OK else {
            sqlite3_close(handle)
            throw ReaderError.open(rc)
        }
        db = handle
    }

    deinit { sqlite3_close(db) }

    public func firstRow(sql: String, bindings: [String]) throws -> [String: String?]? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ReaderError.prepare(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in bindings.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), value, -1, transient)
        }
        let rc = sqlite3_step(statement)
        if rc == SQLITE_DONE { return nil }
        guard rc == SQLITE_ROW else { throw ReaderError.step(String(cString: sqlite3_errmsg(db))) }
        var row: [String: String?] = [:]
        for column in 0..<sqlite3_column_count(statement) {
            let name = String(cString: sqlite3_column_name(statement, column))
            if let text = sqlite3_column_text(statement, column) {
                row[name] = String(cString: text)
            } else {
                row[name] = .some(nil)
            }
        }
        return row
    }
}
