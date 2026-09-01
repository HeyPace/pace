//
//  QScreenDerivedAuditRedactionTests.swift
//  leanring-buddyTests
//
//  Q Security Architecture — Screen-Derived Content Audit Boundary Tests (Phase 2G remediation).
//  Proves that screen/perception-derived action results (the data path a future real screen.ocr
//  would populate) cannot reach durable persistence, audit storage, or evidence/goal-evaluation
//  text unredacted, while the on-device-only taint propagation into QTaskContext keeps its full,
//  unredacted content and still forces fresh approval on subsequent Level 2/3 steps. This does NOT
//  implement real screen capture or OCR — QBridgeVision.performOCR remains the Phase 2B/2E stub;
//  these tests simulate a future real OCR result via a mock execution provider so the audit
//  boundary can be proven correct before real recognized text ever exists.
//

import Testing
import Foundation
@testable import Pace

// MARK: - Mock execution provider simulating a future real screen.ocr result

/// Returns a fixed QActionResult regardless of the requested tool — lets tests simulate exactly
/// what a real screen.ocr implementation's QActionResult.summary would look like (raw recognized
/// text interpolated inline, matching QExecutionService.executeScreenOCR's existing summary shape)
/// without implementing any real capture/recognition.
final class MockScreenDerivedExecutionProvider: QExecutionProvider, @unchecked Sendable {
    var summaryToReturn: String = ""

    func executeAction(_ request: QActionRequest, context: QTaskContext) async throws -> QActionResult {
        QActionResult(actionId: request.actionId, success: true, summary: summaryToReturn)
    }
}

@Suite("QScreenDerivedAuditRedactionTests")
struct QScreenDerivedAuditRedactionTests {

    private func ocrStep(index: Int = 0) -> QPlanStep {
        QPlanStep(
            index: index,
            action: QPlannedAction(
                actionName: "screen.ocr",
                toolFamily: "perception",
                riskLevel: .level0ReadOnly,
                literalAction: "Capture and OCR screen"
            ),
            description: "OCR step"
        )
    }

    // MARK: - 1, 4, 10. Screen-derived secret redacted before audit persistence; no bypass via executionSummary

    @Test("1/4/10. A known secret pattern in a screen-derived result never reaches persisted audit output unredacted")
    func screenDerivedSecretRedactedBeforeAuditPersistence() async throws {
        let secret = "sk-abcdefghijklmnopqrstuvwxyz012345"
        let mockExec = MockScreenDerivedExecutionProvider()
        mockExec.summaryToReturn = "Captured screen 1 and recognized: API key found: \(secret)"

        let executor = QPlanExecutor(executionProvider: mockExec)
        let plan = QPlan(taskId: "t-secret-\(UUID().uuidString)", taskPrompt: "Read screen", steps: [ocrStep()])
        let context = QTaskContext(taskId: plan.taskId)

        let executedPlan = try await executor.execute(plan: plan, context: context)

        #expect(executedPlan.isComplete == true)
        // Layer 1 (source redaction in QPlanExecutor): the in-memory result is already sanitized.
        #expect(executedPlan.steps[0].result?.summary.contains(secret) == false)
        #expect(executedPlan.steps[0].result?.summary.contains("[REDACTED_SECRET]") == true)

        // The audit log (executionSummary path) never carries the plaintext secret either.
        let recentRecords = QAuditLogger.shared.getRecentRecords(limit: 200)
        let anyRecordLeaksSecret = recentRecords.contains { record in
            (record.executionSummary ?? "").contains(secret) || (record.error ?? "").contains(secret)
        }
        #expect(anyRecordLeaksSecret == false)
    }

    // MARK: - 5. rawArguments cannot carry the secret

