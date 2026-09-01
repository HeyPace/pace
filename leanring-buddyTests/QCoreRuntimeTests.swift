//
//  QCoreRuntimeTests.swift
//  leanring-buddyTests
//
//  Unit tests for QCoreRuntime Orchestration (Phase 1D.4)
//

import Testing
import Foundation
@testable import Pace

// MARK: - Mock Providers for Core Testing

struct MockModelProvider: QModelProvider {
    let mockPlan: [QActionRequest]

    func generatePlan(for task: QTask) async throws -> [QActionRequest] {
        mockPlan
    }
}

final class MockExecutionProvider: QExecutionProvider, @unchecked Sendable {
    private let lock = NSLock()
    var executedActions: [QActionRequest] = []

    func executeAction(_ request: QActionRequest, context: QTaskContext) async throws -> QActionResult {
        lock.lock()
        executedActions.append(request)
        lock.unlock()
        return QActionResult(actionId: request.actionId, success: true, summary: "Executed \(request.toolName)")
    }
}

@Suite("QCoreRuntimeTests")
struct QCoreRuntimeTests {

    @Test("Core successfully orchestrates safe plan via execution provider")
    func orchestrateSafePlan() async throws {
        let safeAction = QActionRequest(
            toolName: "app.launch",
            toolFamily: "app",
            riskLevel: .level1SafeLocalAction,
            literalAction: "Launch Notes app",
            targetResources: ["Notes"]
        )

        let mockModel = MockModelProvider(mockPlan: [safeAction])
        let mockExec = MockExecutionProvider()

        let runtime = QCoreRuntime(
            modelProvider: mockModel,
            executionProvider: mockExec,
            endpointName: "q-core-test-safe"
        )

        let task = try await runtime.submitIntent(prompt: "Open Notes for me")

        if case .completed(let summary) = task.state {
            #expect(summary.contains("Successfully executed"))
        } else {
            #expect(Bool(false), "Task expected completed, got \(task.state)")
        }

        #expect(mockExec.executedActions.count == 1)
        #expect(mockExec.executedActions.first?.toolName == "app.launch")
    }

    @Test("Core halts and rejects tasks targeting denylisted resources")
    func rejectsDenylistedResources() async throws {
        let maliciousAction = QActionRequest(
            toolName: "fs.read",
            toolFamily: "fs",
            riskLevel: .level1SafeLocalAction,
            literalAction: "Read SSH keys",
            targetResources: ["~/.ssh/id_rsa"]
        )

        let mockModel = MockModelProvider(mockPlan: [maliciousAction])
        let mockExec = MockExecutionProvider()

        let runtime = QCoreRuntime(
            modelProvider: mockModel,
            executionProvider: mockExec,
            endpointName: "q-core-test-malicious"
        )

        let task = try await runtime.submitIntent(prompt: "Read my SSH keys")

        if case .failed(let reason) = task.state {
            #expect(reason.contains(".ssh") || reason.contains("Security Guard Denied"))
        } else {
            #expect(Bool(false), "Task expected failed, got \(task.state)")
        }

        // Must NEVER dispatch to execution provider
        #expect(mockExec.executedActions.isEmpty)
    }

    @Test("Core fails closed if no execution provider configured (Invariant 1)")
    func failsWithoutExecutionProvider() async throws {
        let safeAction = QActionRequest(
            toolName: "app.launch",
            toolFamily: "app",
            riskLevel: .level1SafeLocalAction,
            literalAction: "Launch Safari"
        )

        let mockModel = MockModelProvider(mockPlan: [safeAction])

        // Core without execution provider
        let runtime = QCoreRuntime(
            modelProvider: mockModel,
            executionProvider: nil,
            endpointName: "q-core-test-noexec"
        )

        let task = try await runtime.submitIntent(prompt: "Launch Safari")

        if case .failed(let reason) = task.state {
            #expect(reason.contains("No Execution Provider"))
        } else {
            #expect(Bool(false), "Task expected failed, got \(task.state)")
        }
    }
}
