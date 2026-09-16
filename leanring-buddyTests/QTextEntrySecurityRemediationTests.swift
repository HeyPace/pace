//
//  QTextEntrySecurityRemediationTests.swift
//  leanring-buddyTests
//
//  Q Security Architecture — Text-Entry Privacy Boundary Tests (Phase 2I remediation).
//  Proves the six gaps the Phase 2I text-entry privacy pre-check confirmed are closed, WITHOUT
//  `ui.set_text_value` existing as a registered/executable capability — `QModelPlanParser
//  .registeredCapabilities` is never touched by this remediation, so these tests construct
//  `QPlannedAction`/`QPlanStep` values with that action name directly (the same pattern
//  QScreenDerivedAuditRedactionTests already uses for `screen.ocr`), bypassing the planner
//  parser entirely. See docs/PHASE_2I_TEXT_ENTRY_SECURITY_REMEDIATION.md.
//

import Testing
import Foundation
@testable import Pace

@Suite("QTextEntrySecurityRemediationTests")
struct QTextEntrySecurityRemediationTests {

    private static let secretValue = "SECRET_TEST_VALUE"

    private func sensitiveStep(index: Int = 0, applicationName: String = "Notes", identifier: String = "bodyField") -> QPlanStep {
        QPlanStep(
            index: index,
            action: QPlannedAction(
                actionName: "ui.set_text_value",
                toolFamily: "ui",
                riskLevel: .level2UserApproval,
                literalAction: "Type \"\(Self.secretValue)\" into the \(applicationName) \(identifier) field",
                targetResources: [applicationName],
                arguments: [
                    "applicationName": applicationName,
                    "role": "AXTextArea",
                    "identifier": identifier,
                    "value": Self.secretValue
                ]
            ),
            description: "Type \"\(Self.secretValue)\" into the \(applicationName) \(identifier) field"
        )
    }

    // MARK: - QSensitiveArgumentPolicy (pure unit tests)

    @Test("QSensitiveArgumentPolicy masks only declared-sensitive keys, preserving non-sensitive keys and length metadata")
    func sensitiveArgumentPolicyMasksOnlyDeclaredKeys() {
        let raw = ["applicationName": "Notes", "identifier": "bodyField", "value": Self.secretValue]
        let redacted = QSensitiveArgumentPolicy.redactedArguments(toolName: "ui.set_text_value", arguments: raw)

        #expect(redacted["applicationName"] == "Notes")
        #expect(redacted["identifier"] == "bodyField")
        #expect(redacted["value"] != Self.secretValue)
        #expect(redacted["value"]?.contains(Self.secretValue) == false)
        #expect(redacted["value"] == "[REDACTED_SENSITIVE_ARGUMENT:length=\(Self.secretValue.count)]")
    }

    @Test("QSensitiveArgumentPolicy is a byte-for-byte no-op for a tool with no declared-sensitive keys")
    func sensitiveArgumentPolicyNoOpForOrdinaryTool() {
        let raw = ["applicationName": "Calculator", "role": "AXButton", "identifier": "Clear"]
        let redacted = QSensitiveArgumentPolicy.redactedArguments(toolName: "ui.click_element", arguments: raw)
        #expect(redacted == raw)
    }

    @Test("approvalSafeLiteralAction builds a safe template for a sensitive tool and never includes the value")
    func approvalSafeLiteralActionBuildsSafeTemplate() {
        let safeText = QSensitiveArgumentPolicy.approvalSafeLiteralAction(
            toolName: "ui.set_text_value",
            arguments: ["applicationName": "Notes", "identifier": "bodyField", "value": Self.secretValue],
            fallbackLiteralAction: "Type \"\(Self.secretValue)\" into Notes"
        )
        #expect(safeText.contains(Self.secretValue) == false)
        #expect(safeText.contains("Notes"))
        #expect(safeText.contains("bodyField"))
    }

    @Test("approvalSafeLiteralAction degrades to a fully generic template when no arguments are available")
    func approvalSafeLiteralActionDegradesWithoutArguments() {
        let safeText = QSensitiveArgumentPolicy.approvalSafeLiteralAction(
            toolName: "ui.set_text_value",
            arguments: [:],
            fallbackLiteralAction: "Type \"\(Self.secretValue)\" into Notes"
        )
        #expect(safeText.contains(Self.secretValue) == false)
    }

