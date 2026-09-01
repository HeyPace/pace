//
//  QDurableTaskStore.swift
//  leanring-buddy
//
//  Q Security Architecture — SQLite WAL Durable Task & Event Storage (Phase 2D).
//  Provides crash-resilient persistence for durable tasks, plan snapshots, and lifecycle events.
//

import Foundation
import SQLite3

public protocol QDurableTaskStoreProtocol: Sendable {
    func saveTask(_ state: QDurableTaskState) throws
    func getTask(taskId: String) throws -> QDurableTaskState?
    func listIncompleteTasks() throws -> [QDurableTaskState]
    func savePlan(_ plan: QDurablePlanSnapshot) throws
    func getPlan(planId: String) throws -> QDurablePlanSnapshot?
    func recordEvent(_ event: QTaskLifecycleEvent) throws
    func listEvents(taskId: String) throws -> [QTaskLifecycleEvent]
    func deleteTask(taskId: String) throws
}

public final class QDurableTaskStore: QDurableTaskStoreProtocol, @unchecked Sendable {
    public static let shared = try! QDurableTaskStore()

    private var db: OpaquePointer?
    private let dbPath: String
    private let lock = NSRecursiveLock()
    private let jsonEncoder = JSONEncoder()
    private let jsonDecoder = JSONDecoder()

    public init(databasePath: String = ":memory:", inMemory: Bool = false) throws {
        if inMemory || databasePath == ":memory:" {
            self.dbPath = ":memory:"
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let qDir = appSupport.appendingPathComponent("Pace/q-data", isDirectory: true)
            try? FileManager.default.createDirectory(at: qDir, withIntermediateDirectories: true)
            self.dbPath = databasePath == "default" ? qDir.appendingPathComponent("q_durable_tasks.sqlite").path : databasePath
        }

        try openDatabase()
        try createTables()
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
        }

        if sqlite3_open_v2(dbPath, &db, flags, nil) != SQLITE_OK {
            let msg = db != nil ? String(cString: sqlite3_errmsg(db)) : "Unknown error"
            throw QMemoryError.databaseOpenFailed(msg)
        }

