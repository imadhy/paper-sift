import Foundation
import SQLite3

/// `SQLITE_TRANSIENT` is a C macro the Swift importer drops, so rebuild it by
/// hand: without it SQLite borrows the pointer we bind instead of copying it.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public struct SQLiteError: Error, CustomStringConvertible {
    public let code: Int32
    public let message: String
    public let sql: String?

    public var description: String {
        guard let sql else { return "SQLite error \(code): \(message)" }
        return "SQLite error \(code): \(message) — while running: \(sql)"
    }
}

/// A value bound to a `?` placeholder.
public enum SQLValue: Sendable, Equatable {
    case null
    case int(Int64)
    case double(Double)
    case text(String)
    case blob(Data)

    public static func bool(_ value: Bool) -> SQLValue { .int(value ? 1 : 0) }
    public static func date(_ value: Date) -> SQLValue { .double(value.timeIntervalSince1970) }
    public static func count(_ value: Int) -> SQLValue { .int(Int64(value)) }

    // Distinct names rather than optional-taking overloads of the cases above:
    // overloading a case name makes call sites ambiguous in surprising ways.
    public static func optionalText(_ value: String?) -> SQLValue { value.map(SQLValue.text) ?? .null }
    public static func optionalBlob(_ value: Data?) -> SQLValue { value.map(SQLValue.blob) ?? .null }
    public static func optionalDate(_ value: Date?) -> SQLValue { value.map(SQLValue.date) ?? .null }
}

/// One row of a result set. Only valid inside the decoding closure that receives
/// it — it reads straight out of the live statement.
public struct SQLRow {
    fileprivate let statement: OpaquePointer

    public func isNull(_ column: Int) -> Bool {
        sqlite3_column_type(statement, Int32(column)) == SQLITE_NULL
    }

    public func int64(_ column: Int) -> Int64 { sqlite3_column_int64(statement, Int32(column)) }
    public func int(_ column: Int) -> Int { Int(int64(column)) }
    public func double(_ column: Int) -> Double { sqlite3_column_double(statement, Int32(column)) }
    public func bool(_ column: Int) -> Bool { int64(column) != 0 }
    public func date(_ column: Int) -> Date { Date(timeIntervalSince1970: double(column)) }

    public func text(_ column: Int) -> String {
        guard let pointer = sqlite3_column_text(statement, Int32(column)) else { return "" }
        return String(cString: pointer)
    }

    public func optionalText(_ column: Int) -> String? {
        isNull(column) ? nil : text(column)
    }

    public func optionalDate(_ column: Int) -> Date? {
        isNull(column) ? nil : date(column)
    }

    public func blob(_ column: Int) -> Data {
        guard let pointer = sqlite3_column_blob(statement, Int32(column)) else { return Data() }
        return Data(bytes: pointer, count: Int(sqlite3_column_bytes(statement, Int32(column))))
    }

    public func optionalBlob(_ column: Int) -> Data? {
        isNull(column) ? nil : blob(column)
    }
}

/// A prepared statement. Finalized on deinit, so callers never have to remember.
final class SQLiteStatement {
    private let handle: OpaquePointer
    private let database: OpaquePointer
    private let sql: String

    init(database: OpaquePointer, sql: String) throws {
        var handle: OpaquePointer?
        let code = sqlite3_prepare_v2(database, sql, -1, &handle, nil)
        guard code == SQLITE_OK, let handle else {
            sqlite3_finalize(handle)
            throw SQLiteError(code: code, message: String(cString: sqlite3_errmsg(database)), sql: sql)
        }
        self.handle = handle
        self.database = database
        self.sql = sql
    }

    deinit { sqlite3_finalize(handle) }