    @Test("approvalSafeLiteralAction passes through unchanged for a tool with no declared-sensitive arguments")
    func approvalSafeLiteralActionPassthroughForOrdinaryTool() {
        let fallback = "Click the AllClear button"
        let safeText = QSensitiveArgumentPolicy.approvalSafeLiteralAction(
            toolName: "ui.click_element",
            arguments: ["applicationName": "Calculator", "identifier": "AllClear"],
            fallbackLiteralAction: fallback
        )
        #expect(safeText == fallback)
    }

    // MARK: - 1. Durable plan snapshot masking

    @Test("1. A sensitive 'value' argument is masked (not raw-persisted) at the durable snapshot boundary")
    func sensitiveValueMaskedInDurableSnapshot() {
        let snapshot = QDurablePlanStepSnapshot(from: sensitiveStep())
        #expect(snapshot.arguments["value"]?.contains(Self.secretValue) == false)
        #expect(snapshot.arguments["value"]?.hasPrefix("[REDACTED_SENSITIVE_ARGUMENT:") == true)
        // Non-sensitive targeting metadata is preserved for debugging.
        #expect(snapshot.arguments["applicationName"] == "Notes")
        #expect(snapshot.arguments["identifier"] == "bodyField")
    }

    @Test("1b. A real save/reload round trip through QDurableTaskStore contains only the masked value")
    func durableRoundTripContainsOnlyMaskedValue() throws {
        let step = sensitiveStep(applicationName: "Notes-\(UUID().uuidString)")
        let plan = QPlan(taskId: "t-durable-\(UUID().uuidString)", taskPrompt: "Enter text", steps: [step])
        let snapshot = QDurablePlanSnapshot(from: plan)

        let store = try QDurableTaskStore(inMemory: true)
        try store.savePlan(snapshot)

        let reloaded = try store.getPlan(planId: snapshot.planId)
        #expect(reloaded != nil)
        let reloadedArguments = reloaded?.steps.first?.arguments ?? [:]
        #expect(reloadedArguments["value"]?.contains(Self.secretValue) == false)
        #expect(reloadedArguments["applicationName"] == step.action.arguments["applicationName"])
    }

    // MARK: - 8. Existing (non-sensitive) capability persistence is unchanged

    @Test("8. An existing registered capability's argument persistence is unaffected (ui.click_element)")
    func existingCapabilityArgumentsUnchanged() {
        let step = QPlanStep(
            index: 0,
            action: QPlannedAction(
                actionName: "ui.click_element",
                toolFamily: "ui",
                riskLevel: .level2UserApproval,
                literalAction: "Click the AllClear button",
                arguments: ["applicationName": "Calculator", "role": "AXButton", "identifier": "AllClear"]
            ),
            description: "Click AllClear"
        )
        let snapshot = QDurablePlanStepSnapshot(from: step)
        #expect(snapshot.arguments == step.action.arguments)
    }

    // MARK: - 2. QMemoryStore boundary

