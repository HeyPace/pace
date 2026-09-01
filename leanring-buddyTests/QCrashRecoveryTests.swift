//
//  QCrashRecoveryTests.swift
//  leanring-buddyTests
//
//  Q Security Architecture — Crash Recovery State Machine Tests (Phase 2D).
//  Validates state recovery after mid-flight crashes, uncertain step resolution,
//  and clean sequential resume.
//

import Testing
import Foundation
@testable import Pace

@Suite("QCrashRecoveryTests")
struct QCrashRecoveryTests {

    @Test("1. Simulated crash during plan creation allows complete recovery")
    func recoverAfterPlanCreationCrash() async throws {
        let store = try QDurableTaskStore(inMemory: true)
        let runtime = QCoreRuntime(
            modelProvider: QModelRouter.shared,
            memoryProvider: QSQLiteMemoryStore(inMemory: true),
            executionProvider: QExecutionService.shared,
            durableStore: store
        )

        let step0 = QDurablePlanStepSnapshot(
            stepId: "step-0",
            index: 0,
            actionName: "system.running_apps",
            toolFamily: "system",
            riskLevel: "level0ReadOnly",
            literalAction: "Query running applications",
            targetResources: [],
            arguments: [:],
            state: "pending"
        )

        let plan = QDurablePlanSnapshot(
            planId: "plan-crash-0",
            taskId: "task-crash-0",
            sessionId: "s0",
            goal: "Check system running applications",
            steps: [step0]
        )

        let task = QDurableTaskState(
            taskId: "task-crash-0",
            sessionId: "s0",
            originalIntent: "Check system running applications",
            lifecycleState: .running,
            currentPlanId: "plan-crash-0",
            currentStepIndex: 0
        )

        try store.savePlan(plan)
        try store.saveTask(task)

        // Resume task
        let resumedTask = try await runtime.resumeTask(taskId: "task-crash-0")
        #expect(resumedTask.state.isTerminal == true)
        if case .completed = resumedTask.state {
            #expect(true)
        } else {
            #expect(Bool(false), "Expected completed state after resume, got: \(resumedTask.state)")
        }
    }

    @Test("2. Simulated crash on mid-flight multi-step task resumes from unexecuted step")
    func resumeMultiStepTaskFromPendingStep() async throws {
        let store = try QDurableTaskStore(inMemory: true)
        let runtime = QCoreRuntime(
            modelProvider: QModelRouter.shared,
            memoryProvider: QSQLiteMemoryStore(inMemory: true),
            executionProvider: QExecutionService.shared,
            durableStore: store
        )

        // Step 0 was already completed before the crash
        let step0 = QDurablePlanStepSnapshot(
            stepId: "step-multi-0",
            index: 0,
            actionName: "system.running_apps",
            toolFamily: "system",
            riskLevel: "level0ReadOnly",
            literalAction: "Query running applications",
            state: "completed",
            resultSummary: "Found Finder, Pace, and system processes",
            verifiedEvidence: "system.running_apps query completed"
        )

        // Step 1 was pending when the crash happened
        let step1 = QDurablePlanStepSnapshot(
            stepId: "step-multi-1",
            index: 1,
            actionName: "system.clipboard.read",
            toolFamily: "system",
            riskLevel: "level0ReadOnly",
            literalAction: "Read system clipboard",
            state: "pending"
        )

        let plan = QDurablePlanSnapshot(
            planId: "plan-multi-crash",
            taskId: "task-multi-crash",
            sessionId: "s1",
            goal: "Check system running applications and read clipboard",
            steps: [step0, step1]
        )

        let task = QDurableTaskState(
            taskId: "task-multi-crash",
            sessionId: "s1",
            originalIntent: "Check system running applications and read clipboard",
            lifecycleState: .running,
            currentPlanId: "plan-multi-crash",
            currentStepIndex: 1,
            completedStepIds: ["step-multi-0"],
            verificationEvidenceReferences: ["system.running_apps query completed"]
        )

        try store.savePlan(plan)
        try store.saveTask(task)

        // Resume task
        let resumedTask = try await runtime.resumeTask(taskId: "task-multi-crash")
        #expect(resumedTask.state.isTerminal == true)
        if case .completed = resumedTask.state {
            #expect(true)
        } else {
            #expect(Bool(false), "Expected completed state after resuming remaining steps, got: \(resumedTask.state)")
        }
    }
}