    func bind(_ values: [SQLValue]) throws {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let code: Int32
            switch value {
            case .null:
                code = sqlite3_bind_null(handle, index)
            case .int(let number):
                code = sqlite3_bind_int64(handle, index, number)
            case .double(let number):
                code = sqlite3_bind_double(handle, index, number)
            case .text(let string):
                code = sqlite3_bind_text(handle, index, string, -1, SQLITE_TRANSIENT)
            case .blob(let data):
                code = data.isEmpty
                    ? sqlite3_bind_zeroblob(handle, index, 0)
                    : data.withUnsafeBytes { sqlite3_bind_blob(handle, index, $0.baseAddress, Int32(data.count), SQLITE_TRANSIENT) }
            }
            guard code == SQLITE_OK else { throw error(code) }
        }
    }

    /// Advances the cursor. `true` while a row is available.
    func step() throws -> Bool {
        let code = sqlite3_step(handle)
        switch code {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw error(code)
        }
    }

    var row: SQLRow { SQLRow(statement: handle) }

    private func error(_ code: Int32) -> SQLiteError {
        SQLiteError(code: code, message: String(cString: sqlite3_errmsg(database)), sql: sql)
    }
}

/// Thin wrapper over the system SQLite C API.
///
/// SwiftData needs the macro plugins that ship with Xcode — absent from the
/// Command Line Tools — and our needs fit in a handful of statements, so we talk
/// to sqlite3 directly. Deliberately **not** `Sendable`: the connection lives
/// inside `IndexStore`'s actor isolation and never escapes it.
final class SQLiteConnection {
    private let handle: OpaquePointer
    let path: String

    init(path: String) throws {
        var handle: OpaquePointer?
        // FULLMUTEX: the actor already serializes access, but it hops threads
        // across suspension points and serialized mode makes that a non-issue.
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let code = sqlite3_open_v2(path, &handle, flags, nil)
        guard code == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open \(path)"
            sqlite3_close(handle)
            throw SQLiteError(code: code, message: message, sql: nil)
        }
        self.handle = handle
        self.path = path
        sqlite3_busy_timeout(handle, 5_000)
    }

    deinit { sqlite3_close(handle) }

    /// Runs one or more statements with no bindings and no results.
    func execute(_ sql: String) throws {
        var raw: UnsafeMutablePointer<CChar>?
        let code = sqlite3_exec(handle, sql, nil, nil, &raw)
        guard code == SQLITE_OK else {
            let message = raw.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(handle))
            sqlite3_free(raw)
            throw SQLiteError(code: code, message: message, sql: sql)
        }
    }

    /// Runs a write statement and returns the rowid it inserted, if any.
    @discardableResult
    func run(_ sql: String, _ bindings: [SQLValue] = []) throws -> Int64 {
        let statement = try SQLiteStatement(database: handle, sql: sql)
        try statement.bind(bindings)
        while try statement.step() {}
        return sqlite3_last_insert_rowid(handle)
    }

    func query<T>(_ sql: String, _ bindings: [SQLValue] = [], _ decode: (SQLRow) throws -> T) throws -> [T] {
        let statement = try SQLiteStatement(database: handle, sql: sql)
        try statement.bind(bindings)
        var rows: [T] = []
        while try statement.step() { rows.append(try decode(statement.row)) }
        return rows
    }

    func first<T>(_ sql: String, _ bindings: [SQLValue] = [], _ decode: (SQLRow) throws -> T) throws -> T? {
        let statement = try SQLiteStatement(database: handle, sql: sql)
        try statement.bind(bindings)
        guard try statement.step() else { return nil }
        return try decode(statement.row)
    }

    func count(_ sql: String, _ bindings: [SQLValue] = []) throws -> Int {
        try first(sql, bindings) { $0.int(0) } ?? 0
    }

    /// `BEGIN IMMEDIATE` … `COMMIT`, rolling back on any thrown error.
    func transaction<T>(_ body: () throws -> T) throws -> T {
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

    func userVersion() throws -> Int {
        try first("PRAGMA user_version") { $0.int(0) } ?? 0
    }

    func setUserVersion(_ version: Int) throws {
        // PRAGMA values cannot be bound, and this one is an internal Int.
        try execute("PRAGMA user_version = \(version)")
    }
}