    @Test("2. A secret-shaped result cannot reach persisted QMemoryStore content unredacted")
    func secretCannotReachMemoryStoreUnredacted() async throws {
        // QSecretRedactor is pattern-based (it matches secret *shapes* — API keys, PEM blocks,
        // password/token assignments) — it cannot generically identify arbitrary free text, so
        // this test uses a secret-shaped literal, the same convention
        // QScreenDerivedAuditRedactionTests already established for proving this exact boundary.
        //
        // None of QPlanExecutor's built-in QVerificationStrategy cases echo a step's raw
        // QActionResult.summary back into their `.verified(evidence:)` string on a normal
        // (non-resumed) run — `stepEvidence` is only ever that synthetic evidence string, never
        // `result.summary`, for a step that actually executes through `execute()`. The one real,
        // exercised code path where a step's own `verifiedEvidence` string is carried forward
        // verbatim into `completedStepsEvidence`/`finalSummary` is plan RESUME: `execute()`
        // skips already-`.completed` steps and appends their persisted `result.verifiedEvidence`
        // directly (the same "Phase 2D: recovery/resume" branch a crash-recovered plan uses).
        // That is exactly the shape a future capability's already-completed step evidence would
        // take when its plan resumes and completes — so this test simulates it directly rather
        // than requiring `ui.set_text_value` to exist.
        let secret = "sk-memorycheck0123456789012345678901"
        let alreadyCompletedStep = QPlanStep(
            index: 0,
            action: QPlannedAction(actionName: "system.running_apps", toolFamily: "system", riskLevel: .level0ReadOnly, literalAction: "Query running apps"),
            description: "Query",
            state: .completed,
            result: QPlanStepResult(
                stepId: UUID(),
                success: true,
                summary: "Found: \(secret)",
                verifiedEvidence: "Found: \(secret)"
            )
        )
        let executor = QPlanExecutor(executionProvider: QExecutionService.shared)
        let plan = QPlan(taskId: "t-memcheck-\(UUID().uuidString)", taskPrompt: "Query", steps: [alreadyCompletedStep])

        _ = await QRuntimeBootstrap.shared.bootstrap(databasePath: ":memory:", localOnlyModels: true)
        guard let memory = QRuntimeBootstrap.shared.getMemoryStore() else {
            Issue.record("Expected QRuntimeBootstrap to expose a memory store after bootstrap")
            return
        }

        let executedPlan = try await executor.execute(plan: plan, context: QTaskContext(taskId: plan.taskId))
        #expect(executedPlan.isComplete == true)

        let record = try memory.getByKey("plan_\(executedPlan.id.uuidString)", sessionId: executedPlan.sessionId)
        #expect(record != nil)
        #expect(record?.content.contains(secret) == false)
        #expect(record?.content.contains("[REDACTED_SECRET]") == true)
    }

    // MARK: - 3. Audit contains no literal secret across the sensitive-step halt path

    @Test("3. No audit record for a sensitive-argument step's approval halt contains the literal value")
    func auditContainsNoLiteralSecretForSensitiveHalt() async throws {
        let executor = QPlanExecutor(executionProvider: QExecutionService.shared)
        let plan = QPlan(taskId: "t-audit-\(UUID().uuidString)", taskPrompt: "Enter text", steps: [sensitiveStep()])

        let executedPlan = try await executor.execute(plan: plan, context: QTaskContext(taskId: plan.taskId))
        guard case .waitingForPermission = executedPlan.state else {
            Issue.record("Expected the Level 2 step to halt for approval, got: \(executedPlan.state)")
            return
        }

        let recentRecords = QAuditLogger.shared.getRecentRecords(limit: 1000)
        let relevantRecords = recentRecords.filter { $0.taskId == plan.taskId }
        #expect(!relevantRecords.isEmpty)
        let anyRecordLeaksSecret = relevantRecords.contains {
            ($0.executionSummary ?? "").contains(Self.secretValue) || ($0.error ?? "").contains(Self.secretValue)
        }
        #expect(anyRecordLeaksSecret == false)
    }

    // MARK: - 5. Approval construction contains no literal text

    @Test("5a. A live approval halt via QCoreRuntime.submitIntent exposes no literal in expectedEffect")
    func coreRuntimeApprovalHaltHidesLiteral() async throws {
        let mockModel = MockAutonomousModelProvider()
        let taskId = "t-coreruntime-\(UUID().uuidString)"
        mockModel.plansToReturn = [
            QPlan(taskId: taskId, taskPrompt: "Enter text into Notes", steps: [sensitiveStep()])
        ]
        let memory = try QSQLiteMemoryStore(inMemory: true)
        let runtime = QCoreRuntime(
            modelProvider: mockModel,
            memoryProvider: memory,
            executionProvider: QExecutionService.shared,
            endpointName: "text-entry-remediation-\(UUID().uuidString)"
        )

        let task = try await runtime.submitIntent(prompt: "Enter text into Notes")
        guard case .awaitingApproval(let req) = task.state else {
            Issue.record("Expected task to halt awaiting approval, got: \(task.state)")
            return
        }
        #expect(req.expectedEffect.contains(Self.secretValue) == false)
        #expect(req.literalAction.contains(Self.secretValue) == false)
        #expect(req.expectedEffect.contains("Notes"))
    }

