//
//  QMemoryStore.swift
//  leanring-buddy
//
//  Q Security Architecture — SQLite WAL Memory Foundation (Phase 1D.8).
//  Provides robust SQLite persistence with WAL mode, schema versioning,
//  provenance binding, and concurrent lexical retrieval.
//

import Foundation
import SQLite3

// MARK: - Memory Record

public struct QMemoryRecord: Sendable, Equatable {
    public let recordId: String
    public let sessionId: String
    public let taskId: String?
    public let key: String
    public let content: String
    public let provenanceKind: String
    public let provenanceSource: String
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        recordId: String = UUID().uuidString,
        sessionId: String,
        taskId: String? = nil,
        key: String,
        content: String,
        provenanceKind: String = "trusted:user",
        provenanceSource: String = "direct",
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.recordId = recordId
        self.sessionId = sessionId
        self.taskId = taskId
        self.key = key
        self.content = content
        self.provenanceKind = provenanceKind
        self.provenanceSource = provenanceSource
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// MARK: - Memory Store Protocol

public protocol QMemoryStore: Sendable {
    func insert(record: QMemoryRecord) throws
    func update(record: QMemoryRecord) throws
    func get(recordId: String) throws -> QMemoryRecord?
    func getByKey(_ key: String, sessionId: String) throws -> QMemoryRecord?
    func query(text: String, sessionId: String?, limit: Int) throws -> [QMemoryRecord]
    func listRecent(sessionId: String?, limit: Int) throws -> [QMemoryRecord]
    func delete(recordId: String) throws
}

// MARK: - SQLite Implementation

public final class QSQLiteMemoryStore: QMemoryStore, QMemoryProvider, @unchecked Sendable {
    private var db: OpaquePointer?
    private let dbPath: String
    private let lock = NSRecursiveLock()

    public init(databasePath: String = ":memory:") throws {
        self.dbPath = databasePath
        try openDatabase()
        try applyMigrations()
    }

    deinit {
        lock.lock()
        if let db {
            sqlite3_close(db)
        }
        lock.unlock()
    }

    private func openDatabase() throws {
        lock.lock()
        defer { lock.unlock() }

        var flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        if dbPath == ":memory:" {
            flags |= SQLITE_OPEN_MEMORY
        } else {
            let dir = (dbPath as NSString).deletingLastPathComponent
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }

        if sqlite3_open_v2(dbPath, &db, flags, nil) != SQLITE_OK {
            let errMsg = String(cString: sqlite3_errmsg(db))
            throw QMemoryError.databaseOpenFailed(errMsg)
        }

        // Enable WAL mode and Busy Timeout
        execSimpleSQL("PRAGMA journal_mode=WAL;")
        execSimpleSQL("PRAGMA synchronous=NORMAL;")
        execSimpleSQL("PRAGMA busy_timeout=5000;")
    }

    private func execSimpleSQL(_ sql: String) {
        var err: UnsafeMutablePointer<CChar>?
        sqlite3_exec(db, sql, nil, nil, &err)
        if let err {
            sqlite3_free(err)
        }
    }

    private func applyMigrations() throws {
        lock.lock()
        defer { lock.unlock() }

        execSimpleSQL("""
        CREATE TABLE IF NOT EXISTS schema_migrations (
            version INTEGER PRIMARY KEY,
            applied_at TEXT NOT NULL
        );
        """)

        // Migration 1: Memory records table
        execSimpleSQL("""
        CREATE TABLE IF NOT EXISTS memory_records (
            record_id TEXT PRIMARY KEY,
            session_id TEXT NOT NULL,
            task_id TEXT,
            key TEXT NOT NULL,
            content TEXT NOT NULL,
            provenance_kind TEXT NOT NULL,
            provenance_source TEXT NOT NULL,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_mem_session ON memory_records(session_id);
        CREATE INDEX IF NOT EXISTS idx_mem_key ON memory_records(key);
        """)
    }

    // MARK: - CRUD Operations

