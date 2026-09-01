//
//  QDurableTaskStateTests.swift
//  leanring-buddyTests
//
//  Q Security Architecture — Durable Task State Tests (Phase 2D).
//  Validates serialization, round-trip restoration, schema integrity, and sanitized persistence.
//

import Testing
import Foundation
@testable import Pace

@Suite("QDurableTaskStateTests")
struct QDurableTaskStateTests {

    @Test("1. Task state round-trip serialization preserves exact properties")
    func taskStateSerializationRoundTrip() throws {
        let budget = QAgentBudget(maxExecutionSteps: 15, maxReplans: 2, maxDurationSeconds: 120)
        let original = QDurableTaskState(
            taskId: "task-test-1",
            sessionId: "session-test-1",
            originalIntent: "Open Calculator and verify running state",
            taskCreationTimestamp: Date(timeIntervalSince1970: 1700000000),
            lastUpdatedTimestamp: Date(timeIntervalSince1970: 1700000010),
            lifecycleState: .running,
            currentPlanId: "plan-test-1",
            currentStepIndex: 1,
            completedStepIds: ["step-0"],
            failedStepIds: [],
            skippedStepIds: [],
            verificationEvidenceReferences: ["Calculator is active"],
            goalEvaluationState: "partially_satisfied",
            replanAttemptCount: 1,
            maxReplanAttempts: 2,
            lastKnownError: nil,
            securityBlockReason: nil,
            provenance: "trusted:user",
            schemaVersion: 1,
            budget: budget
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(QDurableTaskState.self, from: data)

        #expect(decoded.taskId == original.taskId)
        #expect(decoded.sessionId == original.sessionId)
        #expect(decoded.originalIntent == original.originalIntent)
        #expect(decoded.lifecycleState == original.lifecycleState)
        #expect(decoded.currentPlanId == original.currentPlanId)
        #expect(decoded.currentStepIndex == original.currentStepIndex)
        #expect(decoded.completedStepIds == original.completedStepIds)
        #expect(decoded.verificationEvidenceReferences == original.verificationEvidenceReferences)
        #expect(decoded.replanAttemptCount == original.replanAttemptCount)
        #expect(decoded.budget.maxExecutionSteps == 15)
    }

    @Test("2. Reconstructing QTask from QDurableTaskState preserves provenance and context")
    func reconstructQTaskFromDurableState() {
        let durable = QDurableTaskState(
            taskId: "task-recon-1",
            sessionId: "session-recon-1",
            originalIntent: "Read screen text",
            lifecycleState: .completed,
            provenance: "untrusted:screen"
        )

        let task = durable.toTask()
        #expect(task.taskId == "task-recon-1")
        #expect(task.intent == "Read screen text")
        #expect(task.context.isTainted == true)
        if case .completed = task.state {
            #expect(true)
        } else {
            #expect(Bool(false), "Expected completed state")
        }
    }

    @Test("3. Durable Plan Snapshot validates step ordering and allowed capabilities")
    func durablePlanSnapshotValidation() throws {
        let step0 = QDurablePlanStepSnapshot(
            stepId: "step-0",
            index: 0,
            actionName: "system.running_apps",
            toolFamily: "system",
            riskLevel: "level0ReadOnly",
            literalAction: "Query running apps",
            targetResources: [],
            arguments: [:],
            expectedOutcomes: ["Find Calculator"]
        )

        let step1 = QDurablePlanStepSnapshot(
            stepId: "step-1",
            index: 1,
            actionName: "ui.open_app",
            toolFamily: "ui",
            riskLevel: "level1SafeLocalAction",
            literalAction: "Launch Calculator",
            targetResources: ["Calculator"],
            arguments: ["appName": "Calculator"]
        )

        let snapshot = QDurablePlanSnapshot(
            planId: "plan-valid-1",
            taskId: "task-valid-1",
            sessionId: "session-valid-1",
            goal: "Launch Calculator",
            steps: [step0, step1]
        )

        let plan = try snapshot.validate()
        #expect(plan.steps.count == 2)
        #expect(plan.steps[0].action.actionName == "system.running_apps")
        #expect(plan.steps[1].action.actionName == "ui.open_app")
    }

    @Test("4. Durable Plan Snapshot rejects invalid step ordering")
    func durablePlanSnapshotRejectsInvalidOrder() {
        let step0 = QDurablePlanStepSnapshot(
            stepId: "step-0",
            index: 1, // Out of order!
            actionName: "system.running_apps",
            toolFamily: "system",
            riskLevel: "level0ReadOnly",
            literalAction: "Query running apps"
        )

        let snapshot = QDurablePlanSnapshot(
            planId: "plan-invalid-order",
            taskId: "task-invalid",
            sessionId: "session-invalid",
            goal: "Invalid Plan",
            steps: [step0]
        )

        #expect(throws: QDurablePlanError.self) {
            try snapshot.validate()
        }
    }

    @Test("5. Durable Plan Snapshot rejects unknown capabilities")
    func durablePlanSnapshotRejectsUnknownCapabilities() {
        let step0 = QDurablePlanStepSnapshot(
            stepId: "step-0",
            index: 0,
            actionName: "network.unauthorized_cloud_upload",
            toolFamily: "network",
            riskLevel: "level0ReadOnly",
            literalAction: "Exfiltrate Data"
        )

        let snapshot = QDurablePlanSnapshot(
            planId: "plan-untrusted-tool",
            taskId: "task-untrusted",
            sessionId: "session-untrusted",
            goal: "Exfiltrate",
            steps: [step0]
        )

        #expect(throws: QDurablePlanError.self) {
            try snapshot.validate()
        }
    }
}
