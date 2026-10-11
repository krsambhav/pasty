import Foundation
import SQLite3

public struct SQLiteError: Error, CustomStringConvertible, Sendable {
    public let code: Int32
    public let message: String

    public var description: String { "SQLite error \(code): \(message)" }
}

/// `SQLITE_TRANSIENT` isn't importable from Swift; this is its documented value.
private var SQLITE_TRANSIENT: sqlite3_destructor_type { unsafeBitCast(-1, to: sqlite3_destructor_type.self) }

/// A minimal, statement-caching SQLite connection.
///
/// Not thread-safe by design: it is owned and serialized by `ClipboardStore` (an actor).
final class SQLiteConnection {
    private var handle: OpaquePointer?
    private var statements: [String: Statement] = [:]

    init(path: String) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        var db: OpaquePointer?
        let result = sqlite3_open_v2(path, &db, flags, nil)
        guard result == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unable to open database"
            sqlite3_close(db)
            throw SQLiteError(code: result, message: message)
        }
        handle = db
        sqlite3_busy_timeout(db, 2_000)
    }

    deinit {
        statements.values.forEach { $0.finalize() }
        statements.removeAll()
        sqlite3_close_v2(handle)
    }

    var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(handle) }
    var changes: Int { Int(sqlite3_changes(handle)) }

    func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(handle, sql, nil, nil, &error)
        if result != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(error)
            throw SQLiteError(code: result, message: message)
        }
    }

    /// Returns a cached, reset prepared statement.
    func prepare(_ sql: String) throws -> Statement {
        if let cached = statements[sql] {
            cached.reset()
            return cached
        }
        var pointer: OpaquePointer?
        let result = sqlite3_prepare_v3(handle, sql, -1, UInt32(SQLITE_PREPARE_PERSISTENT), &pointer, nil)
        guard result == SQLITE_OK, let pointer else {
            throw SQLiteError(code: result, message: String(cString: sqlite3_errmsg(handle)))
        }
        let statement = Statement(pointer: pointer, connection: handle)
        statements[sql] = statement
        return statement
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let value = try body()
            try execute("COMMIT")
            return value
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func pragma(_ name: String) throws -> String? {
        try prepare("PRAGMA \(name)").firstRow { $0.string(0) }
    }
}

final class Statement {
    private let pointer: OpaquePointer
    private let connection: OpaquePointer?

    init(pointer: OpaquePointer, connection: OpaquePointer?) {
        self.pointer = pointer
        self.connection = connection
    }

    func finalize() { sqlite3_finalize(pointer) }

    func reset() {
        sqlite3_reset(pointer)
        sqlite3_clear_bindings(pointer)
    }

    @discardableResult
    func bind(_ values: SQLiteValue?...) -> Statement {
        for (offset, value) in values.enumerated() {
            bind(value, at: Int32(offset + 1))
        }
        return self
    }

    func bind(_ value: SQLiteValue?, at index: Int32) {
        switch value {
        case nil, .null?:
            sqlite3_bind_null(pointer, index)
        case let .integer(int)?:
            sqlite3_bind_int64(pointer, index, int)
        case let .real(double)?:
            sqlite3_bind_double(pointer, index, double)
        case let .text(string)?:
            sqlite3_bind_text(pointer, index, string, -1, SQLITE_TRANSIENT)
        case let .blob(data)?:
            _ = data.withUnsafeBytes { buffer in
                // A zero-length blob must still be non-NULL to stay a blob.
                if buffer.count == 0 {
                    sqlite3_bind_zeroblob(pointer, index, 0)
                } else {
                    sqlite3_bind_blob(pointer, index, buffer.baseAddress, Int32(buffer.count), SQLITE_TRANSIENT)
                }
            }
        }
    }

    /// Advances the statement. Returns `true` while rows are available.
    @discardableResult
    func step() throws -> Bool {
        let result = sqlite3_step(pointer)
        switch result {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw SQLiteError(code: result, message: String(cString: sqlite3_errmsg(connection)))
        }
    }

    /// Maps the first row (if any) and resets, so no read transaction is left open.
    func firstRow<T>(_ map: (Statement) -> T?) throws -> T? {
        defer { sqlite3_reset(pointer) }
        return try step() ? map(self) : nil
    }

    func run() throws {
        while try step() {}
    }

    func int(_ column: Int32) -> Int { Int(sqlite3_column_int64(pointer, column)) }
    func int64(_ column: Int32) -> Int64 { sqlite3_column_int64(pointer, column) }
    func double(_ column: Int32) -> Double { sqlite3_column_double(pointer, column) }
    func bool(_ column: Int32) -> Bool { sqlite3_column_int64(pointer, column) != 0 }
    func isNull(_ column: Int32) -> Bool { sqlite3_column_type(pointer, column) == SQLITE_NULL }

    func string(_ column: Int32) -> String? {
        guard let text = sqlite3_column_text(pointer, column) else { return nil }
        return String(cString: text)
    }

    func data(_ column: Int32) -> Data? {
        guard sqlite3_column_type(pointer, column) != SQLITE_NULL else { return nil }
        let count = Int(sqlite3_column_bytes(pointer, column))
        guard count > 0, let bytes = sqlite3_column_blob(pointer, column) else { return Data() }
        return Data(bytes: bytes, count: count)
    }
}

enum SQLiteValue {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)
}

extension SQLiteValue {
    static func int(_ value: Int) -> SQLiteValue { .integer(Int64(value)) }
    static func bool(_ value: Bool) -> SQLiteValue { .integer(value ? 1 : 0) }
    static func date(_ value: Date) -> SQLiteValue { .real(value.timeIntervalSince1970) }
    static func optionalText(_ value: String?) -> SQLiteValue { value.map(SQLiteValue.text) ?? .null }
}