        execSimpleSQL("PRAGMA journal_mode=WAL;")
        execSimpleSQL("PRAGMA busy_timeout=5000;")
        execSimpleSQL("PRAGMA synchronous=NORMAL;")
    }

    private func createTables() throws {
        lock.lock()
        defer { lock.unlock() }

        let sql = """
        CREATE TABLE IF NOT EXISTS q_durable_tasks (
            task_id TEXT PRIMARY KEY,
            session_id TEXT NOT NULL,
            state_json TEXT NOT NULL,
            lifecycle_state TEXT NOT NULL,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        );

        CREATE TABLE IF NOT EXISTS q_durable_plans (
            plan_id TEXT PRIMARY KEY,
            task_id TEXT NOT NULL,
            plan_json TEXT NOT NULL,
            created_at REAL NOT NULL
        );

        CREATE TABLE IF NOT EXISTS q_lifecycle_events (
            event_id TEXT PRIMARY KEY,
            task_id TEXT NOT NULL,
            session_id TEXT NOT NULL,
            event_type TEXT NOT NULL,
            event_json TEXT NOT NULL,
            timestamp REAL NOT NULL
        );

        CREATE INDEX IF NOT EXISTS idx_tasks_lifecycle ON q_durable_tasks(lifecycle_state);
        CREATE INDEX IF NOT EXISTS idx_plans_task ON q_durable_plans(task_id);
        CREATE INDEX IF NOT EXISTS idx_events_task ON q_lifecycle_events(task_id, timestamp);
        """

        execSimpleSQL(sql)
    }

    private func execSimpleSQL(_ sql: String) {
        var err: UnsafeMutablePointer<CChar>?
        sqlite3_exec(db, sql, nil, nil, &err)
        if let err {
            sqlite3_free(err)
        }
    }

    // MARK: - Task Persistence

    public func saveTask(_ state: QDurableTaskState) throws {
        lock.lock()
        defer { lock.unlock() }

        let data = try jsonEncoder.encode(state)
        let jsonStr = String(data: data, encoding: .utf8) ?? "{}"

        let sql = """
        INSERT INTO q_durable_tasks (task_id, session_id, state_json, lifecycle_state, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT(task_id) DO UPDATE SET
            session_id = excluded.session_id,
            state_json = excluded.state_json,
            lifecycle_state = excluded.lifecycle_state,
            updated_at = excluded.updated_at;
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw QMemoryError.queryFailed("Failed to prepare saveTask SQL")
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, (state.taskId as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (state.sessionId as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 3, (jsonStr as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 4, (state.lifecycleState.rawValue as NSString).utf8String, -1, nil)
        sqlite3_bind_double(stmt, 5, state.taskCreationTimestamp.timeIntervalSince1970)
        sqlite3_bind_double(stmt, 6, state.lastUpdatedTimestamp.timeIntervalSince1970)

        if sqlite3_step(stmt) != SQLITE_DONE {
            throw QMemoryError.queryFailed("Failed to execute saveTask")
        }
    }

    public func getTask(taskId: String) throws -> QDurableTaskState? {
        lock.lock()
        defer { lock.unlock() }

        let sql = "SELECT state_json FROM q_durable_tasks WHERE task_id = ? LIMIT 1;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw QMemoryError.queryFailed("Failed to prepare getTask SQL")
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, (taskId as NSString).utf8String, -1, nil)

        if sqlite3_step(stmt) == SQLITE_ROW {
            if let cStr = sqlite3_column_text(stmt, 0) {
                let jsonStr = String(cString: cStr)
                if let data = jsonStr.data(using: .utf8) {
                    return try jsonDecoder.decode(QDurableTaskState.self, from: data)
                }
            }
        }
        return nil
    }

    public func listIncompleteTasks() throws -> [QDurableTaskState] {
        lock.lock()
        defer { lock.unlock() }

        let sql = "SELECT state_json FROM q_durable_tasks WHERE lifecycle_state IN ('pending', 'running', 'awaiting_approval', 'paused') ORDER BY created_at ASC;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw QMemoryError.queryFailed("Failed to prepare listIncompleteTasks SQL")
        }
        defer { sqlite3_finalize(stmt) }

        var results: [QDurableTaskState] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let cStr = sqlite3_column_text(stmt, 0) {
                let jsonStr = String(cString: cStr)
                if let data = jsonStr.data(using: .utf8),
                   let task = try? jsonDecoder.decode(QDurableTaskState.self, from: data) {
                    results.append(task)
                }
            }
        }
        return results
    }

    // MARK: - Plan Persistence

    public func savePlan(_ plan: QDurablePlanSnapshot) throws {
        lock.lock()
        defer { lock.unlock() }

        let data = try jsonEncoder.encode(plan)
        let jsonStr = String(data: data, encoding: .utf8) ?? "{}"

        let sql = """
        INSERT INTO q_durable_plans (plan_id, task_id, plan_json, created_at)
        VALUES (?, ?, ?, ?)
        ON CONFLICT(plan_id) DO UPDATE SET
            task_id = excluded.task_id,
            plan_json = excluded.plan_json;
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw QMemoryError.queryFailed("Failed to prepare savePlan SQL")
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, (plan.planId as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (plan.taskId as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 3, (jsonStr as NSString).utf8String, -1, nil)
        sqlite3_bind_double(stmt, 4, plan.creationTimestamp.timeIntervalSince1970)

        if sqlite3_step(stmt) != SQLITE_DONE {
            throw QMemoryError.queryFailed("Failed to execute savePlan")
        }
    }

    public func getPlan(planId: String) throws -> QDurablePlanSnapshot? {
        lock.lock()
        defer { lock.unlock() }

        let sql = "SELECT plan_json FROM q_durable_plans WHERE plan_id = ? LIMIT 1;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw QMemoryError.queryFailed("Failed to prepare getPlan SQL")
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, (planId as NSString).utf8String, -1, nil)

        if sqlite3_step(stmt) == SQLITE_ROW {
            if let cStr = sqlite3_column_text(stmt, 0) {
                let jsonStr = String(cString: cStr)
                if let data = jsonStr.data(using: .utf8) {
                    return try jsonDecoder.decode(QDurablePlanSnapshot.self, from: data)
                }
            }
        }
        return nil
    }

    // MARK: - Event Sourced Lifecycle

    public func recordEvent(_ event: QTaskLifecycleEvent) throws {
        lock.lock()
        defer { lock.unlock() }

        let data = try jsonEncoder.encode(event)
        let jsonStr = String(data: data, encoding: .utf8) ?? "{}"

        let sql = """
        INSERT INTO q_lifecycle_events (event_id, task_id, session_id, event_type, event_json, timestamp)
        VALUES (?, ?, ?, ?, ?, ?);
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw QMemoryError.queryFailed("Failed to prepare recordEvent SQL")
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, (event.eventId as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (event.taskId as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 3, (event.sessionId as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 4, (event.eventType.rawValue as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 5, (jsonStr as NSString).utf8String, -1, nil)
        sqlite3_bind_double(stmt, 6, event.timestamp.timeIntervalSince1970)

        if sqlite3_step(stmt) != SQLITE_DONE {
            throw QMemoryError.queryFailed("Failed to execute recordEvent")
        }
    }

    public func listEvents(taskId: String) throws -> [QTaskLifecycleEvent] {
        lock.lock()
        defer { lock.unlock() }

        let sql = "SELECT event_json FROM q_lifecycle_events WHERE task_id = ? ORDER BY timestamp ASC;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw QMemoryError.queryFailed("Failed to prepare listEvents SQL")
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, (taskId as NSString).utf8String, -1, nil)

        var results: [QTaskLifecycleEvent] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let cStr = sqlite3_column_text(stmt, 0) {
                let jsonStr = String(cString: cStr)
                if let data = jsonStr.data(using: .utf8),
                   let ev = try? jsonDecoder.decode(QTaskLifecycleEvent.self, from: data) {
                    results.append(ev)
                }
            }
        }
        return results
    }

    public func deleteTask(taskId: String) throws {
        lock.lock()
        defer { lock.unlock() }

        execSimpleSQL("DELETE FROM q_durable_tasks WHERE task_id = '\(taskId)';")
        execSimpleSQL("DELETE FROM q_durable_plans WHERE task_id = '\(taskId)';")
        execSimpleSQL("DELETE FROM q_lifecycle_events WHERE task_id = '\(taskId)';")
    }
}
