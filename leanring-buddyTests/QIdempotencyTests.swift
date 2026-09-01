//
//  QIdempotencyTests.swift
//  leanring-buddyTests
//
//  Q Security Architecture — Action Idempotency & Re-Execution Guards (Phase 2D).
//  Ensures actions whose effects already exist are verified rather than physically repeated.
//

import Testing
import Foundation
@testable import Pace

@Suite("QIdempotencyTests")
struct QIdempotencyTests {

    @Test("1. QExecutionIdentity produces unique deterministic fingerprint")
    func executionIdentityFingerprint() {
        let id1 = QExecutionIdentity(
            taskId: "task-1",
            planId: "plan-1",
            stepId: "step-0",
            attemptId: "att-1",
            actionName: "ui.open_app"
        )

        let id2 = QExecutionIdentity(
            taskId: "task-1",
            planId: "plan-1",
            stepId: "step-0",
            attemptId: "att-2",
            actionName: "ui.open_app"
        )

        #expect(id1.stepFingerprint == id2.stepFingerprint)
        #expect(id1.stepFingerprint == "task-1:plan-1:step-0:ui.open_app")
    }

    @Test("2. Observation-first resolution detects existing file on disk and verifies without re-writing")
    func observationFirstDetectsExistingFile() async throws {
        let store = try QDurableTaskStore(inMemory: true)
        let manager = QTaskRecoveryManager(store: store)

        let testFile = "/tmp/q-sandbox/idempotent-test.txt"
        try? FileManager.default.createDirectory(atPath: "/tmp/q-sandbox", withIntermediateDirectories: true)
        try "Phase 2D Idempotent Data".write(toFile: testFile, atomically: true, encoding: .utf8)

        let step0 = QDurablePlanStepSnapshot(
            stepId: "step-write-0",
            index: 0,
            actionName: "fs.write_sandbox",
            toolFamily: "fs",
            riskLevel: "level1SafeLocalAction",
            literalAction: "Write sandbox file",
            targetResources: [testFile],
            state: "running"
        )

        let plan = QDurablePlanSnapshot(
            planId: "plan-file-1",
            taskId: "task-file-1",
            sessionId: "s1",
            goal: "Write sandbox file",
            steps: [step0]
        )

        let task = QDurableTaskState(
            taskId: "task-file-1",
            sessionId: "s1",
            originalIntent: "Write sandbox file",
            lifecycleState: .running,
            currentPlanId: "plan-file-1",
            currentStepIndex: 0
        )

        let resolution = try await manager.resolveUncertainStep(
            task: task,
            plan: plan,
            stepIndex: 0,
            uncertainStep: step0
        )

        #expect(resolution.isVerified == true)
        #expect(resolution.updatedPlan.steps[0].state == "completed")
        #expect(resolution.updatedTask.completedStepIds.contains("step-write-0"))
        #expect(resolution.updatedTask.currentStepIndex == 1)

        // Cleanup
        try? FileManager.default.removeItem(atPath: testFile)
    }

    @Test("3. Non-existent effect marks step pending so it safely executes once")
    func nonExistentEffectMarksStepPending() async throws {
        let store = try QDurableTaskStore(inMemory: true)
        let manager = QTaskRecoveryManager(store: store)

        let missingFile = "/tmp/q-sandbox/definitely-not-existing-\(UUID().uuidString).txt"

        let step0 = QDurablePlanStepSnapshot(
            stepId: "step-missing-0",
            index: 0,
            actionName: "fs.write_sandbox",
            toolFamily: "fs",
            riskLevel: "level1SafeLocalAction",
            literalAction: "Write sandbox file",
            targetResources: [missingFile],
            state: "running"
        )

        let plan = QDurablePlanSnapshot(
            planId: "plan-missing-1",
            taskId: "task-missing-1",
            sessionId: "s1",
            goal: "Write missing file",
            steps: [step0]
        )

        let task = QDurableTaskState(
            taskId: "task-missing-1",
            sessionId: "s1",
            originalIntent: "Write missing file",
            lifecycleState: .running,
            currentPlanId: "plan-missing-1",
            currentStepIndex: 0
        )

        let resolution = try await manager.resolveUncertainStep(
            task: task,
            plan: plan,
            stepIndex: 0,
            uncertainStep: step0
        )

        #expect(resolution.isVerified == false)
        #expect(resolution.updatedPlan.steps[0].state == "pending")
        #expect(!resolution.updatedTask.completedStepIds.contains("step-missing-0"))
    }
}
