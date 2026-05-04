import Foundation
import SQLite3

enum SQLiteStatement {
    static func executePrepared(_ sql: String, using db: OpaquePointer, binder: (OpaquePointer) throws -> Void) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw HistoryStoreError.prepareFailed
        }

        defer {
            sqlite3_finalize(statement)
        }

        try binder(statement)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw HistoryStoreError.stepFailed
        }
    }

    static func querySingleInt64(_ sql: String, using db: OpaquePointer, binder: (OpaquePointer) -> Void) throws -> Int64? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw HistoryStoreError.prepareFailed
        }

        defer {
            sqlite3_finalize(statement)
        }

        binder(statement)

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }

        return sqlite3_column_int64(statement, 0)
    }

    static func bind(_ value: String?, to statement: OpaquePointer?, index: Int32) {
        guard let statement else { return }
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_text(statement, index, value, -1, transientDestructor)
    }

    static func bind(_ value: Int?, to statement: OpaquePointer?, index: Int32) {
        guard let statement else { return }
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_int64(statement, index, sqlite3_int64(value))
    }

    static func bind(_ value: Int64?, to statement: OpaquePointer?, index: Int32) {
        guard let statement else { return }
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_int64(statement, index, value)
    }

    static func textValue(_ statement: OpaquePointer?, index: Int32) -> String? {
        guard let cString = sqlite3_column_text(statement, index) else {
            return nil
        }
        return String(cString: cString)
    }

    static func optionalIntValue(_ statement: OpaquePointer?, index: Int32) -> Int? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else {
            return nil
        }
        return Int(sqlite3_column_int64(statement, index))
    }

    static func execute(_ sql: String, using db: OpaquePointer) {
        sqlite3_exec(db, sql, nil, nil, nil)
    }
}

enum HistoryStoreError: Error {
    case prepareFailed
    case stepFailed
}

private let transientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
