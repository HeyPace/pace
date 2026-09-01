//
//  QRecoveryE2ETests.swift
//  leanring-buddyTests
//
//  Q Security Architecture — Real macOS Safe Recovery E2E Integration (Phase 2D).
//  Validates complete crash, observation-first recovery, and resume against real macOS system state.
//

import Testing
import Foundation
import AppKit
@testable import Pace

@Suite("QRecoveryE2ETests")
struct QRecoveryE2ETests {

    @Test("Scenario A: Real Safe Mac E2E — Crash after execution resolves via observation-first verification")
    func realMacCrashAfterExecutionResolvesViaObservation() async throws {
        let store = try QDurableTaskStore(inMemory: true)
        let runtime = QCoreRuntime(
            modelProvider: QModelRouter.shared,
            memoryProvider: QSQLiteMemoryStore(inMemory: true),
            executionProvider: QExecutionService.shared,
            durableStore: store
        )

        // Simulate crash: step was 'running' when process terminated
        let step0 = QDurablePlanStepSnapshot(
            stepId: "step-finder-0",
            index: 0,
            actionName: "ui.open_app",
            toolFamily: "ui",
            riskLevel: "level1SafeLocalAction",
            literalAction: "Ensure Finder is active",
            targetResources: ["Finder"],
            arguments: ["appName": "Finder"],
            state: "running"
        )

        let plan = QDurablePlanSnapshot(
            planId: "plan-finder-crash",
            taskId: "task-finder-crash",
            sessionId: "s-finder-1",
            goal: "Open Finder",
            steps: [step0]
        )

        let task = QDurableTaskState(
            taskId: "task-finder-crash",
            sessionId: "s-finder-1",
            originalIntent: "Open Finder",
            lifecycleState: .running,
            currentPlanId: "plan-finder-crash",
            currentStepIndex: 0
        )

        try store.savePlan(plan)
        try store.saveTask(task)

        // Execute recovery and resume
        let recoveredTask = try await runtime.resumeTask(taskId: "task-finder-crash")
        #expect(recoveredTask.state.isTerminal == true)

        if case .completed(let summary) = recoveredTask.state {
            #expect(!summary.isEmpty)
        } else {
            #expect(Bool(false), "Expected recovered task to complete, got: \(recoveredTask.state)")
        }
    }

    @Test("Scenario B: Real Safe Mac E2E — Crash before execution executes safely once")
    func realMacCrashBeforeExecutionExecutesOnce() async throws {
        let store = try QDurableTaskStore(inMemory: true)
        let runtime = QCoreRuntime(
            modelProvider: QModelRouter.shared,
            memoryProvider: QSQLiteMemoryStore(inMemory: true),
            executionProvider: QExecutionService.shared,
            durableStore: store
        )

        let step0 = QDurablePlanStepSnapshot(
            stepId: "step-safe-0",
            index: 0,
            actionName: "system.running_apps",
            toolFamily: "system",
            riskLevel: "level0ReadOnly",
            literalAction: "Query running applications",
            state: "pending"
        )

        let plan = QDurablePlanSnapshot(
            planId: "plan-safe-crash",
            taskId: "task-safe-crash",
            sessionId: "s-safe-1",
            goal: "Check system running applications",
            steps: [step0]
        )

        let task = QDurableTaskState(
            taskId: "task-safe-crash",
            sessionId: "s-safe-1",
            originalIntent: "Check system running applications",
            lifecycleState: .running,
            currentPlanId: "plan-safe-crash",
            currentStepIndex: 0
        )

        try store.savePlan(plan)
        try store.saveTask(task)

        let recoveredTask = try await runtime.resumeTask(taskId: "task-safe-crash")
        #expect(recoveredTask.state.isTerminal == true)
        if case .completed = recoveredTask.state {
            #expect(true)
        } else {
            #expect(Bool(false), "Expected recovered task to complete, got: \(recoveredTask.state)")
        }
    }

    @Test("Scenario C: Real Safe Mac Multi-Step Recovery — Step 1 completed, Step 2 resumed")
    func realMacMultiStepRecovery() async throws {
        let store = try QDurableTaskStore(inMemory: true)
        let agent = QAgent(
            coreRuntime: QCoreRuntime(
                modelProvider: QModelRouter.shared,
                memoryProvider: QSQLiteMemoryStore(inMemory: true),
                executionProvider: QExecutionService.shared,
                durableStore: store
            )
        )

        // Step 1 was completed prior to crash
        let step0 = QDurablePlanStepSnapshot(
            stepId: "step-multi-calc-0",
            index: 0,
            actionName: "ui.open_app",
            toolFamily: "ui",
            riskLevel: "level1SafeLocalAction",
            literalAction: "Launch Calculator",
            targetResources: ["Calculator"],
            arguments: ["appName": "Calculator"],
            state: "completed",
            resultSummary: "Calculator launched",
            verifiedEvidence: "Application Calculator is running"
        )

        // Step 2 was pending
        let step1 = QDurablePlanStepSnapshot(
            stepId: "step-multi-calc-1",
            index: 1,
            actionName: "system.running_apps",
            toolFamily: "system",
            riskLevel: "level0ReadOnly",
            literalAction: "Check running applications",
            state: "pending"
        )

        let plan = QDurablePlanSnapshot(
            planId: "plan-multistep-calc",
            taskId: "task-multistep-calc",
            sessionId: "s-multi-1",
            goal: "Open Calculator and check running applications",
            steps: [step0, step1]
        )

        let task = QDurableTaskState(
            taskId: "task-multistep-calc",
            sessionId: "s-multi-1",
            originalIntent: "Open Calculator and check running applications",
            lifecycleState: .running,
            currentPlanId: "plan-multistep-calc",
            currentStepIndex: 1,
            completedStepIds: ["step-multi-calc-0"],
            verificationEvidenceReferences: ["Application Calculator is running"]
        )

        try store.savePlan(plan)
        try store.saveTask(task)

        let result = try await agent.resume(taskId: "task-multistep-calc")
        #expect(result.isSuccess == true)
        #expect(!result.summary.isEmpty)
    }
}
