//
//  QApprovalHUDTests.swift
//  leanring-buddyTests
//
//  Q Security Architecture — Approval UI Bridge Tests (Phase 2F).
//  Proves that the existing live Pace HUD Allow/Deny affordance actually resolves a real
//  Phase 2E controlled action end-to-end, rather than the pre-2F standing-grant dead end that
//  never resumed execution. See docs/PHASE_2F_APPROVAL_UI_BRIDGE.md.
//

import Testing
import AppKit
import Foundation
@testable import Pace

@Suite("QApprovalHUDTests")
struct QApprovalHUDTests {

    // MARK: - 1. Reconstruction correctness (pure, no side effects)

    @Test("1. QRuntimeUISnapshot.pendingApproval reconstructs the exact deterministic id a live halt would record")
    func pendingApprovalReconstructsMatchingDeterministicId() {
        let taskId = "t-recon-\(UUID().uuidString)"
        let stepId = UUID()
        let planId = UUID()

        let step = QPlanStep(
            id: stepId,
            index: 0,
            action: QPlannedAction(
                actionName: "app.quit",
                toolFamily: "app",
                riskLevel: .level3HighRisk,
                literalAction: "Quit Stickies",
                targetResources: ["Stickies"]
            ),
            description: "Quit Stickies",
            state: .waitingForPermission(reason: "Approval required")
        )
        let plan = QPlan(
            id: planId,
            taskId: taskId,
            taskPrompt: "Quit Stickies",
            state: .waitingForPermission(stepIndex: 0, reason: "Approval required"),
            steps: [step]
        )

        let snapshot = QRuntimeUISnapshot.from(plan: plan)
        let reconstructed = snapshot.pendingApproval

        #expect(reconstructed != nil)
        #expect(reconstructed?.toolName == "app.quit")
        #expect(reconstructed?.riskLevel == .level3HighRisk)
        #expect(reconstructed?.isReversible == false)
        #expect(reconstructed?.affectedResources == ["Stickies"])

        let expectedIdentity = QExecutionIdentity(
            taskId: taskId, planId: planId.uuidString, stepId: stepId.uuidString,
            actionName: "app.quit", targetResources: ["Stickies"]
        )
        let expectedId = QApprovalRequest.deterministicId(fingerprint: expectedIdentity.stepFingerprint)
        #expect(reconstructed?.id == expectedId)
    }

    @Test("1b. pendingApproval is nil when the plan is not actually waiting for permission")
    func pendingApprovalNilWhenNotWaiting() {
        let step = QPlanStep(
            index: 0,
            action: QPlannedAction(actionName: "test.noop", toolFamily: "test", riskLevel: .level0ReadOnly, literalAction: "noop"),
            description: "noop",
            state: .completed
        )
        let plan = QPlan(taskId: "t-not-waiting", taskPrompt: "noop", state: .completed(summary: "done"), steps: [step])
        let snapshot = QRuntimeUISnapshot.from(plan: plan)
        #expect(snapshot.pendingApproval == nil)
    }

    // MARK: - 2. HUD copy distinction (pure, no side effects)

    @Test("2. Level 3 approval copy is visually distinct from Level 2 approval copy")
    func qApprovalRequestHUDCopyDiffersByRiskLevel() {
        let identityL2 = QExecutionIdentity(taskId: "t-l2", planId: "p-l2", stepId: "s-l2", actionName: "system.clipboard.write")
        let level2Request = QApprovalRequest(
            taskId: "t-l2", toolName: "system.clipboard.write", riskLevel: .level2UserApproval,
            literalAction: "Write to clipboard", affectedResources: [], scope: .global,
            reason: "test", isContextTainted: false, expectedEffect: "Write to clipboard",
            isReversible: true, executionIdentity: identityL2
        )
        let identityL3 = QExecutionIdentity(taskId: "t-l3", planId: "p-l3", stepId: "s-l3", actionName: "app.quit")
        let level3Request = QApprovalRequest(
            taskId: "t-l3", toolName: "app.quit", riskLevel: .level3HighRisk,
            literalAction: "Quit Stickies", affectedResources: ["Stickies"], scope: .global,
            reason: "test", isContextTainted: false, expectedEffect: "Quit Stickies",
            isReversible: false, executionIdentity: identityL3
        )

        let level2HUD = PaceTurnHUDState.qApprovalRequest(level2Request)
        let level3HUD = PaceTurnHUDState.qApprovalRequest(level3Request)

        #expect(level2HUD.title != level3HUD.title)
        #expect(level3HUD.title.contains("⚠️"))
        #expect(!level2HUD.title.contains("⚠️"))
        #expect(level2HUD.options == ["Allow", "Deny"])
        #expect(level3HUD.options == ["Allow", "Deny"])
    }

    // MARK: - 3. Full real click-through: Level 2 approval actually executes