    @Test("5b. QRuntimeUISnapshot.pendingApproval reconstruction exposes no literal in expectedEffect")
    func runtimeUISnapshotPendingApprovalHidesLiteral() async throws {
        let executor = QPlanExecutor(executionProvider: QExecutionService.shared)
        let plan = QPlan(taskId: "t-snapshot-\(UUID().uuidString)", taskPrompt: "Enter text", steps: [sensitiveStep()])

        let executedPlan = try await executor.execute(plan: plan, context: QTaskContext(taskId: plan.taskId))
        guard case .waitingForPermission = executedPlan.state else {
            Issue.record("Expected the Level 2 step to halt for approval, got: \(executedPlan.state)")
            return
        }

        let snapshot = QRuntimeUISnapshot.from(plan: executedPlan)
        guard let pending = snapshot.pendingApproval else {
            Issue.record("Expected a reconstructable pending approval")
            return
        }
        #expect(pending.expectedEffect.contains(Self.secretValue) == false)
        #expect(pending.literalAction.contains(Self.secretValue) == false)
    }

    // MARK: - 6. AXSecureTextField / AXStaticText / unknown role rejection

    @Test("6. Text-entry role policy allows only AXTextField/AXTextArea and rejects everything else")
    func textEntryRolePolicyAllowlist() {
        #expect(QAXTextEntryRolePolicy.isAllowedTextEntryRole("AXTextField") == true)
        #expect(QAXTextEntryRolePolicy.isAllowedTextEntryRole("AXTextArea") == true)
        #expect(QAXTextEntryRolePolicy.isAllowedTextEntryRole("AXSecureTextField") == false)
        #expect(QAXTextEntryRolePolicy.isAllowedTextEntryRole("AXStaticText") == false)
        #expect(QAXTextEntryRolePolicy.isAllowedTextEntryRole("AXCustomWidgetRole42") == false)
        #expect(QAXTextEntryRolePolicy.isAllowedTextEntryRole("") == false)
    }

    @Test("6b. QAXInteractionError has a fail-closed case for a disallowed target role")
    func disallowedTargetRoleErrorCode() {
        let error = QAXInteractionError.disallowedTargetRole("AXSecureTextField")
        #expect(error.errorCode == "AX_TARGET_ROLE_NOT_ALLOWED")
        #expect(error.description.contains("AXSecureTextField"))
    }

    // MARK: - 3 (contract). Verification evidence type cannot represent the literal value

    @Test("QSafeTextEntryVerificationEvidence's safe conversions never contain literal content — only the five declared fields")
    func safeTextEntryVerificationEvidenceHasNoLiteralField() {
        let evidence = QSafeTextEntryVerificationEvidence(
            valueChanged: true,
            previousLength: 0,
            currentLength: Self.secretValue.count,
            targetIdentity: "role=AXTextArea identifier=bodyField",
            verificationStatus: .verified
        )
        let outputData = evidence.toActionResultOutputData()
        #expect(Set(outputData.keys) == ["valueChanged", "previousLength", "currentLength", "targetIdentity", "verificationStatus"])
        #expect(outputData["valueChanged"] == "true")
        #expect(outputData["previousLength"] == "0")
        #expect(outputData["currentLength"] == "\(Self.secretValue.count)")
        #expect(outputData.values.contains { $0.contains(Self.secretValue) } == false)
        #expect(evidence.safeEvidenceDescription.contains(Self.secretValue) == false)
    }

    // MARK: - 6 (contract). Recovery equality result carries only a boolean

    @Test("QTextEntryRecoveryEqualityResult carries only the boolean comparison outcome")
    func recoveryEqualityResultIsBooleanOnly() {
        let matched = QTextEntryRecoveryEqualityResult(alreadyMatchesIntendedValue: true)
        let mismatched = QTextEntryRecoveryEqualityResult(alreadyMatchesIntendedValue: false)
        #expect(matched.alreadyMatchesIntendedValue == true)
        #expect(mismatched.alreadyMatchesIntendedValue == false)
        #expect(matched != mismatched)
    }
}
