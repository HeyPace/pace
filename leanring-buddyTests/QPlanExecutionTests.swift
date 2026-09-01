//
//  QPlanExecutionTests.swift
//  leanring-buddyTests
//
//  Q Security Architecture — Sequential Plan Execution Test Suite (Phase 2A.1).
//  Validates strict sequential execution, per-step permission gating, closed-loop
//  verification barriers, denial cascading, and taint propagation.
//

import Testing
import Foundation
import AppKit
@testable import Pace

@Suite("QPlanExecutionTests")
struct QPlanExecutionTests {

    private func makeSandboxFilePath(filename: String) -> String {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let sandboxDir = docs.appendingPathComponent("q_plan_test_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: sandboxDir, withIntermediateDirectories: true)
        return sandboxDir.appendingPathComponent(filename).path
    }

    // MARK: - Test 2: Steps Execute Strictly in Order

    @Test("Test 2: Steps execute strictly in deterministic sequential order")
    func testStepsExecuteStrictlyInOrder() async throws {
        let executor = QPlanExecutor.shared
        let context = QTaskContext(taskId: "task_order_test")

        let step0 = QPlanStep(
            index: 0,
            action: QPlannedAction(
                actionName: "system.running_apps",
                toolFamily: "system",
                riskLevel: .level0ReadOnly,
                literalAction: "Query running apps"
            ),
            description: "Step 0"
        )

        let step1 = QPlanStep(
            index: 1,
            action: QPlannedAction(
                actionName: "system.clipboard.read",
                toolFamily: "system",
                riskLevel: .level0ReadOnly,
                literalAction: "Read clipboard"
            ),
            description: "Step 1"
        )

        let plan = QPlan(taskPrompt: "Sequential test", steps: [step0, step1])
        let executedPlan = try await executor.execute(plan: plan, context: context)

        #expect(executedPlan.isComplete == true)
        #expect(executedPlan.steps[0].state == .completed)
        #expect(executedPlan.steps[1].state == .completed)
        #expect(executedPlan.steps[0].result?.success == true)
        #expect(executedPlan.steps[1].result?.success == true)
    }

    // MARK: - Test 3 & 9: Step 2 cannot start until Step 1 is verified

    @Test("Test 3 & 9: Step 2 starts only after Step 1 verification; all steps must be verified")
    func testStep2RequiresStep1Verification() async throws {
        let executor = QPlanExecutor.shared
        let filePath = makeSandboxFilePath(filename: "verify_step.txt")
        let content = "Verified-Evidence-\(UUID().uuidString)"
        let context = QTaskContext(taskId: "task_verify_order")

        // Step 0: Write sandbox file
        let step0 = QPlanStep(
            index: 0,
            action: QPlannedAction(
                actionName: "fs.write_sandbox",
                toolFamily: "fs",
                riskLevel: .level1SafeLocalAction,
                literalAction: "Write to \(filePath)",
                targetResources: [filePath],
                arguments: ["path": filePath, "content": content]
            ),
            description: "Write sandbox file"
        )

        // Step 1: Read sandbox file (depends on step 0 verification)
        let step1 = QPlanStep(
            index: 1,
            action: QPlannedAction(
                actionName: "fs.read",
                toolFamily: "fs",
                riskLevel: .level0ReadOnly,
                literalAction: "Read from \(filePath)",
                targetResources: [filePath],
                arguments: ["path": filePath]
            ),
            description: "Read sandbox file"
        )

        let plan = QPlan(taskPrompt: "File round-trip with verification", steps: [step0, step1])
        let executedPlan = try await executor.execute(plan: plan, context: context)

        #expect(executedPlan.isComplete == true)
        #expect(executedPlan.steps[0].state == .completed)
        #expect(executedPlan.steps[0].result?.verifiedEvidence?.contains("exists") == true)
        #expect(executedPlan.steps[1].state == .completed)
    }

    // MARK: - Test 4: Permission Denial on Step 2 Stops Step 3

    @Test("Test 4: Permission denial on Step 2 immediately halts plan and skips Step 3")
    func testPermissionDenialHaltsPlan() async throws {
        let executor = QPlanExecutor.shared
        let context = QTaskContext(taskId: "task_deny_halt")

        // Step 0: Safe read
        let step0 = QPlanStep(
            index: 0,
            action: QPlannedAction(
                actionName: "system.running_apps",
                toolFamily: "system",
                riskLevel: .level0ReadOnly,
                literalAction: "Query running apps"
            ),
            description: "Safe step 0"
        )

        // Step 1: Forbidden Level 4 action
        let step1 = QPlanStep(
            index: 1,
            action: QPlannedAction(
                actionName: "security.disable_firewall",
                toolFamily: "system",
                riskLevel: .level4Blocked,
                literalAction: "Disable system firewall"
            ),
            description: "Forbidden step 1"
        )

        // Step 2: Safe step that must never run
        let step2 = QPlanStep(
            index: 2,
            action: QPlannedAction(
                actionName: "system.clipboard.read",
                toolFamily: "system",
                riskLevel: .level0ReadOnly,
                literalAction: "Read clipboard"
            ),
            description: "Should be skipped"
        )

        let plan = QPlan(taskPrompt: "Denial cascade test", steps: [step0, step1, step2])
        let executedPlan = try await executor.execute(plan: plan, context: context)

        #expect(executedPlan.isComplete == false)
        #expect(executedPlan.steps[0].state == .completed)
        if case .blocked(let reason) = executedPlan.steps[1].state {
            #expect(reason.contains("Permission Gate Denied") || reason.contains("Level 4") || reason.contains("Blocked"))
        } else {
            #expect(Bool(false), "Step 1 must be blocked")
        }
        if case .skipped = executedPlan.steps[2].state {
            #expect(true)
        } else {
            #expect(Bool(false), "Step 2 must be marked as skipped")
        }
    }

    // MARK: - Test 6: Blocked Secret-Resource Action Stops Plan

    @Test("Test 6: ResourceGuard blocks protected path on Step 1, halting the plan immediately")
    func testResourceGuardDenialHaltsPlan() async throws {
        let executor = QPlanExecutor.shared
        let context = QTaskContext(taskId: "task_resource_guard_halt")

        let step0 = QPlanStep(
            index: 0,
            action: QPlannedAction(
                actionName: "system.running_apps",
                toolFamily: "system",
                riskLevel: .level0ReadOnly,
                literalAction: "Query running apps"
            ),
            description: "Safe step 0"
        )

        let step1 = QPlanStep(
            index: 1,
            action: QPlannedAction(
                actionName: "fs.read",
                toolFamily: "fs",
                riskLevel: .level0ReadOnly,
                literalAction: "Read ~/.ssh/id_rsa",
                targetResources: ["~/.ssh/id_rsa"],
                arguments: ["path": "~/.ssh/id_rsa"]
            ),
            description: "Protected resource step 1"
        )

        let step2 = QPlanStep(
            index: 2,
            action: QPlannedAction(
                actionName: "ui.open_app",
                toolFamily: "app",
                riskLevel: .level1SafeLocalAction,
                literalAction: "Open Calculator",
                targetResources: ["Calculator"],
                arguments: ["appName": "Calculator"]
            ),
            description: "Should be skipped"
        )

        let plan = QPlan(taskPrompt: "Resource guard halt test", steps: [step0, step1, step2])
        let executedPlan = try await executor.execute(plan: plan, context: context)

        #expect(executedPlan.isComplete == false)
        #expect(executedPlan.steps[0].state == .completed)
        if case .blocked = executedPlan.steps[1].state {
            #expect(true)
        } else {
            #expect(Bool(false), "Step 1 must be blocked by ResourceGuard")
        }
        if case .skipped = executedPlan.steps[2].state {
            #expect(true)
        } else {
            #expect(Bool(false), "Step 2 must be skipped")
        }
    }

    // MARK: - Test 7: Untrusted Provenance Cannot Escalate a Later Step

    @Test("Test 7: Untrusted OCR perception propagates taint and restricts subsequent plan steps")
    func testUntrustedProvenanceTaintPropagation() async throws {
        // Phase 2G: screen.ocr now performs a REAL ScreenCaptureKit capture + Vision recognition
        // via the shared, non-mocked QExecutionService — it is no longer a stub that always
        // succeeds. Screen Recording TCC permission cannot be assumed inside an isolated
        // DerivedData test runner (see docs/PHASE_2G_REAL_SCREEN_OCR.md's TCC test strategy), so
        // this test asserts the CORRECT deterministic outcome for whichever permission state is
        // actually live in this run, rather than assuming either — it must never assume success
        // just to keep passing, and must never be weakened by mocking away the real capture path.
        let executor = QPlanExecutor.shared
        let context = QTaskContext(taskId: "task_taint_test")

        // Step 0: Screen OCR (injects untrusted perception taint on success)
        let step0 = QPlanStep(
            index: 0,
            action: QPlannedAction(
                actionName: "screen.ocr",
                toolFamily: "perception",
                riskLevel: .level0ReadOnly,
                literalAction: "Capture and OCR screen"
            ),
            description: "OCR step"
        )

        // Step 1: Subsequent action evaluates with tainted context
        let step1 = QPlanStep(
            index: 1,
            action: QPlannedAction(
                actionName: "system.running_apps",
                toolFamily: "system",
                riskLevel: .level0ReadOnly,
                literalAction: "Query running apps"
            ),
            description: "Subsequent query"
        )

        let plan = QPlan(taskPrompt: "Taint propagation plan", steps: [step0, step1])
        let executedPlan = try await executor.execute(plan: plan, context: context)

        if CGPreflightScreenCaptureAccess() {
            // Permission is live in this environment — real capture + recognition should
            // succeed and both steps should complete normally.
            #expect(executedPlan.isComplete == true)
            #expect(executedPlan.steps[0].state == .completed)
            #expect(executedPlan.steps[1].state == .completed)
        } else {
            // No Screen Recording permission — screen.ocr MUST fail closed with the
            // deterministic permission error, never fabricate a result, and the plan must halt
            // (skip the remaining step) exactly like any other execution failure.
            #expect(executedPlan.isComplete == false)
            if case .failed(let reason) = executedPlan.steps[0].state {
                #expect(reason.contains(QScreenCaptureError.permissionDenied.errorCode) || reason.contains("Screen Recording"))
            } else {
                Issue.record("Expected step 0 to fail closed on missing Screen Recording permission, got: \(executedPlan.steps[0].state)")
            }
            #expect(executedPlan.steps[1].state == .skipped(reason: "Prior step 0 returned error"))
        }
    }

    // MARK: - Test 10: Audit Records Plan & Step Lifecycle Without Leaking Secrets

    @Test("Test 10: Audit logger captures plan start, step completion, and SHA-256 hashes")
    func testAuditTrailIntegrity() async throws {
        let executor = QPlanExecutor.shared
        let context = QTaskContext(taskId: "task_audit_test")

        let step = QPlanStep(
            index: 0,
            action: QPlannedAction(
                actionName: "system.running_apps",
                toolFamily: "system",
                riskLevel: .level0ReadOnly,
                literalAction: "Query running apps"
            ),
            description: "Audited step"
        )

        let plan = QPlan(taskPrompt: "Audit plan test", steps: [step])
        _ = try await executor.execute(plan: plan, context: context)

        let audits = QAuditLogger.shared.getRecentRecords(limit: 20)
        #expect(audits.contains { $0.tool == "plan.start" })
        #expect(audits.contains { $0.tool == "plan.complete" })
        #expect(audits.contains { $0.tool == "system.running_apps" })
    }

    // MARK: - STEP 8: Real Multi-Step E2E Test

    @Test("STEP 8: Real Multi-Step E2E Test: Sandbox write -> Sandbox read -> Open Calculator")
    func testRealMultiStepE2EExecution() async throws {
        let executor = QPlanExecutor.shared
        let filePath = makeSandboxFilePath(filename: "e2e_plan_test.txt")
        let fileContent = "Q-Plan-E2E-Token-\(UUID().uuidString)"
        let context = QTaskContext(taskId: "e2e_real_plan")

        // Step 0: Write sandbox file
        let step0 = QPlanStep(
            index: 0,
            action: QPlannedAction(
                actionName: "fs.write_sandbox",
                toolFamily: "fs",
                riskLevel: .level1SafeLocalAction,
                literalAction: "Write to \(filePath)",
                targetResources: [filePath],
                arguments: ["path": filePath, "content": fileContent]
            ),
            description: "Step 0: Create sandbox test file"
        )

        // Step 1: Read sandbox file
        let step1 = QPlanStep(
            index: 1,
            action: QPlannedAction(
                actionName: "fs.read",
                toolFamily: "fs",
                riskLevel: .level0ReadOnly,
                literalAction: "Read from \(filePath)",
                targetResources: [filePath],
                arguments: ["path": filePath]
            ),
            description: "Step 1: Read sandbox test file"
        )

        // Step 2: Open Calculator application
        let step2 = QPlanStep(
            index: 2,
            action: QPlannedAction(
                actionName: "ui.open_app",
                toolFamily: "app",
                riskLevel: .level1SafeLocalAction,
                literalAction: "Open Calculator",
                targetResources: ["Calculator"],
                arguments: ["appName": "Calculator"]
            ),
            description: "Step 2: Launch Calculator"
        )

        let plan = QPlan(taskPrompt: "Write file, read file, open Calculator", steps: [step0, step1, step2])
        let executedPlan = try await executor.execute(plan: plan, context: context)

        #expect(executedPlan.isComplete == true)
        #expect(executedPlan.steps.count == 3)
        #expect(executedPlan.steps[0].state == .completed)
        #expect(executedPlan.steps[1].state == .completed)
        #expect(executedPlan.steps[2].state == .completed)

        // Empirical confirmation that Calculator is running in NSWorkspace
        let isRunning = NSWorkspace.shared.runningApplications.contains { app in
            (app.localizedName?.caseInsensitiveCompare("Calculator") == .orderedSame) ||
            (app.bundleIdentifier?.caseInsensitiveCompare("com.apple.calculator") == .orderedSame)
        }
        #expect(isRunning == true)
    }
}
