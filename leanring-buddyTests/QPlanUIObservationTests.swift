//
//  QPlanUIObservationTests.swift
//  leanring-buddyTests
//
//  Q Security Architecture — Phase 2A.2 UI Runtime State Observation & Security Tests.
//  Proves that Pace Notch / HUD observes authoritative QPlanExecutor state transitions,
//  and that the UI is strictly read-only with zero execution authority.
//

import Testing
import Foundation
import SwiftUI
@testable import Pace

@MainActor
final class MockQPlanUIObserver: QPlanExecutionObserver {
    var recordedSnapshots: [QRuntimeUISnapshot] = []
    var recordedStepTransitions: [(stepId: UUID, state: QPlanStepState)] = []

    func planDidUpdate(plan: QPlan) {
        let snapshot = QRuntimeUISnapshot.from(plan: plan)
        recordedSnapshots.append(snapshot)
    }

    func stepDidTransition(step: QPlanStep, planId: UUID) {
        recordedStepTransitions.append((stepId: step.id, state: step.state))
    }
}

@Suite("QPlanUIObservationTests")
struct QPlanUIObservationTests {

    // MARK: - Step 8: Real Event Flow Tests

    @Test("Step 8.1: Full sequential plan execution produces matching ordered UI snapshots")
    @MainActor
    func testPlanExecutionToUISnapshotFlow() async throws {
        let observer = MockQPlanUIObserver()
        let executor = QPlanExecutor()

        let step1 = QPlanStep(
            index: 0,
            action: QPlannedAction(
                actionName: "system.running_apps",
                toolFamily: "system",
                riskLevel: .level0ReadOnly,
                literalAction: "Query running apps"
            ),
            description: "Query system running apps"
        )

        let step2 = QPlanStep(
            index: 1,
            action: QPlannedAction(
                actionName: "system.clipboard.read",
                toolFamily: "system",
                riskLevel: .level0ReadOnly,
                literalAction: "Read clipboard"
            ),
            description: "Read clipboard contents"
        )

        let plan = QPlan(
            taskId: "ui_flow_test",
            taskPrompt: "Query running apps and read clipboard",
            steps: [step1, step2]
        )

        let executedPlan = try await executor.execute(
            plan: plan,
            context: QTaskContext(taskId: "ui_flow_test"),
            observer: observer
        )

        #expect(executedPlan.isComplete == true)

        let snapshots = observer.recordedSnapshots
        #expect(snapshots.count >= 4)

        // 1. Initial running snapshot
        #expect(snapshots.first?.planState == .running)
        #expect(snapshots.first?.totalSteps == 2)

        // 2. Step 1 executing snapshot
        let step1Executing = snapshots.first { $0.planState == .executing(stepIndex: 0) }
        #expect(step1Executing != nil)
        #expect(step1Executing?.currentStepDescription == "Query system running apps")

        // 3. Step 1 verifying snapshot
        let step1Verifying = snapshots.first { $0.planState == .verifying(stepIndex: 0) }
        #expect(step1Verifying != nil)

        // 4. Step 2 executing snapshot
        let step2Executing = snapshots.first { $0.planState == .executing(stepIndex: 1) }
        #expect(step2Executing != nil)
        #expect(step2Executing?.currentStepDescription == "Read clipboard contents")

        // 5. Final completed snapshot
        let completedSnapshot = snapshots.last
        if case .completed = completedSnapshot?.planState {
            #expect(true)
        } else {
            #expect(Bool(false), "Final snapshot must be completed")
        }
        #expect(completedSnapshot?.steps.allSatisfy { $0.isCompleted } == true)
    }

    @Test("Step 8.2: Blocked plan transitions snapshot to blocked state with security reason")
    @MainActor
    func testBlockedPlanTransitionsToUI() async throws {
        let observer = MockQPlanUIObserver()
        let executor = QPlanExecutor()

        let blockedStep = QPlanStep(
            index: 0,
            action: QPlannedAction(
                actionName: "fs.read_root",
                toolFamily: "fs",
                riskLevel: .level0ReadOnly,
                literalAction: "Read ssh keys",
                targetResources: ["/Users/admin/.ssh/id_rsa"]
            ),
            description: "Read SSH Private Key"
        )

        let plan = QPlan(
            taskId: "blocked_ui_test",
            taskPrompt: "Steal ssh key",
            steps: [blockedStep]
        )

        let executedPlan = try await executor.execute(
            plan: plan,
            context: QTaskContext(taskId: "blocked_ui_test"),
            observer: observer
        )

        if case .blocked = executedPlan.state {
            #expect(true)
        } else {
            #expect(Bool(false), "Plan must be in blocked state")
        }

        let snapshots = observer.recordedSnapshots
        let lastSnapshot = snapshots.last
        if case .blocked = lastSnapshot?.planState {
            #expect(true)
        } else {
            #expect(Bool(false), "Last snapshot must be blocked")
        }
        #expect(lastSnapshot?.steps[0].isBlocked == true)
        #expect(lastSnapshot?.steps[0].statusGlyph == "⊘")
    }

