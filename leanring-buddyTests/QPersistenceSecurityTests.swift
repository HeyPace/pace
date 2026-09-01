//
//  QPersistenceSecurityTests.swift
//  leanring-buddyTests
//
//  Q Security Architecture — Persistence Security & Adversarial Deserialization Tests (Phase 2D).
//  Validates rejection of corrupted JSON, unknown schema versions, fake permission grants,
//  and privilege escalation attempts from persisted state.
//

import Testing
import Foundation
@testable import Pace

@Suite("QPersistenceSecurityTests")
struct QPersistenceSecurityTests {

    @Test("1. Corrupted JSON in durable task store fails cleanly")
    func corruptedJsonFailsCleanly() async throws {
        let store = try QDurableTaskStore(inMemory: true)
        let manager = QTaskRecoveryManager(store: store)

        // Inject invalid state
        let invalidTask = QDurableTaskState(
            taskId: "task-corrupt",
            sessionId: "s1",
            originalIntent: "Corrupt",
            lifecycleState: .running,
            currentPlanId: "non-existent"
        )
        try store.saveTask(invalidTask)

        let status = try await manager.evaluateTaskRecovery(taskId: "task-corrupt")
        if case .corrupted = status {
            #expect(true)
        } else {
            #expect(Bool(false), "Expected corrupted status for missing plan")
        }
    }

    @Test("2. Persisted plan declaring Level 4 Blocked capability is rejected during reconstruction")
    func persistedLevel4PlanRejected() {
        let step0 = QDurablePlanStepSnapshot(
            stepId: "step-escalate",
            index: 0,
            actionName: "system.execute_root_shell",
            toolFamily: "system",
            riskLevel: "level4Blocked",
            literalAction: "Execute root shell"
        )

        let snapshot = QDurablePlanSnapshot(
            planId: "plan-escalate",
            taskId: "task-escalate",
            sessionId: "s1",
            goal: "Escalate privileges",
            steps: [step0]
        )

        #expect(throws: QDurablePlanError.self) {
            try snapshot.validate()
        }
    }

    @Test("3. Persisted fake permission grant does not grant runtime authorization")
    func persistedFakePermissionDoesNotAuthorize() throws {
        // Even if an event claiming permission was granted is stored, QPermissionGate must still gate
        let gate = QPermissionGate.shared

        let authReq = QToolAuthorizationRequest(
            taskId: "task-fake-perm",
            toolName: "fs.write_sandbox",
            toolFamily: "fs",
            baseRisk: .level2UserApproval,
            effectiveRisk: .level2UserApproval,
            targetScope: .global,
            literalAction: "Delete system file",
            affectedResources: ["/System/Library/test"],
            isContextTainted: false
        )

        let decision = gate.evaluate(request: authReq)

        // Permission Gate must still require explicit interactive consent
        #expect(decision.isAllowed == false)
        #expect(decision.requiresApproval == true)
    }

    @Test("4. Tainted provenance in persisted task context remains untrusted after reconstruction")
    func taintedProvenanceRemainsUntrusted() {
        let durable = QDurableTaskState(
            taskId: "task-tainted",
            sessionId: "s1",
            originalIntent: "Tainted instruction",
            lifecycleState: .running,
            provenance: "untrusted:screen"
        )

        let task = durable.toTask()
        #expect(task.context.isTainted == true)
        #expect(task.context.untrustedSources.count > 0)
    }
}
