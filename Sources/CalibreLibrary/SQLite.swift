import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum SQLiteError: Error, LocalizedError {
    case open(String)
    case prepare(String, sql: String)
    case step(String, sql: String)

    public var errorDescription: String? {
        switch self {
        case .open(let message): return "Could not open metadata.db: \(message)"
        case .prepare(let message, let sql): return "SQL error: \(message) — \(sql)"
        case .step(let message, let sql): return "SQL execution error: \(message) — \(sql)"
        }
    }
}

public final class SQLiteDatabase {
    let handle: OpaquePointer

    public init(path: String, readOnly: Bool) throws {
        var handle: OpaquePointer?
        let flags = readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        guard sqlite3_open_v2(path, &handle, flags | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let handle
        else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            if let handle { sqlite3_close_v2(handle) }
            throw SQLiteError.open(message)
        }
        self.handle = handle
        sqlite3_busy_timeout(handle, 5000)
    }

    deinit {
        sqlite3_close_v2(handle)
    }

    var lastErrorMessage: String { String(cString: sqlite3_errmsg(handle)) }

    public func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? lastErrorMessage
            sqlite3_free(error)
            throw SQLiteError.step(message, sql: sql)
        }
    }

    public func prepare(_ sql: String) throws -> SQLiteStatement {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw SQLiteError.prepare(lastErrorMessage, sql: sql)
        }
        return SQLiteStatement(handle: statement, database: self, sql: sql)
    }

    /// Runs a query and maps every row.
    public func query<T>(_ sql: String, _ bindings: [SQLiteValue] = [], _ row: (SQLiteStatement) throws -> T) throws -> [T] {
        let statement = try prepare(sql)
        try statement.bind(bindings)
        var result: [T] = []
        while try statement.step() { result.append(try row(statement)) }
        return result
    }

    @discardableResult
    public func run(_ sql: String, _ bindings: [SQLiteValue] = []) throws -> Int64 {
        let statement = try prepare(sql)
        try statement.bind(bindings)
        while try statement.step() {}
        return sqlite3_last_insert_rowid(handle)
    }

    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }
}

public enum SQLiteValue {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)

    public static func text(_ value: String?) -> SQLiteValue {
        value.map { .text($0) } ?? .null
    }
}

public final class SQLiteStatement {
    let handle: OpaquePointer
    private let database: SQLiteDatabase
    private let sql: String

    init(handle: OpaquePointer, database: SQLiteDatabase, sql: String) {
        self.handle = handle
        self.database = database
        self.sql = sql
    }

    deinit {
        sqlite3_finalize(handle)
    }

    public func bind(_ values: [SQLiteValue]) throws {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .null: sqlite3_bind_null(handle, index)
            case .integer(let number): sqlite3_bind_int64(handle, index, number)
            case .real(let number): sqlite3_bind_double(handle, index, number)
            case .text(let string): sqlite3_bind_text(handle, index, string, -1, SQLITE_TRANSIENT)
            }
        }
    }

    /// True while rows are available.
    public func step() throws -> Bool {
        switch sqlite3_step(handle) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw SQLiteError.step(database.lastErrorMessage, sql: sql)
        }
    }

    public func int(_ column: Int32) -> Int64 { sqlite3_column_int64(handle, column) }
    public func double(_ column: Int32) -> Double { sqlite3_column_double(handle, column) }
    public func bool(_ column: Int32) -> Bool { sqlite3_column_int64(handle, column) != 0 }

    public func string(_ column: Int32) -> String? {
        guard let text = sqlite3_column_text(handle, column) else { return nil }
        return String(cString: text)
    }
}