    @Test("3. Approving a Level 2 clipboard write through resolveQPermissionApproval actually writes it")
    @MainActor
    func fullClickThroughApprovesLevel2ClipboardWrite() async throws {
        let marker = "q-2f-l2-\(UUID().uuidString)"
        let mockModel = MockAutonomousModelProvider()
        mockModel.structuredPlansToReturn = [
            """
            {
              "taskPrompt": "Write phase 2F marker",
              "steps": [
                {
                  "actionName": "system.clipboard.write",
                  "toolFamily": "system",
                  "description": "Write 2F marker to clipboard",
                  "parameters": {"text": "\(marker)"}
                }
              ]
            }
            """
        ]

        let observer = MockQPlanUIObserver()
        let runtime = QCoreRuntime(
            modelProvider: mockModel,
            memoryProvider: try QSQLiteMemoryStore(inMemory: true),
            executionProvider: QExecutionService.shared,
            durableStore: QDurableTaskStore.shared,
            endpointName: "phase2f-l2-\(UUID().uuidString)"
        )

        let task = try await runtime.submitIntent(prompt: "Write phase 2F marker", observer: observer)
        guard case .awaitingApproval = task.state else {
            Issue.record("Expected task to halt awaiting approval, got: \(task.state)")
            return
        }

        guard let snapshot = observer.recordedSnapshots.last(where: { $0.pendingApproval != nil }) else {
            Issue.record("Expected an observed snapshot with a reconstructable pending approval")
            return
        }

        let manager = CompanionManager()
        manager.activeQPlanSnapshot = snapshot

        await manager.resolveQPermissionApproval(approved: true)

        #expect(NSPasteboard.general.string(forType: .string) == marker)

        let finalTaskState = try QDurableTaskStore.shared.getTask(taskId: task.taskId)
        #expect(finalTaskState?.lifecycleState == .completed)
    }

    // MARK: - 4. Full real click-through: denial via resolveClarification never executes

    @Test("4. Denying through resolveClarification (the real HUD entry point) never writes the clipboard")
    @MainActor
    func fullClickThroughDeniesViaResolveClarification() async throws {
        let marker = "q-2f-denied-\(UUID().uuidString)"
        let mockModel = MockAutonomousModelProvider()
        mockModel.structuredPlansToReturn = [
            """
            {
              "taskPrompt": "Write denied marker",
              "steps": [
                {
                  "actionName": "system.clipboard.write",
                  "toolFamily": "system",
                  "description": "Write denied 2F marker",
                  "parameters": {"text": "\(marker)"}
                }
              ]
            }
            """
        ]

        let observer = MockQPlanUIObserver()
        let runtime = QCoreRuntime(
            modelProvider: mockModel,
            memoryProvider: try QSQLiteMemoryStore(inMemory: true),
            executionProvider: QExecutionService.shared,
            durableStore: QDurableTaskStore.shared,
            endpointName: "phase2f-deny-\(UUID().uuidString)"
        )

        let task = try await runtime.submitIntent(prompt: "Write denied marker", observer: observer)
        guard case .awaitingApproval = task.state else {
            Issue.record("Expected task to halt awaiting approval, got: \(task.state)")
            return
        }
        guard let snapshot = observer.recordedSnapshots.last(where: { $0.pendingApproval != nil }) else {
            Issue.record("Expected an observed snapshot with a reconstructable pending approval")
            return
        }

        let manager = CompanionManager()
        manager.activeQPlanSnapshot = snapshot

        // This is the actual production entry point the clarification-chip Button calls.
        manager.resolveClarification(option: "Deny")

        // Immediate synchronous feedback — no execution wait, since nothing is running.
        #expect(manager.currentTurnHUDState.status == .unsupported)

        // The real denial (durable-state bookkeeping) is dispatched asynchronously; poll briefly
        // for it to settle rather than assuming a fixed delay.
        var finalState: QDurableTaskLifecycleState?
        for _ in 0..<20 {
            finalState = try? QDurableTaskStore.shared.getTask(taskId: task.taskId)?.lifecycleState
            if finalState == .failed { break }
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }

        #expect(finalState == .failed)
        #expect(NSPasteboard.general.string(forType: .string) != marker)
    }

    // MARK: - 5. Full real macOS E2E: Level 3 app.quit approved through the HUD path

    @Test("5. Real macOS E2E — approving a Level 3 app.quit through resolveQPermissionApproval actually terminates it")
    @MainActor
    func fullClickThroughApprovesLevel3AppQuit() async throws {
        let targetApp = "Stickies"

        // Open the target app first via the unaffected Level 1 path (auto-allowed, no approval).
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
            memoryProvider: try QSQLiteMemoryStore(inMemory: true),
            executionProvider: QExecutionService.shared,
            endpointName: "phase2f-e2e-open-\(UUID().uuidString)"
        )
        let openTask = try await openRuntime.submitIntent(prompt: "Open \(targetApp)")
        #expect(openTask.state.isCompleted == true)

