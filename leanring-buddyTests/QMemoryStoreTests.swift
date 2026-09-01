//
//  QMemoryStoreTests.swift
//  leanring-buddyTests
//
//  Unit tests for SQLite WAL Memory Foundation (Phase 1D.8)
//

import Testing
import Foundation
@testable import Pace

@Suite("QMemoryStoreTests")
struct QMemoryStoreTests {

    @Test("Insert, retrieve by ID, and get by key")
    func insertAndRetrieve() throws {
        let store = try QSQLiteMemoryStore(databasePath: ":memory:")
        let record = QMemoryRecord(
            sessionId: "sess_1",
            taskId: "task_1",
            key: "user_preference",
            content: "Dark mode enabled",
            provenanceKind: "trusted:user",
            provenanceSource: "settings"
        )

        try store.insert(record: record)

        let retrieved = try store.get(recordId: record.recordId)
        #expect(retrieved != nil)
        #expect(retrieved?.key == "user_preference")
        #expect(retrieved?.content == "Dark mode enabled")

        let byKey = try store.getByKey("user_preference", sessionId: "sess_1")
        #expect(byKey != nil)
        #expect(byKey?.recordId == record.recordId)
    }

    @Test("Update modifies existing record content")
    func updateRecord() throws {
        let store = try QSQLiteMemoryStore(databasePath: ":memory:")
        var record = QMemoryRecord(
            sessionId: "sess_1",
            key: "workspace_path",
            content: "/old/path"
        )
        try store.insert(record: record)

        record = QMemoryRecord(
            recordId: record.recordId,
            sessionId: record.sessionId,
            key: record.key,
            content: "/new/path"
        )
        try store.update(record: record)

        let updated = try store.get(recordId: record.recordId)
        #expect(updated?.content == "/new/path")
    }

    @Test("Lexical query searches content and key fields")
    func lexicalSearch() throws {
        let store = try QSQLiteMemoryStore(databasePath: ":memory:")
        try store.insert(record: QMemoryRecord(sessionId: "s1", key: "note_1", content: "Swift concurrency on macOS"))
        try store.insert(record: QMemoryRecord(sessionId: "s1", key: "note_2", content: "Python script runner"))
        try store.insert(record: QMemoryRecord(sessionId: "s1", key: "doc_swift", content: "Architecture docs"))

        let swiftResults = try store.query(text: "Swift", sessionId: "s1")
        #expect(swiftResults.count == 2)

        let pythonResults = try store.query(text: "Python", sessionId: "s1")
        #expect(pythonResults.count == 1)
        #expect(pythonResults.first?.key == "note_2")
    }

    @Test("Persistence across database reopening (Restart persistence)")
    func restartPersistence() throws {
        let dbPath = "/tmp/q-test-db-\(UUID().uuidString).sqlite"

        // 1. Write to database and close
        do {
            let store1 = try QSQLiteMemoryStore(databasePath: dbPath)
            let rec = QMemoryRecord(sessionId: "s_persist", key: "persisted_key", content: "Saved Data")
            try store1.insert(record: rec)
        }

        // 2. Reopen from same disk file
        do {
            let store2 = try QSQLiteMemoryStore(databasePath: dbPath)
            let rec = try store2.getByKey("persisted_key", sessionId: "s_persist")
            #expect(rec != nil)
            #expect(rec?.content == "Saved Data")
        }

        try? FileManager.default.removeItem(atPath: dbPath)
    }

    @Test("Concurrent multi-task read/write access under WAL mode")
    func concurrentAccess() async throws {
        let store = try QSQLiteMemoryStore(databasePath: ":memory:")

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<20 {
                group.addTask {
                    let rec = QMemoryRecord(
                        sessionId: "concurrent_sess",
                        key: "key_\(i)",
                        content: "Payload \(i)"
                    )
                    try? store.insert(record: rec)
                }
            }
        }

        let list = try store.listRecent(sessionId: "concurrent_sess", limit: 50)
        #expect(list.count == 20)
    }
}
