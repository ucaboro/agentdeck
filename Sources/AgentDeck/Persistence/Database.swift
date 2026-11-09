import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Minimal, dependency-free SQLite wrapper. All access is serialized on one queue.
final class Database: @unchecked Sendable {
    enum Value { case int(Int64), double(Double), text(String), null }

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "agentdeck.sqlite")

    init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw AgentDeckError.commandFailed("Could not open database at \(url.path)")
        }
        // Owner-only permissions: local session metadata should not be readable by other users.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        try exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA foreign_keys=ON;")
    }

    deinit { sqlite3_close(db) }

    func exec(_ sql: String) throws {
        try queue.sync {
            var err: UnsafeMutablePointer<CChar>?
            if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
                let msg = err.map { String(cString: $0) } ?? "unknown"
                sqlite3_free(err)
                throw AgentDeckError.commandFailed("SQLite: \(msg)")
            }
        }
    }

    @discardableResult
    func run(_ sql: String, _ params: [Value] = []) throws -> Int64 {
        try queue.sync {
            let stmt = try prepare(sql, params)
            defer { sqlite3_finalize(stmt) }
            let rc = sqlite3_step(stmt)
            guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw AgentDeckError.commandFailed("SQLite: \(String(cString: sqlite3_errmsg(db)))") }
            return sqlite3_last_insert_rowid(db)
        }
    }

    func query(_ sql: String, _ params: [Value] = []) throws -> [[String: Value]] {
        try queue.sync {
            let stmt = try prepare(sql, params)
            defer { sqlite3_finalize(stmt) }
            var rows: [[String: Value]] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                var row: [String: Value] = [:]
                for i in 0..<sqlite3_column_count(stmt) {
                    let name = String(cString: sqlite3_column_name(stmt, i))
                    switch sqlite3_column_type(stmt, i) {
                    case SQLITE_INTEGER: row[name] = .int(sqlite3_column_int64(stmt, i))
                    case SQLITE_FLOAT: row[name] = .double(sqlite3_column_double(stmt, i))
                    case SQLITE_TEXT: row[name] = .text(String(cString: sqlite3_column_text(stmt, i)))
                    default: row[name] = .null
                    }
                }
                rows.append(row)
            }
            return rows
        }
    }

    func transaction(_ body: () throws -> Void) throws {
        try exec("BEGIN")
        do { try body(); try exec("COMMIT") } catch { try? exec("ROLLBACK"); throw error }
    }

    private func prepare(_ sql: String, _ params: [Value]) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw AgentDeckError.commandFailed("SQLite prepare: \(String(cString: sqlite3_errmsg(db)))")
        }
        for (i, p) in params.enumerated() {
            let idx = Int32(i + 1)
            switch p {
            case .int(let v): sqlite3_bind_int64(stmt, idx, v)
            case .double(let v): sqlite3_bind_double(stmt, idx, v)
            case .text(let v): sqlite3_bind_text(stmt, idx, v, -1, SQLITE_TRANSIENT)
            case .null: sqlite3_bind_null(stmt, idx)
            }
        }
        return stmt
    }
}

extension Database.Value {
    var string: String? { if case .text(let s) = self { return s }; return nil }
    var int: Int64? {
        switch self { case .int(let v): return v; case .double(let d): return Int64(d); default: return nil }
    }
    var double: Double? {
        switch self { case .double(let d): return d; case .int(let v): return Double(v); default: return nil }
    }
    var date: Date? { double.map { Date(timeIntervalSince1970: $0) } }

    static func from(_ s: String?) -> Database.Value { s.map { .text($0) } ?? .null }
    static func from(_ d: Date?) -> Database.Value { d.map { .double($0.timeIntervalSince1970) } ?? .null }
    static func from(_ b: Bool) -> Database.Value { .int(b ? 1 : 0) }
}
