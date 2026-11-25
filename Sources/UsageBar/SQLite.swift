import Foundation
import SQLite3

/// Minimal wrapper over the system libsqlite3 — just what the usage ledger
/// needs (prepared statements, transactions). Not shared across threads:
/// each owner guards its connection with its own lock.
final class SQLiteDB {
    struct Failure: LocalizedError {
        let message: String
        let code: Int32
        var errorDescription: String? { "SQLite \(code): \(message)" }
    }

    private(set) var handle: OpaquePointer?

    /// - Parameter readOnly: open without creating or writing.
    /// - Parameter create: create the file when missing (read-write only).
    init(path: String, readOnly: Bool = false, create: Bool = true, busyTimeoutMs: Int32 = 5_000) throws {
        let flags = (readOnly ? SQLITE_OPEN_READONLY
                     : SQLITE_OPEN_READWRITE | (create ? SQLITE_OPEN_CREATE : 0))
            | SQLITE_OPEN_FULLMUTEX
        var db: OpaquePointer?
        let rc = sqlite3_open_v2(path, &db, flags, nil)
        guard rc == SQLITE_OK, let db else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open 실패"
            sqlite3_close(db)
            throw Failure(message: msg, code: rc)
        }
        handle = db
        sqlite3_busy_timeout(db, busyTimeoutMs)
    }

    deinit { sqlite3_close(handle) }

    func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? lastMessage
            sqlite3_free(err)
            throw Failure(message: msg, code: rc)
        }
    }

    func prepare(_ sql: String) throws -> Statement {
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(handle, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else { throw Failure(message: lastMessage, code: rc) }
        return Statement(stmt, db: self)
    }

    /// Rows changed by the last INSERT/UPDATE/DELETE.
    var changes: Int32 { sqlite3_changes(handle) }

    /// `BEGIN IMMEDIATE` (takes the write lock up front, so two processes
    /// scanning at once serialize instead of deadlocking on upgrade) …
    /// COMMIT, or ROLLBACK when `body` throws.
    func immediateTransaction<T>(_ body: () throws -> T) throws -> T {
        try exec("BEGIN IMMEDIATE")
        do {
            let value = try body()
            try exec("COMMIT")
            return value
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    var lastMessage: String { String(cString: sqlite3_errmsg(handle)) }

    final class Statement {
        private let stmt: OpaquePointer
        private let db: SQLiteDB

        fileprivate init(_ stmt: OpaquePointer, db: SQLiteDB) {
            self.stmt = stmt
            self.db = db
        }

        deinit { sqlite3_finalize(stmt) }

        /// SQLITE_TRANSIENT: sqlite copies the bytes before bind returns.
        private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

        @discardableResult
        func bind(_ values: [Value]) -> Statement {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            for (i, v) in values.enumerated() {
                let idx = Int32(i + 1)
                switch v {
                case .int(let n): sqlite3_bind_int64(stmt, idx, n)
                case .double(let d): sqlite3_bind_double(stmt, idx, d)
                case .text(let s): sqlite3_bind_text(stmt, idx, s, -1, Self.transient)
                case .null: sqlite3_bind_null(stmt, idx)
                }
            }
            return self
        }

        /// Run to completion (statements without result rows).
        func run(_ values: [Value] = []) throws {
            bind(values)
            let rc = sqlite3_step(stmt)
            sqlite3_reset(stmt)
            guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
                throw Failure(message: db.lastMessage, code: rc)
            }
        }

        /// Every result row, mapped.
        func query<T>(_ values: [Value] = [], _ map: (Row) -> T?) throws -> [T] {
            bind(values)
            defer { sqlite3_reset(stmt) }
            var out: [T] = []
            while true {
                let rc = sqlite3_step(stmt)
                if rc == SQLITE_DONE { break }
                guard rc == SQLITE_ROW else { throw Failure(message: db.lastMessage, code: rc) }
                if let v = map(Row(stmt: stmt)) { out.append(v) }
            }
            return out
        }
    }

    enum Value {
        case int(Int64)
        case double(Double)
        case text(String)
        case null
    }

    struct Row {
        fileprivate let stmt: OpaquePointer

        func int(_ i: Int32) -> Int64 { sqlite3_column_int64(stmt, i) }
        func double(_ i: Int32) -> Double { sqlite3_column_double(stmt, i) }
        func text(_ i: Int32) -> String? {
            sqlite3_column_text(stmt, i).map { String(cString: $0) }
        }
        func isNull(_ i: Int32) -> Bool { sqlite3_column_type(stmt, i) == SQLITE_NULL }
    }
}