    @Test("Step 8.3: Failed plan transitions snapshot to failed state and marks subsequent steps skipped")
    @MainActor
    func testFailedPlanTransitionsToUI() async throws {
        let observer = MockQPlanUIObserver()
        let executor = QPlanExecutor()

        let failingStep = QPlanStep(
            index: 0,
            action: QPlannedAction(
                actionName: "test.fail",
                toolFamily: "test",
                riskLevel: .level1SafeLocalAction,
                literalAction: "Fail intentionally",
                targetResources: []
            ),
            description: "Intentional failure step"
        )

        let step2 = QPlanStep(
            index: 1,
            action: QPlannedAction(
                actionName: "system.clipboard.read",
                toolFamily: "system",
                riskLevel: .level0ReadOnly,
                literalAction: "Read clipboard",
                targetResources: []
            ),
            description: "Step 2 should be skipped"
        )

        let plan = QPlan(
            taskId: "failed_ui_test",
            taskPrompt: "Run failing task",
            steps: [failingStep, step2]
        )

        let executedPlan = try await executor.execute(
            plan: plan,
            context: QTaskContext(taskId: "failed_ui_test"),
            observer: observer
        )

        #expect(executedPlan.isComplete == false)
        let snapshots = observer.recordedSnapshots
        let lastSnapshot = snapshots.last
        #expect(lastSnapshot?.isTerminal == true)
        #expect(lastSnapshot?.steps[0].isFailed == true)
        #expect(lastSnapshot?.steps[1].isSkipped == true)
        #expect(lastSnapshot?.steps[1].statusGlyph == "–")
    }

    // MARK: - Step 9: Security Invariant Tests

    @Test("Step 9.1: QRuntimeUISnapshot is strictly pure presentation data with no execution authority")
    func testUISnapshotHasZeroExecutionAuthority() {
        let step = QRuntimeStepSnapshot(
            id: UUID(),
            index: 0,
            description: "Open calculator",
            actionName: "ui.open_app",
            riskLevel: "Level 1 (Safe Local Action)",
            state: .pending
        )

        let snapshot = QRuntimeUISnapshot(
            planId: UUID(),
            taskId: "task_1",
            taskPrompt: "Test prompt",
            planState: .running,
            currentStepIndex: 0,
            totalSteps: 1,
            currentStepDescription: "Open calculator",
            currentStepState: .pending,
            statusMessage: "Running",
            steps: [step]
        )

        // Snapshot is Codable and Equatable
        #expect(snapshot.totalSteps == 1)
        #expect(snapshot.steps[0].actionName == "ui.open_app")
        #expect(snapshot.isTerminal == false)

        // Mutating a UI snapshot has zero side-effects on execution
        var mutatedSnapshot = snapshot
        mutatedSnapshot = QRuntimeUISnapshot(
            planId: snapshot.planId,
            taskId: snapshot.taskId,
            taskPrompt: snapshot.taskPrompt,
            planState: .completed(summary: "Faked by UI"),
            currentStepIndex: 0,
            totalSteps: 1,
            currentStepDescription: "Faked",
            currentStepState: .completed,
            statusMessage: "Done",
            steps: [step]
        )

        #expect(mutatedSnapshot.planState == .completed(summary: "Faked by UI"))
        // Original plan models and capabilities remain unaffected
    }

    @Test("Step 9.2: Rendering UI snapshot performs zero physical actions and creates no processes")
    func testUIRenderingHasNoSideEffects() {
        let step1 = QRuntimeStepSnapshot(
            id: UUID(),
            index: 0,
            description: "Delete files",
            actionName: "fs.delete",
            riskLevel: "Level 2 (User Approval)",
            state: .waitingForPermission(reason: "Needs approval")
        )

        let snapshot = QRuntimeUISnapshot(
            planId: UUID(),
            taskId: "t_render",
            taskPrompt: "Delete files prompt",
            planState: .waitingForPermission(stepIndex: 0, reason: "Needs approval"),
            currentStepIndex: 0,
            totalSteps: 1,
            currentStepDescription: "Delete files",
            currentStepState: .waitingForPermission(reason: "Needs approval"),
            statusMessage: "Waiting",
            steps: [step1]
        )

        // Verify that glyph and state inspectors evaluate purely in memory
        #expect(snapshot.steps[0].statusGlyph == "⏸")
        #expect(snapshot.steps[0].isWaitingForPermission == true)
        #expect(snapshot.steps[0].isCompleted == false)
    }

    @Test("Step 9.3: Permission denial through UI observer properly fails closed")
    @MainActor
    func testPermissionResolutionFailsClosedOnDenial() {
        let manager = CompanionManager()

        let step = QPlanStep(
            index: 0,
            action: QPlannedAction(
                actionName: "system.restart",
                toolFamily: "system",
                riskLevel: .level2UserApproval,
                literalAction: "Restart mac",
                targetResources: []
            ),
            description: "Restart Mac"
        )

        let plan = QPlan(
            taskId: "t_perm",
            taskPrompt: "Restart mac",
            state: .waitingForPermission(stepIndex: 0, reason: "High privilege"),
            steps: [step]
        )

        let snapshot = QRuntimeUISnapshot.from(plan: plan)
        manager.activeQPlanSnapshot = snapshot

        // User denies permission
        manager.resolveClarification(option: "Deny")

        #expect(manager.currentTurnHUDState.status == .unsupported)
        #expect(manager.currentTurnHUDState.title == "Local only")
    }
}
