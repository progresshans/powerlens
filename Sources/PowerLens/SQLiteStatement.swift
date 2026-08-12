import Foundation
import SQLite3

enum SQLiteStatement {
    static func prepare(
        _ sql: String,
        using db: OpaquePointer,
        operation: String = "prepare statement"
    ) throws -> OpaquePointer {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else {
            throw error(operation: operation, result: result, using: db)
        }
        return statement
    }

    static func executePrepared(
        _ sql: String,
        using db: OpaquePointer,
        operation: String = "execute statement",
        binder: (OpaquePointer) throws -> Void
    ) throws {
        let statement = try prepare(
            sql,
            using: db,
            operation: "\(operation): prepare"
        )
        defer {
            sqlite3_finalize(statement)
        }

        try binder(statement)

        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE else {
            throw error(operation: operation, result: result, using: db)
        }
    }

    static func querySingleInt64(
        _ sql: String,
        using db: OpaquePointer,
        operation: String = "query value",
        binder: (OpaquePointer) -> Void
    ) throws -> Int64? {
        let statement = try prepare(
            sql,
            using: db,
            operation: "\(operation): prepare"
        )
        defer {
            sqlite3_finalize(statement)
        }

        binder(statement)

        let result = sqlite3_step(statement)
        if result == SQLITE_DONE {
            return nil
        }
        guard result == SQLITE_ROW else {
            throw error(operation: operation, result: result, using: db)
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

    static func optionalDoubleValue(_ statement: OpaquePointer?, index: Int32) -> Double? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else {
            return nil
        }
        return sqlite3_column_double(statement, index)
    }

    static func execute(
        _ sql: String,
        using db: OpaquePointer,
        operation: String = "execute SQL"
    ) throws {
        let result = sqlite3_exec(db, sql, nil, nil, nil)
        guard result == SQLITE_OK else {
            throw error(operation: operation, result: result, using: db)
        }
    }

    static func requireDone(
        _ result: Int32,
        using db: OpaquePointer,
        operation: String
    ) throws {
        guard result == SQLITE_DONE else {
            throw error(operation: operation, result: result, using: db)
        }
    }

    static func error(
        operation: String,
        result: Int32,
        using db: OpaquePointer
    ) -> HistoryStoreError {
        let extendedCode = sqlite3_extended_errcode(db)
        let code = extendedCode == SQLITE_OK ? result : extendedCode
        let message = String(cString: sqlite3_errmsg(db))
        return .sqlite(operation: operation, code: code, message: message)
    }
}

enum HistoryStoreError: Error, LocalizedError, Sendable {
    case fileSystem(operation: String, description: String)
    case sqlite(operation: String, code: Int32, message: String)
    case invalidConfiguration(String)

    var errorDescription: String? {
        switch self {
        case let .fileSystem(operation, description):
            "\(operation) failed: \(description)"
        case let .sqlite(operation, code, message):
            "\(operation) failed (SQLite \(code)): \(message)"
        case let .invalidConfiguration(description):
            description
        }
    }
}

private let transientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
