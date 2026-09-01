//
//  QTaskRecoveryManagerTests.swift
//  leanring-buddyTests
//
//  Q Security Architecture — Task Recovery Manager Tests (Phase 2D).
//  Validates discovery, state analysis, fail-closed handling on corrupt state,
//  and observation-first resolution.
//

import Testing
import Foundation
@testable import Pace

@Suite("QTaskRecoveryManagerTests")
struct QTaskRecoveryManagerTests {

    @Test("1. Discover incomplete tasks finds active and paused tasks")
    func discoverIncompleteTasks() throws {
        let store = try QDurableTaskStore(inMemory: true)
        let manager = QTaskRecoveryManager(store: store)

        let task1 = QDurableTaskState(taskId: "task-1", sessionId: "s1", originalIntent: "Task 1", lifecycleState: .running)
        let task2 = QDurableTaskState(taskId: "task-2", sessionId: "s2", originalIntent: "Task 2", lifecycleState: .completed)
        let task3 = QDurableTaskState(taskId: "task-3", sessionId: "s3", originalIntent: "Task 3", lifecycleState: .awaitingApproval)

        try store.saveTask(task1)
        try store.saveTask(task2)
        try store.saveTask(task3)

        let incomplete = try manager.discoverIncompleteTasks()
        #expect(incomplete.count == 2)
        #expect(incomplete.contains { $0.taskId == "task-1" })
        #expect(incomplete.contains { $0.taskId == "task-3" })
        #expect(!incomplete.contains { $0.taskId == "task-2" })
    }

    @Test("2. Completed task evaluates to completed recovery status without execution")
    func completedTaskEvaluatesToCompleted() async throws {
        let store = try QDurableTaskStore(inMemory: true)
        let manager = QTaskRecoveryManager(store: store)

        let task = QDurableTaskState(taskId: "task-comp", sessionId: "s1", originalIntent: "Completed", lifecycleState: .completed)
        try store.saveTask(task)

        let status = try await manager.evaluateTaskRecovery(taskId: "task-comp")
        #expect(status == .completed(task: task))
    }

    @Test("3. Missing plan snapshot evaluates to corrupted status")
    func missingPlanEvaluatesToCorrupted() async throws {
        let store = try QDurableTaskStore(inMemory: true)
        let manager = QTaskRecoveryManager(store: store)

        let task = QDurableTaskState(taskId: "task-no-plan", sessionId: "s1", originalIntent: "Incomplete", lifecycleState: .running, currentPlanId: "non-existent-plan")
        try store.saveTask(task)

        let status = try await manager.evaluateTaskRecovery(taskId: "task-no-plan")
        if case .corrupted(let id, _) = status {
            #expect(id == "task-no-plan")
        } else {
            #expect(Bool(false), "Expected corrupted status")
        }
    }

    @Test("4. Uncertain in-flight step evaluates to needsVerification status")
    func inFlightStepEvaluatesToNeedsVerification() async throws {
        let store = try QDurableTaskStore(inMemory: true)
        let manager = QTaskRecoveryManager(store: store)

        let step0 = QDurablePlanStepSnapshot(
            stepId: "step-0",
            index: 0,
            actionName: "ui.open_app",
            toolFamily: "ui",
            riskLevel: "level1SafeLocalAction",
            literalAction: "Launch Calculator",
            targetResources: ["Calculator"],
            state: "running" // crashed during execution!
        )

        let plan = QDurablePlanSnapshot(
            planId: "plan-crash-1",
            taskId: "task-crash-1",
            sessionId: "session-crash-1",
            goal: "Launch Calculator",
            steps: [step0]
        )

        let task = QDurableTaskState(
            taskId: "task-crash-1",
            sessionId: "session-crash-1",
            originalIntent: "Launch Calculator",
            lifecycleState: .running,
            currentPlanId: "plan-crash-1",
            currentStepIndex: 0
        )

        try store.savePlan(plan)
        try store.saveTask(task)
        try store.recordEvent(
            QTaskLifecycleEvent(taskId: "task-crash-1", sessionId: "session-crash-1", eventType: .stepStarted)
        )

        let status = try await manager.evaluateTaskRecovery(taskId: "task-crash-1")
        if case .needsVerification(let t, _, let stepIdx, let uncertainStep) = status {
            #expect(t.taskId == "task-crash-1")
            #expect(stepIdx == 0)
            #expect(uncertainStep.actionName == "ui.open_app")
        } else {
            #expect(Bool(false), "Expected needsVerification status")
        }
    }

    @Test("5. Task with security block reason evaluates to securityBlocked status")
    func securityBlockedTaskEvaluatesToBlocked() async throws {
        let store = try QDurableTaskStore(inMemory: true)
        let manager = QTaskRecoveryManager(store: store)

        let task = QDurableTaskState(
            taskId: "task-blocked",
            sessionId: "s1",
            originalIntent: "Blocked Intent",
            lifecycleState: .blocked,
            securityBlockReason: "Targeted denylisted resource"
        )
        try store.saveTask(task)

        let status = try await manager.evaluateTaskRecovery(taskId: "task-blocked")
        if case .securityBlocked(let t, let reason) = status {
            #expect(t.taskId == "task-blocked")
            #expect(reason.contains("denylisted"))
        } else {
            #expect(Bool(false), "Expected securityBlocked status")
        }
    }
}