    @Test("5. rawArguments cannot bypass redaction — it is hashed, never stored as plaintext, regardless of screen-derived content")
    func rawArgumentsNeverCarriesPlaintextSecret() {
        let secret = "sk-rawargscheck012345678901234567890"
        let record = QAuditRecord(
            sessionId: "s-rawargs", taskId: "t-rawargs", tool: "screen.ocr",
            riskLevel: .level0ReadOnly,
            rawArguments: "Captured screen 1 and recognized: \(secret)",
            authorizationResult: "allow", provenance: "untrusted"
        )
        // rawArguments is never exposed as a stored property at all — only its SHA-256 hash is.
        #expect(record.argumentsHash.contains(secret) == false)
        #expect(record.argumentsHash.count == 64) // hex-encoded SHA-256 digest, not a copy of the input
        #expect(record.argumentsHash.allSatisfy { $0.isHexDigit })
    }

    // MARK: - 6. Failure/error paths cannot bypass, at the durable persistence boundary

    @Test("6. A secret embedded in a failure/blocked reason is redacted at the durable snapshot boundary regardless of source")
    func failureAndBlockedReasonsRedactedAtDurableBoundary() {
        let secretA = "sk-failpath0123456789012345678901"
        let secretB = "sk-blockedpath01234567890123456789"

        let failedStep = QPlanStep(
            index: 0,
            action: QPlannedAction(actionName: "screen.ocr", toolFamily: "perception", riskLevel: .level0ReadOnly, literalAction: "Capture and OCR screen"),
            description: "OCR step",
            state: .failed(reason: "Verification mismatch, found on screen: \(secretA)")
        )
        let failedSnapshot = QDurablePlanStepSnapshot(from: failedStep)
        #expect(failedSnapshot.state.contains(secretA) == false)
        #expect(failedSnapshot.state.contains("[REDACTED_SECRET]") == true)
        #expect(failedSnapshot.state.hasPrefix("failed:")) // state-prefix parsing used by validate()/recovery stays intact

        let blockedStep = QPlanStep(
            index: 0,
            action: QPlannedAction(actionName: "screen.ocr", toolFamily: "perception", riskLevel: .level0ReadOnly, literalAction: "Capture and OCR screen"),
            description: "OCR step",
            state: .blocked(reason: "Denied, screen showed: \(secretB)")
        )
        let blockedSnapshot = QDurablePlanStepSnapshot(from: blockedStep)
        #expect(blockedSnapshot.state.contains(secretB) == false)
        #expect(blockedSnapshot.state.contains("[REDACTED_SECRET]") == true)
        #expect(blockedSnapshot.state.hasPrefix("blocked:"))
    }

    // MARK: - 3. Sanitization preserves .untrustedScreen provenance / does not weaken taint enforcement

    @Test("3. A screen-derived step's context taint still forces approval on a later Level 2 step, even though its summary was redacted for persistence")
    func sanitizationDoesNotWeakenTaintEnforcement() async throws {
        let secret = "sk-taintcheck0123456789012345678901"
        let mockExec = MockScreenDerivedExecutionProvider()
        mockExec.summaryToReturn = "Captured screen 1 and recognized: \(secret)"
        let executor = QPlanExecutor(executionProvider: mockExec)

        let clipboardStep = QPlanStep(
            index: 1,
            action: QPlannedAction(
                actionName: "system.clipboard.write", toolFamily: "system", riskLevel: .level2UserApproval,
                literalAction: "Write text", arguments: ["text": "hello"]
            ),
            description: "Write clipboard"
        )
        let plan = QPlan(
            taskId: "t-taint-enforce-\(UUID().uuidString)",
            taskPrompt: "Read screen then write clipboard",
            steps: [ocrStep(), clipboardStep]
        )
        let context = QTaskContext(taskId: plan.taskId)

        let executedPlan = try await executor.execute(plan: plan, context: context)

        // The OCR step completed with a SANITIZED summary...
        #expect(executedPlan.steps[0].isComplete == true)
        #expect(executedPlan.steps[0].result?.summary.contains(secret) == false)

        // ...but the tainted context it produced still forces the Level 2 step to require fresh
        // approval regardless of any standing grant — redaction sanitizes what gets PERSISTED, it
        // is never treated as authorization and never "cleans" the taint itself.
        guard case .waitingForPermission = executedPlan.state else {
            Issue.record("Expected the Level 2 step to halt for approval due to tainted context, got: \(executedPlan.state)")
            return
        }
    }

