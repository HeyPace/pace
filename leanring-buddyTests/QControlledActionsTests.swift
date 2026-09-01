//
//  QControlledActionsTests.swift
//  leanring-buddyTests
//
//  Q Security Architecture — Controlled Real-World Actions Tests (Phase 2E).
//  Validates the two new Level 2/3 capabilities (system.clipboard.write, app.quit), the
//  execution-identity-bound approval architecture (QApprovalCoordinator), fail-closed
//  capability/risk validation, and their interaction with the existing Phase 2D durability,
//  idempotency, budget, and goal-evaluation invariants.
//

import Testing
import AppKit
import Foundation
@testable import Pace

@Suite("QControlledActionsTests")
struct QControlledActionsTests {

    // MARK: - 1. Unknown capability -> rejected

    @Test("1. Unknown capability is rejected by the schema parser")
    func unknownCapabilityRejected() {
        let json = """
        {
          "taskPrompt": "Reboot the machine",
          "steps": [
            {
              "actionName": "system.reboot",
              "toolFamily": "system",
              "description": "Reboot macOS"
            }
          ]
        }
        """

        #expect(throws: QModelPlanParseError.self) {
            try QModelPlanParser.parse(rawText: json, taskId: "t_unknown_2e", taskPrompt: "Reboot the machine")
        }
    }

    // MARK: - 2. Unknown / mismatched risk level -> rejected

    @Test("2. A declared risk level that does not match the tool's registered level is rejected (also closes a model-controlled risk-downgrade path)")
    func mismatchedRiskLevelRejected() {
        // app.quit is registered Level 3 (high risk). A model declaring Level 0 for it is
        // exactly the kind of self-declared downgrade that must never be trusted — it MUST be
        // rejected outright, not silently coerced to the tool's true registered level.
        let json = """
        {
          "taskPrompt": "Quit Calculator",
          "steps": [
            {
              "actionName": "app.quit",
              "toolFamily": "app",
              "riskLevel": "level0ReadOnly",
              "description": "Quit Calculator",
              "targetResources": ["Calculator"]
            }
          ]
        }
        """

        #expect(throws: QModelPlanParseError.self) {
            try QModelPlanParser.parse(rawText: json, taskId: "t_mismatch_2e", taskPrompt: "Quit Calculator")
        }

        // A genuinely unrecognized risk string is equally rejected, not silently defaulted.
        let garbageJSON = """
        {
          "taskPrompt": "Write to clipboard",
          "steps": [
            {
              "actionName": "system.clipboard.write",
              "toolFamily": "system",
              "riskLevel": "level-nine-thousand",
              "description": "Write text",
              "parameters": {"text": "hello"}
            }
          ]
        }
        """

        #expect(throws: QModelPlanParseError.self) {
            try QModelPlanParser.parse(rawText: garbageJSON, taskId: "t_garbage_risk_2e", taskPrompt: "Write to clipboard")
        }
    }

    // MARK: - 3. Level 4 -> rejected

    @Test("3. A model attempting to declare Level 4 (Blocked) for a real registered tool is rejected")
    func level4DeclarationRejected() {
        let json = """
        {
          "taskPrompt": "Write to clipboard",
          "steps": [
            {
              "actionName": "system.clipboard.write",
              "toolFamily": "system",
              "riskLevel": "level4Blocked",
              "description": "Write text",
              "parameters": {"text": "hello"}
            }
          ]
        }
        """

        #expect(throws: QModelPlanParseError.self) {
            try QModelPlanParser.parse(rawText: json, taskId: "t_level4_2e", taskPrompt: "Write to clipboard")
        }
    }

    // MARK: - 4. Level 2 action -> authorization path enforced

    @Test("4. Level 2 clipboard write halts for explicit approval and does not execute silently")
    func level2ActionRequiresAuthorization() async throws {
        let marker = "q-2e-marker-\(UUID().uuidString)"
        let mockModel = MockAutonomousModelProvider()
        mockModel.structuredPlansToReturn = [
            """
            {
              "taskPrompt": "Write marker to clipboard",
              "steps": [
                {
                  "actionName": "system.clipboard.write",
                  "toolFamily": "system",
                  "description": "Write marker text to the system clipboard",
                  "parameters": {"text": "\(marker)"}
                }
              ]
            }
            """
        ]

        let memory = QSQLiteMemoryStore(inMemory: true)
        let runtime = QCoreRuntime(
            modelProvider: mockModel,
            memoryProvider: memory,
            executionProvider: QExecutionService.shared,
            endpointName: "controlled-actions-l2-\(UUID().uuidString)"
        )

        let task = try await runtime.submitIntent(prompt: "Write marker to clipboard")

        guard case .awaitingApproval(let req) = task.state else {
            #expect(Bool(false), "Expected task to halt awaiting approval, got: \(task.state)")
            return
        }
        #expect(req.toolName == "system.clipboard.write")
        #expect(req.riskLevel == .level2UserApproval)
        #expect(req.isReversible == true)
        #expect(req.executionIdentity != nil)
        #expect(!req.reason.isEmpty)
        #expect(!req.expectedEffect.isEmpty)

        // Must NOT have executed yet — the clipboard must not already contain the marker.
        #expect(NSPasteboard.general.string(forType: .string) != marker)
    }

    // MARK: - 5. Level 3 action -> approval required

    @Test("5. Level 3 app.quit halts for explicit approval and does not execute silently")
    func level3ActionRequiresApproval() async throws {
        let mockModel = MockAutonomousModelProvider()
        mockModel.structuredPlansToReturn = [
            """
            {
              "taskPrompt": "Quit a non-existent app",
              "steps": [
                {
                  "actionName": "app.quit",
                  "toolFamily": "app",
                  "description": "Quit NoSuchApp2E",
                  "targetResources": ["NoSuchApp2E"],
                  "parameters": {"appName": "NoSuchApp2E"}
                }
              ]
            }
            """
        ]

        let memory = QSQLiteMemoryStore(inMemory: true)
        let runtime = QCoreRuntime(
            modelProvider: mockModel,
            memoryProvider: memory,
            executionProvider: QExecutionService.shared,
            endpointName: "controlled-actions-l3-\(UUID().uuidString)"
        )

        let task = try await runtime.submitIntent(prompt: "Quit a non-existent app")

        guard case .awaitingApproval(let req) = task.state else {
            #expect(Bool(false), "Expected task to halt awaiting approval, got: \(task.state)")
            return
        }
        #expect(req.toolName == "app.quit")
        #expect(req.riskLevel == .level3HighRisk)
        #expect(req.executionIdentity != nil)
    }

    // MARK: - 6. Approval for action A cannot authorize action B

    @Test("6. Approving one execution identity never grants a different execution identity")
    func approvalDoesNotCrossAuthorizeAnotherAction() {
        let taskId = "task-cross-\(UUID().uuidString)"
        let planId = UUID().uuidString

        let identityA = QExecutionIdentity(taskId: taskId, planId: planId, stepId: "step-A", actionName: "app.quit", targetResources: ["AppA"])
        let identityB = QExecutionIdentity(taskId: taskId, planId: planId, stepId: "step-B", actionName: "app.quit", targetResources: ["AppB"])

        let requestA = QApprovalRequest(
            taskId: taskId, toolName: "app.quit", riskLevel: .level3HighRisk,
            literalAction: "Quit AppA", affectedResources: ["AppA"], scope: .global,
            reason: "test", isContextTainted: false, executionIdentity: identityA
        )
        let requestB = QApprovalRequest(
            taskId: taskId, toolName: "app.quit", riskLevel: .level3HighRisk,
            literalAction: "Quit AppB", affectedResources: ["AppB"], scope: .global,
            reason: "test", isContextTainted: false, executionIdentity: identityB
        )

        // Two distinct execution attempts must never collide on the same approval id.
        #expect(requestA.id != requestB.id)

        QApprovalCoordinator.shared.recordPending(requestA)
        QApprovalCoordinator.shared.recordPending(requestB)

        let outcome = QApprovalCoordinator.shared.resolve(approvalId: requestA.id, decision: .approved)
        guard case .granted(let fingerprintA) = outcome else {
            #expect(Bool(false), "Expected requestA to be granted, got: \(outcome)")
            return
        }
        #expect(fingerprintA == identityA.stepFingerprint)

        // Action A's grant must not spill over to action B, which was never resolved.
        #expect(QApprovalCoordinator.shared.consumeGrantIfPresent(fingerprint: identityB.stepFingerprint) == false)
        // Action A's own grant is still there, exactly once.
        #expect(QApprovalCoordinator.shared.consumeGrantIfPresent(fingerprint: identityA.stepFingerprint) == true)
    }

    // MARK: - 7. Security denial cannot be bypassed by replanning

    @Test("7. A blocked plan state (e.g. security-denied app.quit) is never replanned")
    func securityDenialNeverReplanned() {
        let step = QPlanStep(
            index: 0,
            action: QPlannedAction(
                actionName: "app.quit",
                toolFamily: "app",
                riskLevel: .level3HighRisk,
                literalAction: "Quit Finder",
                targetResources: ["Finder"]
            ),
            description: "Quit Finder",
            state: .blocked(reason: "Permission Gate Denied")
        )
        var plan = QPlan(taskId: "t-blocked-2e", sessionId: "s-blocked-2e", taskPrompt: "Quit Finder", steps: [step])
        plan.state = .blocked(reason: "Permission Gate Denied: Level 3 action denied", blockedStepIndex: 0)

        let evaluation = QGoalEvaluator.shared.evaluate(goal: "Quit Finder", plan: plan, context: QTaskContext(taskId: "t-blocked-2e"))
        #expect(evaluation.isBlocked == true)

        let controller = QReplanController(maxReplans: 2)
        let decision = controller.evaluateReplan(goal: "Quit Finder", currentPlan: plan, evaluation: evaluation)

        guard case .denied(let reason) = decision else {
            #expect(Bool(false), "Expected replanning to be denied for a security-blocked plan")
            return
        }
        #expect(reason.localizedCaseInsensitiveContains("security"))
    }

    // MARK: - 8. Persisted approval does not silently re-authorize after recovery

    @Test("8. A durably-persisted awaiting_approval task cannot be rubber-stamped without a real coordinator grant")
    func persistedApprovalNeverSelfAuthorizes() async throws {
        let store = try QDurableTaskStore(inMemory: true)
        let runtime = QCoreRuntime(
            modelProvider: QModelRouter.shared,
            memoryProvider: QSQLiteMemoryStore(inMemory: true),
            executionProvider: QExecutionService.shared,
            durableStore: store
        )

        let taskId = "task-persisted-approval-\(UUID().uuidString)"
        let planId = UUID().uuidString
        let stepId = UUID().uuidString

        let identity = QExecutionIdentity(taskId: taskId, planId: planId, stepId: stepId, actionName: "app.quit", targetResources: ["Ghost"])
        // Deliberately never call QApprovalCoordinator.recordPending/resolve for this identity —
        // this simulates state that was persisted before a crash/restart, where the in-memory
        // coordinator (and therefore any real "the user actually approved this" fact) is gone.
        let neverPresentedApprovalId = QApprovalRequest.deterministicId(fingerprint: identity.stepFingerprint)

        let planStep = QDurablePlanStepSnapshot(
            stepId: stepId, index: 0, actionName: "app.quit", toolFamily: "app",
            riskLevel: "level3HighRisk", literalAction: "Quit Ghost",
            targetResources: ["Ghost"], arguments: ["appName": "Ghost"],
            state: "waitingForPermission:Approval required"
        )
        let planSnapshot = QDurablePlanSnapshot(
            planId: planId, taskId: taskId, sessionId: "s-persisted", goal: "Quit Ghost", steps: [planStep]
        )
        let taskState = QDurableTaskState(
            taskId: taskId, sessionId: "s-persisted", originalIntent: "Quit Ghost",
            lifecycleState: .awaitingApproval, currentPlanId: planId, currentStepIndex: 0,
            securityBlockReason: "Approval required"
        )
        try store.savePlan(planSnapshot)
        try store.saveTask(taskState)

        // No grant exists in the (fresh, unrelated-to-this-identity) coordinator state.
        #expect(QApprovalCoordinator.shared.consumeGrantIfPresent(fingerprint: identity.stepFingerprint) == false)

        let result = try await runtime.resolveApproval(taskId: taskId, approvalId: neverPresentedApprovalId, decision: .approved)

        guard case .failed(let reason) = result.state else {
            #expect(Bool(false), "Expected resolveApproval to fail closed for an id the coordinator never held, got: \(result.state)")
            return
        }
        #expect(reason.localizedCaseInsensitiveContains("not pending") || reason.localizedCaseInsensitiveContains("not found") || reason.localizedCaseInsensitiveContains("expired"))
    }

    // MARK: - 9. Context taint survives recovery

    @Test("9. Reconstructing a durable task with untrusted provenance preserves taint")
    func taintSurvivesRecoveryReconstruction() {
        let taskState = QDurableTaskState(
            taskId: "task-taint-2e", sessionId: "s-taint-2e", originalIntent: "Quit Calculator",
            lifecycleState: .awaitingApproval, provenance: "untrusted"
        )
        let reconstructed = taskState.toTask()
        #expect(reconstructed.context.isTainted == true)
    }

    // MARK: - 10 & 11. Crash during action -> observation before retry; uncertain state fails closed

    @Test("10-11. An uncertain in-flight app.quit step is never blindly marked complete — it fails closed to pending for a single safe re-execution")
    func uncertainAppQuitStepFailsClosedToPending() async throws {
        let store = try QDurableTaskStore(inMemory: true)
        let recoveryManager = QTaskRecoveryManager(store: store)

        let taskState = QDurableTaskState(
            taskId: "task-uncertain-quit", sessionId: "s-uncertain-quit", originalIntent: "Quit GhostApp",
            lifecycleState: .running, currentPlanId: "plan-uncertain-quit", currentStepIndex: 0
        )
        let uncertainStep = QDurablePlanStepSnapshot(
            stepId: "step-uncertain-quit", index: 0, actionName: "app.quit", toolFamily: "app",
            riskLevel: "level3HighRisk", literalAction: "Quit GhostApp",
            targetResources: ["GhostApp"], arguments: ["appName": "GhostApp"],
            state: "running"
        )
        let planSnapshot = QDurablePlanSnapshot(
            planId: "plan-uncertain-quit", taskId: "task-uncertain-quit", sessionId: "s-uncertain-quit",
            goal: "Quit GhostApp", steps: [uncertainStep]
        )

        let (updatedTask, updatedPlan, isVerified) = try await recoveryManager.resolveUncertainStep(
            task: taskState, plan: planSnapshot, stepIndex: 0, uncertainStep: uncertainStep
        )

        // app.quit has no dedicated observation-first check (unlike ui.open_app / fs.write_sandbox),
        // so an uncertain attempt must fail closed: not verified, reset to pending for one safe retry
        // — never silently marked completed on a guess.
        #expect(isVerified == false)
        #expect(updatedPlan.steps[0].state == "pending")
        #expect(updatedTask.completedStepIds.isEmpty)
    }

    // MARK: - 12. Execution identity prevents duplicate side effects

    @Test("12. A granted one-time approval fingerprint can be consumed exactly once")
    func executionIdentityGrantIsSingleUse() {
        let identity = QExecutionIdentity(
            taskId: "task-single-use-\(UUID().uuidString)", planId: UUID().uuidString,
            stepId: UUID().uuidString, actionName: "app.quit", targetResources: ["Once"]
        )
        let request = QApprovalRequest(
            taskId: identity.taskId, toolName: "app.quit", riskLevel: .level3HighRisk,
            literalAction: "Quit Once", affectedResources: ["Once"], scope: .global,
            reason: "test", isContextTainted: false, executionIdentity: identity
        )
        QApprovalCoordinator.shared.recordPending(request)

        let outcome = QApprovalCoordinator.shared.resolve(approvalId: request.id, decision: .approved)
        #expect(outcome == .granted(fingerprint: identity.stepFingerprint))

        // First consumption succeeds...
        #expect(QApprovalCoordinator.shared.consumeGrantIfPresent(fingerprint: identity.stepFingerprint) == true)
        // ...a second consumption of the SAME fingerprint must never fire again (no duplicate side effect).
        #expect(QApprovalCoordinator.shared.consumeGrantIfPresent(fingerprint: identity.stepFingerprint) == false)
    }

    // MARK: - 13. Budget exhaustion blocks further execution / new actions consume budget

    @Test("13. Executing a Level 2/3 action through the approval flow consumes the same execution-step budget as any other action")
    func approvedActionConsumesExecutionBudget() async throws {
        let store = try QDurableTaskStore(inMemory: true)
        let mockModel = MockAutonomousModelProvider()
        mockModel.structuredPlansToReturn = [
            """
            {
              "taskPrompt": "Write budget marker to clipboard",
              "steps": [
                {
                  "actionName": "system.clipboard.write",
                  "toolFamily": "system",
                  "description": "Write budget marker",
                  "parameters": {"text": "q-2e-budget-marker"}
                }
              ]
            }
            """
        ]
        let runtime = QCoreRuntime(
            modelProvider: mockModel,
            memoryProvider: QSQLiteMemoryStore(inMemory: true),
            executionProvider: QExecutionService.shared,
            durableStore: store,
            endpointName: "controlled-actions-budget-\(UUID().uuidString)"
        )

        let task = try await runtime.submitIntent(prompt: "Write budget marker to clipboard")
        guard case .awaitingApproval(let req) = task.state, let identity = req.executionIdentity else {
            #expect(Bool(false), "Expected awaiting approval with a bound execution identity")
            return
        }

        let beforeBudget = try store.getTask(taskId: task.taskId)?.budget
        let beforeCount = beforeBudget?.executedStepsCount ?? 0

        let resolved = try await runtime.resolveApproval(taskId: task.taskId, approvalId: req.id, decision: .approved)
        #expect(resolved.state.isTerminal == true)

        let afterBudget = try store.getTask(taskId: task.taskId)?.budget
        // The real execution triggered by approval must be recorded against the same budget —
        // it is never a free, budget-exempt path just because it happened via resolveApproval.
        #expect((afterBudget?.executedStepsCount ?? 0) > beforeCount)
        _ = identity
    }

    // MARK: - 14. Goal evaluation requires empirical evidence

    @Test("14. A failed app.quit step is never counted as satisfying evidence")
    func goalEvaluationRejectsUnverifiedQuit() {
        let failedStep = QPlanStep(
            index: 0,
            action: QPlannedAction(actionName: "app.quit", toolFamily: "app", riskLevel: .level3HighRisk, literalAction: "Quit Ghost", targetResources: ["Ghost"]),
            description: "Quit Ghost",
            state: .failed(reason: "Application 'Ghost' is still running after a termination request.")
        )
        var plan = QPlan(taskId: "t-goal-2e", sessionId: "s-goal-2e", taskPrompt: "Quit Ghost", steps: [failedStep])
        plan.state = .failed(reason: "Step 0 failed", failedStepIndex: 0)

        let evaluation = QGoalEvaluator.shared.evaluate(goal: "Quit Ghost", plan: plan, context: QTaskContext(taskId: "t-goal-2e"))
        #expect(evaluation.isSatisfied == false)
        #expect(evaluation.evidence.isEmpty)
    }

    // MARK: - 15. Full autonomous loop works with an approved action

    @Test("15. Full loop: submit -> awaiting approval -> resolve approved -> completed, with real clipboard verification")
    func fullLoopCompletesAfterApproval() async throws {
        let marker = "q-2e-full-loop-\(UUID().uuidString)"
        let mockModel = MockAutonomousModelProvider()
        mockModel.structuredPlansToReturn = [
            """
            {
              "taskPrompt": "Write marker to clipboard",
              "steps": [
                {
                  "actionName": "system.clipboard.write",
                  "toolFamily": "system",
                  "description": "Write marker text to the system clipboard",
                  "parameters": {"text": "\(marker)"}
                }
              ]
            }
            """
        ]

        let store = try QDurableTaskStore(inMemory: true)
        let runtime = QCoreRuntime(
            modelProvider: mockModel,
            memoryProvider: QSQLiteMemoryStore(inMemory: true),
            executionProvider: QExecutionService.shared,
            durableStore: store,
            endpointName: "controlled-actions-fullloop-\(UUID().uuidString)"
        )

        let task = try await runtime.submitIntent(prompt: "Write marker to clipboard")
        guard case .awaitingApproval(let req) = task.state else {
            #expect(Bool(false), "Expected awaiting approval")
            return
        }

        let resolved = try await runtime.resolveApproval(taskId: task.taskId, approvalId: req.id, decision: .approved)

        guard case .completed(let summary) = resolved.state else {
            #expect(Bool(false), "Expected the task to complete after approval, got: \(resolved.state)")
            return
        }
        #expect(!summary.isEmpty)
        #expect(NSPasteboard.general.string(forType: .string) == marker)
    }

    @Test("15b. A denied approval halts the task and never executes the action")
    func fullLoopHaltsAfterDenial() async throws {
        let marker = "q-2e-denied-\(UUID().uuidString)"
        let mockModel = MockAutonomousModelProvider()
        mockModel.structuredPlansToReturn = [
            """
            {
              "taskPrompt": "Write denied marker to clipboard",
              "steps": [
                {
                  "actionName": "system.clipboard.write",
                  "toolFamily": "system",
                  "description": "Write denied marker text",
                  "parameters": {"text": "\(marker)"}
                }
              ]
            }
            """
        ]

        let runtime = QCoreRuntime(
            modelProvider: mockModel,
            memoryProvider: QSQLiteMemoryStore(inMemory: true),
            executionProvider: QExecutionService.shared,
            endpointName: "controlled-actions-denied-\(UUID().uuidString)"
        )

        let task = try await runtime.submitIntent(prompt: "Write denied marker to clipboard")
        guard case .awaitingApproval(let req) = task.state else {
            #expect(Bool(false), "Expected awaiting approval")
            return
        }

        let resolved = try await runtime.resolveApproval(taskId: task.taskId, approvalId: req.id, decision: .denied(reason: "not now"))

        guard case .failed = resolved.state else {
            #expect(Bool(false), "Expected the task to fail after denial, got: \(resolved.state)")
            return
        }
        #expect(NSPasteboard.general.string(forType: .string) != marker)
    }

    // MARK: - 16. Full regression remains green — asserted at the CI/validation-gate level via
    // scripts/test-pace.sh, not a single in-process test; see docs/PHASE_2E_CONTROLLED_ACTIONS.md.

    // MARK: - 17. Real macOS E2E: open an app (Level 1, exact "Open Calculator" mechanism), then
    // quit it via the new Level 3 approval-gated capability, verified via NSWorkspace.
    //
    // Deliberately targets "Dictionary" rather than Calculator: several other suites in this test
    // target (QAgentE2ETests, QFirstRealRunTests, QClosedLoopAgentTests, ...) open and assert on
    // real Calculator state concurrently, and Swift Testing may run suites in parallel — this test
    // must not quit an app another concurrently-running test depends on being open.

    @Test("17. Real macOS E2E — open Dictionary, then approve and execute app.quit, verified via NSWorkspace")
    func realMacOSE2EQuitAfterApproval() async throws {
        let targetApp = "Dictionary"

        // Step 1: open the app through the existing, unaffected Level 1 ui.open_app path.
        let mockOpenModel = MockAutonomousModelProvider()
        mockOpenModel.structuredPlansToReturn = [
            """
            {
              "taskPrompt": "Open \(targetApp)",
              "steps": [
                {
                  "actionName": "ui.open_app",
                  "toolFamily": "app",
                  "description": "Open \(targetApp)",
                  "targetResources": ["\(targetApp)"],
                  "parameters": {"appName": "\(targetApp)"}
                }
              ]
            }
            """
        ]
        let openRuntime = QCoreRuntime(
            modelProvider: mockOpenModel,
            memoryProvider: QSQLiteMemoryStore(inMemory: true),
            executionProvider: QExecutionService.shared,
            endpointName: "controlled-actions-e2e-open-\(UUID().uuidString)"
        )
        let openTask = try await openRuntime.submitIntent(prompt: "Open \(targetApp)")
        #expect(openTask.state.isCompleted == true)

        // ui.open_app dispatches NSWorkspace.openApplication asynchronously and does not itself
        // wait for the process to register — poll briefly to tolerate real cold-launch latency
        // rather than racing a single instantaneous NSWorkspace check.
        var isRunningBeforeQuit = false
        for _ in 0..<20 {
            isRunningBeforeQuit = NSWorkspace.shared.runningApplications.contains { app in
                app.localizedName == targetApp
            }
            if isRunningBeforeQuit { break }
            try? await Task.sleep(nanoseconds: 150_000_000) // 150ms
        }
        #expect(isRunningBeforeQuit == true)

        // Step 2: quit the app through the new Level 3 approval-gated capability.
        let mockQuitModel = MockAutonomousModelProvider()
        mockQuitModel.structuredPlansToReturn = [
            """
            {
              "taskPrompt": "Quit \(targetApp)",
              "steps": [
                {
                  "actionName": "app.quit",
                  "toolFamily": "app",
                  "description": "Quit \(targetApp)",
                  "targetResources": ["\(targetApp)"],
                  "parameters": {"appName": "\(targetApp)"}
                }
              ]
            }
            """
        ]
        let quitRuntime = QCoreRuntime(
            modelProvider: mockQuitModel,
            memoryProvider: QSQLiteMemoryStore(inMemory: true),
            executionProvider: QExecutionService.shared,
            endpointName: "controlled-actions-e2e-quit-\(UUID().uuidString)"
        )

        let quitTask = try await quitRuntime.submitIntent(prompt: "Quit \(targetApp)")
        guard case .awaitingApproval(let req) = quitTask.state else {
            #expect(Bool(false), "Expected quit to halt for explicit approval, got: \(quitTask.state)")
            return
        }
        #expect(req.riskLevel == .level3HighRisk)

        let resolved = try await quitRuntime.resolveApproval(taskId: quitTask.taskId, approvalId: req.id, decision: .approved)
        guard case .completed = resolved.state else {
            #expect(Bool(false), "Expected \(targetApp) quit to complete after approval, got: \(resolved.state)")
            return
        }

        let isRunningAfterQuit = NSWorkspace.shared.runningApplications.contains { app in
            app.localizedName == targetApp
        }
        #expect(isRunningAfterQuit == false)
    }
}
