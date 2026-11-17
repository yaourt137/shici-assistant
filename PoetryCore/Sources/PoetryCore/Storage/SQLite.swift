import Foundation
import SQLite3

public struct SQLiteError: Error, CustomStringConvertible {
    public let code: Int32
    public let message: String
    public let sql: String?

    public var description: String {
        if let sql { return "SQLite 错误 \(code)：\(message)（\(sql)）" }
        return "SQLite 错误 \(code)：\(message)"
    }
}

public enum SQLValue: Sendable, Hashable {
    case integer(Int64)
    case real(Double)
    case text(String)
    case null

    public static func optional(_ text: String?) -> SQLValue {
        text.map(SQLValue.text) ?? .null
    }

    public static func int(_ value: Int) -> SQLValue { .integer(Int64(value)) }
}

/// 极简 SQLite 封装：单连接、非线程安全，由调用方（actor 或主线程）保证串行访问。
public final class SQLiteDatabase {
    private var handle: OpaquePointer?
    public let path: String

    public init(path: String) throws(SQLiteError) {
        self.path = path
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let result = sqlite3_open_v2(path, &handle, flags, nil)
        guard result == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "无法打开数据库"
            sqlite3_close(handle)
            handle = nil
            throw SQLiteError(code: result, message: message, sql: nil)
        }
        sqlite3_busy_timeout(handle, 5_000)
        try execute("PRAGMA journal_mode = WAL")
        try execute("PRAGMA foreign_keys = ON")
    }

    deinit {
        sqlite3_close_v2(handle)
    }

    private func error(_ code: Int32, sql: String?) -> SQLiteError {
        SQLiteError(code: code, message: String(cString: sqlite3_errmsg(handle)), sql: sql)
    }

    public func execute(_ sql: String) throws(SQLiteError) {
        let result = sqlite3_exec(handle, sql, nil, nil, nil)
        guard result == SQLITE_OK else { throw error(result, sql: sql) }
    }

    public func run(_ sql: String, _ parameters: [SQLValue] = []) throws(SQLiteError) {
        let statement = try prepare(sql)
        try statement.bind(parameters)
        try statement.stepUntilDone()
    }

    public func query<T>(_ sql: String, _ parameters: [SQLValue] = [], _ map: (SQLRow) throws -> T) throws -> [T] {
        let statement = try prepare(sql)
        try statement.bind(parameters)
        var rows: [T] = []
        while try statement.step() {
            rows.append(try map(SQLRow(statement: statement)))
        }
        return rows
    }

    public func prepare(_ sql: String) throws(SQLiteError) -> SQLStatement {
        var pointer: OpaquePointer?
        let result = sqlite3_prepare_v2(handle, sql, -1, &pointer, nil)
        guard result == SQLITE_OK, let pointer else { throw error(result, sql: sql) }
        return SQLStatement(pointer: pointer, database: self, sql: sql)
    }

    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let value = try body()
            try execute("COMMIT")
            return value
        } catch {
            // 回滚失败时仍抛出原始错误；回滚错误本身无法补救，事务会在连接关闭时被丢弃。
            try? execute("ROLLBACK")
            throw error
        }
    }

    public var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(handle) }
    public var changes: Int { Int(sqlite3_changes(handle)) }

    fileprivate func makeError(_ code: Int32, sql: String) -> SQLiteError { error(code, sql: sql) }
}

public final class SQLStatement {
    fileprivate let pointer: OpaquePointer
    private let database: SQLiteDatabase
    private let sql: String

    fileprivate init(pointer: OpaquePointer, database: SQLiteDatabase, sql: String) {
        self.pointer = pointer
        self.database = database
        self.sql = sql
    }

    deinit {
        sqlite3_finalize(pointer)
    }

    /// SQLITE_TRANSIENT：让 SQLite 复制绑定的字符串。
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public func bind(_ parameters: [SQLValue]) throws(SQLiteError) {
        sqlite3_reset(pointer)
        sqlite3_clear_bindings(pointer)
        for (index, value) in parameters.enumerated() {
            let position = Int32(index + 1)
            let result: Int32
            switch value {
            case .integer(let number): result = sqlite3_bind_int64(pointer, position, number)
            case .real(let number): result = sqlite3_bind_double(pointer, position, number)
            case .text(let text): result = sqlite3_bind_text(pointer, position, text, -1, SQLStatement.transient)
            case .null: result = sqlite3_bind_null(pointer, position)
            }
            guard result == SQLITE_OK else { throw database.makeError(result, sql: sql) }
        }
    }

    /// 返回 true 表示取到一行。
    public func step() throws(SQLiteError) -> Bool {
        let result = sqlite3_step(pointer)
        switch result {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw database.makeError(result, sql: sql)
        }
    }

    public func stepUntilDone() throws(SQLiteError) {
        while try step() {}
    }

    /// 绑定参数并执行（用于批量插入时复用语句）。
    public func run(_ parameters: [SQLValue]) throws(SQLiteError) {
        try bind(parameters)
        try stepUntilDone()
    }
}

public struct SQLRow {
    fileprivate let statement: SQLStatement

    public func int(_ index: Int32) -> Int { Int(sqlite3_column_int64(statement.pointer, index)) }
    public func int64(_ index: Int32) -> Int64 { sqlite3_column_int64(statement.pointer, index) }
    public func double(_ index: Int32) -> Double { sqlite3_column_double(statement.pointer, index) }

    public func text(_ index: Int32) -> String {
        guard let pointer = sqlite3_column_text(statement.pointer, index) else { return "" }
        return String(cString: pointer)
    }

    public func optionalText(_ index: Int32) -> String? {
        guard sqlite3_column_type(statement.pointer, index) != SQLITE_NULL,
              let pointer = sqlite3_column_text(statement.pointer, index) else { return nil }
        return String(cString: pointer)
    }

    public func isNull(_ index: Int32) -> Bool {
        sqlite3_column_type(statement.pointer, index) == SQLITE_NULL
    }
}