        var isRunningBeforeQuit = false
        for _ in 0..<20 {
            isRunningBeforeQuit = NSWorkspace.shared.runningApplications.contains { $0.localizedName == targetApp }
            if isRunningBeforeQuit { break }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        #expect(isRunningBeforeQuit == true)

        // Quit it through the real Level 3 approval-gated capability, resolved via the HUD path.
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
        let observer = MockQPlanUIObserver()
        let quitRuntime = QCoreRuntime(
            modelProvider: mockQuitModel,
            memoryProvider: try QSQLiteMemoryStore(inMemory: true),
            executionProvider: QExecutionService.shared,
            durableStore: QDurableTaskStore.shared,
            endpointName: "phase2f-e2e-quit-\(UUID().uuidString)"
        )
        let quitTask = try await quitRuntime.submitIntent(prompt: "Quit \(targetApp)", observer: observer)
        guard case .awaitingApproval = quitTask.state else {
            Issue.record("Expected quit to halt for explicit approval, got: \(quitTask.state)")
            return
        }
        guard let snapshot = observer.recordedSnapshots.last(where: { $0.pendingApproval?.riskLevel == .level3HighRisk }) else {
            Issue.record("Expected an observed snapshot with a reconstructable Level 3 pending approval")
            return
        }

        let manager = CompanionManager()
        manager.activeQPlanSnapshot = snapshot
        await manager.resolveQPermissionApproval(approved: true)

        let isRunningAfterQuit = NSWorkspace.shared.runningApplications.contains { $0.localizedName == targetApp }
        #expect(isRunningAfterQuit == false)
    }

    // MARK: - 6. Expiry fails closed through the HUD path

    @Test("6. An expired approval fails closed and never executes, even if the user eventually clicks Allow")
    @MainActor
    func expiredApprovalFailsClosedThroughHUD() async throws {
        let marker = "q-2f-expired-\(UUID().uuidString)"
        let taskId = "t-expired-\(UUID().uuidString)"
        let planId = UUID()
        let stepId = UUID()

        let identity = QExecutionIdentity(
            taskId: taskId, planId: planId.uuidString, stepId: stepId.uuidString,
            actionName: "system.clipboard.write"
        )
        // Recorded already-expired (createdAt/expiresAt both in the past).
        let pastDate = Date().addingTimeInterval(-600)
        let expiredRequest = QApprovalRequest(
            taskId: taskId, toolName: "system.clipboard.write", riskLevel: .level2UserApproval,
            literalAction: "Write expired marker", affectedResources: [], scope: .global,
            reason: "test", isContextTainted: false, createdAt: pastDate,
            expiresAt: pastDate.addingTimeInterval(1), // expired 599s ago
            expectedEffect: "Write expired marker", isReversible: true, executionIdentity: identity
        )
        QApprovalCoordinator.shared.recordPending(expiredRequest)

        // Durable task must genuinely be .awaitingApproval for resolveApproval to proceed far
        // enough to consult the (expired) coordinator record.
        let planStep = QDurablePlanStepSnapshot(
            stepId: stepId.uuidString, index: 0, actionName: "system.clipboard.write", toolFamily: "system",
            riskLevel: "level2UserApproval", literalAction: "Write expired marker",
            arguments: ["text": marker], state: "waitingForPermission:test"
        )
        let planSnapshot = QDurablePlanSnapshot(
            planId: planId.uuidString, taskId: taskId, sessionId: "s-expired",
            goal: "Write expired marker", steps: [planStep]
        )
        let taskState = QDurableTaskState(
            taskId: taskId, sessionId: "s-expired", originalIntent: "Write expired marker",
            lifecycleState: .awaitingApproval, currentPlanId: planId.uuidString, currentStepIndex: 0,
            securityBlockReason: "test"
        )
        try QDurableTaskStore.shared.savePlan(planSnapshot)
        try QDurableTaskStore.shared.saveTask(taskState)

        let plan = QPlan(
            id: planId, taskId: taskId, taskPrompt: "Write expired marker",
            state: .waitingForPermission(stepIndex: 0, reason: "test"),
            steps: [
                QPlanStep(
                    id: stepId, index: 0,
                    action: QPlannedAction(actionName: "system.clipboard.write", toolFamily: "system", riskLevel: .level2UserApproval, literalAction: "Write expired marker", arguments: ["text": marker]),
                    description: "Write expired marker",
                    state: .waitingForPermission(reason: "test")
                )
            ]
        )
        let snapshot = QRuntimeUISnapshot.from(plan: plan)
        #expect(snapshot.pendingApproval?.id == expiredRequest.id)

        let manager = CompanionManager()
        manager.activeQPlanSnapshot = snapshot

        await manager.resolveQPermissionApproval(approved: true)

        #expect(NSPasteboard.general.string(forType: .string) != marker)
        let finalState = try QDurableTaskStore.shared.getTask(taskId: taskId)
        #expect(finalState?.lifecycleState == .failed)
        #expect(finalState?.lastKnownError?.localizedCaseInsensitiveContains("expired") == true)
    }

    // MARK: - 7. No pending approval fails closed without crashing

    @Test("7. resolveQPermissionApproval fails closed when there is nothing pending to resolve")
    @MainActor
    func resolveQPermissionApprovalFailsClosedWithNoPendingApproval() async {
        let manager = CompanionManager()
        manager.activeQPlanSnapshot = nil

        await manager.resolveQPermissionApproval(approved: true)

        #expect(manager.currentTurnHUDState.status == .failed)
    }
}