    public func insert(record: QMemoryRecord) throws {
        lock.lock()
        defer { lock.unlock() }

        let sql = """
        INSERT OR REPLACE INTO memory_records (
            record_id, session_id, task_id, key, content,
            provenance_kind, provenance_source, created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw QMemoryError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, (record.recordId as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (record.sessionId as NSString).utf8String, -1, nil)
        if let tid = record.taskId {
            sqlite3_bind_text(stmt, 3, (tid as NSString).utf8String, -1, nil)
        } else {
            sqlite3_bind_null(stmt, 3)
        }
        sqlite3_bind_text(stmt, 4, (record.key as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 5, (record.content as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 6, (record.provenanceKind as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 7, (record.provenanceSource as NSString).utf8String, -1, nil)
        sqlite3_bind_double(stmt, 8, record.createdAt.timeIntervalSince1970)
        sqlite3_bind_double(stmt, 9, record.updatedAt.timeIntervalSince1970)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw QMemoryError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    public func update(record: QMemoryRecord) throws {
        try insert(record: record)
    }

    public func get(recordId: String) throws -> QMemoryRecord? {
        lock.lock()
        defer { lock.unlock() }

        let sql = "SELECT record_id, session_id, task_id, key, content, provenance_kind, provenance_source, created_at, updated_at FROM memory_records WHERE record_id = ? LIMIT 1;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw QMemoryError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, (recordId as NSString).utf8String, -1, nil)
        if sqlite3_step(stmt) == SQLITE_ROW {
            return parseRecord(from: stmt!)
        }
        return nil
    }

    public func getByKey(_ key: String, sessionId: String) throws -> QMemoryRecord? {
        lock.lock()
        defer { lock.unlock() }

        let sql = "SELECT record_id, session_id, task_id, key, content, provenance_kind, provenance_source, created_at, updated_at FROM memory_records WHERE key = ? AND session_id = ? ORDER BY updated_at DESC LIMIT 1;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw QMemoryError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, (key as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (sessionId as NSString).utf8String, -1, nil)

        if sqlite3_step(stmt) == SQLITE_ROW {
            return parseRecord(from: stmt!)
        }
        return nil
    }

    public func query(text: String, sessionId: String? = nil, limit: Int = 20) throws -> [QMemoryRecord] {
        lock.lock()
        defer { lock.unlock() }

        let sql: String
        if let sessionId {
            sql = "SELECT record_id, session_id, task_id, key, content, provenance_kind, provenance_source, created_at, updated_at FROM memory_records WHERE session_id = ? AND (content LIKE ? OR key LIKE ?) ORDER BY updated_at DESC LIMIT ?;"
        } else {
            sql = "SELECT record_id, session_id, task_id, key, content, provenance_kind, provenance_source, created_at, updated_at FROM memory_records WHERE (content LIKE ? OR key LIKE ?) ORDER BY updated_at DESC LIMIT ?;"
        }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw QMemoryError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        let pattern = "%\(text)%"
        if let sessionId {
            sqlite3_bind_text(stmt, 1, (sessionId as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (pattern as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 3, (pattern as NSString).utf8String, -1, nil)
            sqlite3_bind_int(stmt, 4, Int32(limit))
        } else {
            sqlite3_bind_text(stmt, 1, (pattern as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (pattern as NSString).utf8String, -1, nil)
            sqlite3_bind_int(stmt, 3, Int32(limit))
        }

        var results: [QMemoryRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append(parseRecord(from: stmt!))
        }
        return results
    }

    public func listRecent(sessionId: String? = nil, limit: Int = 20) throws -> [QMemoryRecord] {
        lock.lock()
        defer { lock.unlock() }

        let sql: String
        if let sessionId {
            sql = "SELECT record_id, session_id, task_id, key, content, provenance_kind, provenance_source, created_at, updated_at FROM memory_records WHERE session_id = ? ORDER BY updated_at DESC LIMIT ?;"
        } else {
            sql = "SELECT record_id, session_id, task_id, key, content, provenance_kind, provenance_source, created_at, updated_at FROM memory_records ORDER BY updated_at DESC LIMIT ?;"
        }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw QMemoryError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        if let sessionId {
            sqlite3_bind_text(stmt, 1, (sessionId as NSString).utf8String, -1, nil)
            sqlite3_bind_int(stmt, 2, Int32(limit))
        } else {
            sqlite3_bind_int(stmt, 1, Int32(limit))
        }

        var results: [QMemoryRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append(parseRecord(from: stmt!))
        }
        return results
    }

    public func delete(recordId: String) throws {
        lock.lock()
        defer { lock.unlock() }

        let sql = "DELETE FROM memory_records WHERE record_id = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw QMemoryError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, (recordId as NSString).utf8String, -1, nil)
        sqlite3_step(stmt)
    }

    private func parseRecord(from stmt: OpaquePointer) -> QMemoryRecord {
        let recId = String(cString: sqlite3_column_text(stmt, 0))
        let sessId = String(cString: sqlite3_column_text(stmt, 1))
        let taskId = sqlite3_column_text(stmt, 2) != nil ? String(cString: sqlite3_column_text(stmt, 2)) : nil
        let key = String(cString: sqlite3_column_text(stmt, 3))
        let content = String(cString: sqlite3_column_text(stmt, 4))
        let provKind = String(cString: sqlite3_column_text(stmt, 5))
        let provSrc = String(cString: sqlite3_column_text(stmt, 6))
        let createdAtSec = sqlite3_column_double(stmt, 7)
        let updatedAtSec = sqlite3_column_double(stmt, 8)

        return QMemoryRecord(
            recordId: recId,
            sessionId: sessId,
            taskId: taskId,
            key: key,
            content: content,
            provenanceKind: provKind,
            provenanceSource: provSrc,
            createdAt: Date(timeIntervalSince1970: createdAtSec),
            updatedAt: Date(timeIntervalSince1970: updatedAtSec)
        )
    }

    // MARK: - QMemoryProvider Protocol Conformance

    public func recordTaskStart(_ task: QTask) async throws {
        let rec = QMemoryRecord(
            sessionId: task.sessionId,
            taskId: task.taskId,
            key: "task_start:\(task.taskId)",
            content: task.intent,
            provenanceKind: "trusted:user",
            provenanceSource: "user_intent"
        )
        try insert(record: rec)
    }

    public func recordTaskCompletion(_ task: QTask, result: String) async throws {
        let rec = QMemoryRecord(
            sessionId: task.sessionId,
            taskId: task.taskId,
            key: "task_completion:\(task.taskId)",
            content: result,
            provenanceKind: "trusted:system",
            provenanceSource: "core_runtime"
        )
        try insert(record: rec)
    }

    public func queryContext(for queryText: String, limit: Int = 10) async throws -> [String] {
        let records = try query(text: queryText, sessionId: nil, limit: limit)
        return records.map(\.content)
    }
}

public enum QMemoryError: Error, Equatable, Sendable {
    case databaseOpenFailed(String)
    case queryFailed(String)
}
