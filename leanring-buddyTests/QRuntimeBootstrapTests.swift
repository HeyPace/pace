//
//  QRuntimeBootstrapTests.swift
//  leanring-buddyTests
//
//  Unit tests for QRuntimeBootstrap (Phase 1E.2)
//

import Testing
import Foundation
@testable import Pace

@Suite("QRuntimeBootstrapTests")
struct QRuntimeBootstrapTests {

    @Test("Bootstrap initializes full local runtime in fail-closed sequence")
    func testRuntimeBootstrap() async {
        let coordinator = QRuntimeBootstrap.shared
        let report = await coordinator.bootstrap(databasePath: ":memory:", localOnlyModels: true)

        #expect(report.isReady == true)
        #expect(report.errors.isEmpty)
        #expect(report.activeComponents.count >= 7)
        #expect(report.activeComponents.contains("QAuditLogger"))
        #expect(report.activeComponents.contains("QPermissionGate"))
        #expect(report.activeComponents.contains("QResourceGuard"))
        #expect(report.activeComponents.contains("QSQLiteMemoryStore (WAL Mode)"))
        #expect(report.activeComponents.contains("QCoreRuntime (Unified Orchestrator)"))

        let core = coordinator.getCoreRuntime()
        #expect(core != nil)

        let memory = coordinator.getMemoryStore()
        #expect(memory != nil)
    }

    @Test("Bootstrap records audit event on startup")
    func testBootstrapAuditLogging() async {
        let coordinator = QRuntimeBootstrap.shared
        _ = await coordinator.bootstrap(databasePath: ":memory:", localOnlyModels: true)

        let records = QAuditLogger.shared.getRecentRecords(limit: 50)
        #expect(records.contains { $0.tool == "runtime.bootstrap" })
    }
}