    // MARK: - 7. Durable persistence + recovery round trip contains only sanitized data

    @Test("7. A real save/reload round trip through QDurableTaskStore contains no plaintext secret")
    func durableRecoveryContainsOnlySanitizedData() async throws {
        let secret = "sk-durablecheck01234567890123456789"
        let mockExec = MockScreenDerivedExecutionProvider()
        mockExec.summaryToReturn = "Captured screen 1 and recognized: \(secret)"
        let executor = QPlanExecutor(executionProvider: mockExec)
        let plan = QPlan(taskId: "t-durable-\(UUID().uuidString)", taskPrompt: "Read screen", steps: [ocrStep()])
        let context = QTaskContext(taskId: plan.taskId)

        let executedPlan = try await executor.execute(plan: plan, context: context)
        #expect(executedPlan.isComplete == true)

        // Persist through a REAL (isolated in-memory, but genuinely serialized) durable store —
        // not a mock of the store itself, so this exercises the actual JSON encode/decode path.
        let store = try QDurableTaskStore(inMemory: true)
        let snapshot = QDurablePlanSnapshot(from: executedPlan)
        try store.savePlan(snapshot)

        let reloaded = try store.getPlan(planId: snapshot.planId)
        #expect(reloaded != nil)
        #expect(reloaded?.steps.first?.resultSummary?.contains(secret) == false)
        #expect(reloaded?.steps.first?.resultSummary?.contains("[REDACTED_SECRET]") == true)

        // Reconstructing a live QPlan from the durable snapshot (the crash-recovery path) also
        // carries forward only the already-sanitized text.
        let recoveredPlan = try reloaded!.validate()
        #expect(recoveredPlan.steps.first?.result?.summary.contains(secret) == false)
    }

    // MARK: - 8. Existing non-screen audit behavior is unchanged

    @Test("8. A non-screen-derived step's summary is not altered by the new redaction boundary")
    func nonScreenDerivedSummaryUnchanged() async throws {
        let mockExec = MockScreenDerivedExecutionProvider()
        mockExec.summaryToReturn = "Found 12 running applications: Finder, Safari, Mail"
        let executor = QPlanExecutor(executionProvider: mockExec)
        let step = QPlanStep(
            index: 0,
            action: QPlannedAction(actionName: "system.running_apps", toolFamily: "system", riskLevel: .level0ReadOnly, literalAction: "Query running apps"),
            description: "Query"
        )
        let plan = QPlan(taskId: "t-nonscreen-\(UUID().uuidString)", taskPrompt: "List apps", steps: [step])
        let context = QTaskContext(taskId: plan.taskId)

        let executedPlan = try await executor.execute(plan: plan, context: context)
        #expect(executedPlan.isComplete == true)
        #expect(executedPlan.steps[0].result?.summary == mockExec.summaryToReturn)
    }

    // MARK: - Redaction is idempotent (never double-transforms already-clean or already-redacted text)

    @Test("Redaction backstop at the durable boundary is a no-op on already-sanitized or ordinary text")
    func redactionBackstopIsIdempotent() {
        let ordinaryStep = QPlanStep(
            index: 0,
            action: QPlannedAction(actionName: "system.running_apps", toolFamily: "system", riskLevel: .level0ReadOnly, literalAction: "Query running apps"),
            description: "Query",
            state: .completed,
            result: QPlanStepResult(stepId: UUID(), success: true, summary: "Found 3 running applications: Finder, Safari, Mail", verifiedEvidence: "system.running_apps query completed")
        )
        let snapshot = QDurablePlanStepSnapshot(from: ordinaryStep)
        #expect(snapshot.resultSummary == "Found 3 running applications: Finder, Safari, Mail")
        #expect(snapshot.verifiedEvidence == "system.running_apps query completed")
    }
}
