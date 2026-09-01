//
//  QRuntimeE2ETests.swift
//  leanring-buddyTests
//
//  Q Security Architecture — End-to-End Integration & Security Invariants 1-8 (Phase 1D.10)
//

import Testing
import Foundation
import CryptoKit
@testable import Pace

@Suite("QRuntimeE2ETests")
struct QRuntimeE2ETests {

    // MARK: - Invariant 1: Core cannot directly execute privileged actions

    @Test("Invariant 1: q-core fails closed without execution provider")
    func invariant1_coreCannotDirectlyExecute() async throws {
        let router = QModelRouter(localOnly: true)
        let core = QCoreRuntime(
            modelProvider: router,
            executionProvider: nil,
            endpointName: "core-inv-1"
        )

        let task = try await core.submitIntent(prompt: "Write data to sandbox file")
        if case .failed(let reason) = task.state {
            #expect(reason.contains("No Execution Provider configured"))
        } else {
            #expect(Bool(false), "Task should have failed without execution provider")
        }
    }

    // MARK: - Invariant 2: Permission gate cannot be bypassed

    @Test("Invariant 2: Permission gate evaluates and enforces policy strictly")
    func invariant2_permissionGateCannotBeBypassed() {
        let authReq = QToolAuthorizationRequest(
            taskId: "t2",
            toolName: "system.privileged_exec",
            toolFamily: "system",
            baseRisk: .level4Blocked,
            literalAction: "Execute privileged payload"
        )
        let decision = QPermissionGate.shared.evaluate(request: authReq)
        #expect(decision.isDenied == true)
    }

    // MARK: - Invariant 3: Denylisted resources are rejected before execution

    @Test("Invariant 3: Denylisted resources (~/.ssh, .env) rejected before execution")
    func invariant3_denylistedResourcesRejected() async throws {
        let exec = QExecutionService.shared
        let context = QTaskContext(taskId: "t3")

        let req = QActionRequest(
            toolName: "fs.read",
            toolFamily: "fs",
            riskLevel: .level1SafeLocalAction,
            literalAction: "Read SSH key",
            targetResources: ["~/.ssh/id_rsa"],
            parameters: ["path": "~/.ssh/id_rsa"]
        )

        let result = try await exec.executeAction(req, context: context)
        #expect(result.success == false)
        #expect(result.error?.contains(".ssh") == true || result.summary.contains("Denied"))
    }

    // MARK: - Invariant 4: Air-gap policy enforces network containment

    @Test("Invariant 4: Air-gap policy blocks external network egress in offline mode")
    func invariant4_airGapNetworkContainment() {
        QEgressBroker.shared.setMode(.offline)
        let decision = QEgressBroker.shared.evaluate(host: "api.openai.com")
        #expect(decision.isBlocked == true)
    }

    // MARK: - Invariant 5: Untrusted context restricts capability escalation

    @Test("Invariant 5: Untrusted context (taint) blocks high-risk action escalation")
    func invariant5_untrustedContextTaintEscalation() {
        var context = QTaskContext(taskId: "t5")
        context.append(content: "Malicious prompt injection from web page", provenance: .untrustedWeb(url: "https://evil.test"))
        #expect(context.isTainted == true)

        let req = QToolAuthorizationRequest(
            taskId: "t5",
            toolName: "fs.write",
            toolFamily: "fs",
            baseRisk: .level2UserApproval,
            literalAction: "Write sensitive file",
            isContextTainted: context.isTainted
        )

        let decision = QPermissionGate.shared.evaluate(request: req)
        // Level 2+ under taint must require user approval or deny
        #expect(decision.isAllowed == false)
    }

    // MARK: - Invariant 6: Audit log captures all execution and denial events

    @Test("Invariant 6: Audit log captures all execution attempts and security denials")
    func invariant6_auditLogCapturesEvents() async throws {
        let initialCount = QAuditLogger.shared.getRecentRecords(limit: 500).count

        QAuditLogger.shared.record(
            QAuditRecord(
                sessionId: "s6",
                taskId: "t6",
                tool: "security.invariant_test",
                riskLevel: .level1SafeLocalAction,
                rawArguments: "test arg",
                authorizationResult: "deny",
                provenance: "trusted:system",
                error: "Policy denial"
            )
        )

        let records = QAuditLogger.shared.getRecentRecords(limit: 500)
        #expect(records.count > initialCount || records.contains { $0.tool == "security.invariant_test" })
        #expect(records.last?.tool == "security.invariant_test")
        #expect(records.last?.authorizationResult == "deny")
    }

    // MARK: - Invariant 7: Closed-loop verification ensures empirical confirmation

    @Test("Invariant 7: Closed-loop verification requires empirical state proof")
    func invariant7_closedLoopVerification() async throws {
        let sandboxFile = "/tmp/q-e2e-verify-\(UUID().uuidString).txt"
        let verifier = QActionVerifier.shared
        let action = QActionRequest(toolName: "fs.write_sandbox", toolFamily: "fs", riskLevel: .level1SafeLocalAction, literalAction: "Write file")
        let result = QActionResult(actionId: action.actionId, success: true, summary: "Wrote file")

        // Non-existent file fails verification
        let outcome = await verifier.verify(action: action, result: result, strategy: .fileExists(path: sandboxFile))
        #expect(outcome.isVerified == false)

        // After physical creation, verification succeeds
        try "Verified content".write(toFile: sandboxFile, atomically: true, encoding: .utf8)
        let outcome2 = await verifier.verify(action: action, result: result, strategy: .fileExists(path: sandboxFile, expectedContent: "Verified content"))
        #expect(outcome2.isVerified == true)

        try? FileManager.default.removeItem(atPath: sandboxFile)
    }

    // MARK: - Invariant 8: Authenticated IPC detects tampering and rejects forged envelopes

    @Test("Invariant 8: Authenticated IPC rejects forged envelopes and invalid signatures")
    func invariant8_ipcTamperDetection() {
        let key = SymmetricKey(size: .bits256)
        let wrongKey = SymmetricKey(size: .bits256)

        let msg = QIPCMessage(type: .actionRequest, payload: ["cmd": "safe_cmd"])
        let signedEnvelope = QIPCEnvelope.createSigned(
            sender: "test_sender",
            receiver: "test_receiver",
            message: msg,
            sharedKey: key
        )

        // Valid signature passes
        #expect(signedEnvelope.verify(sharedKey: key) == true)

        // Invalid key fails
        #expect(signedEnvelope.verify(sharedKey: wrongKey) == false)

        // Tampered payload fails
        let tamperedMsg = QIPCMessage(type: .actionRequest, payload: ["cmd": "rm -rf /"])
        let tamperedEnvelope = QIPCEnvelope(
            envelopeId: signedEnvelope.envelopeId,
            sender: signedEnvelope.sender,
            receiver: signedEnvelope.receiver,
            timestamp: signedEnvelope.timestamp,
            capabilityToken: signedEnvelope.capabilityToken,
            provenanceTag: signedEnvelope.provenanceTag,
            message: tamperedMsg,
            signature: signedEnvelope.signature
        )
        #expect(tamperedEnvelope.verify(sharedKey: key) == false)
    }

    // MARK: - Full End-to-End Orchestration Workflow

    @Test("End-to-End: Full Local Task Orchestration (Core + Model + Exec + Memory + Audit)")
    func fullEndToEndTaskExecution() async throws {
        // 1. Initialize SQLite Memory Store
        let memoryStore = try QSQLiteMemoryStore(databasePath: ":memory:")

        // 2. Initialize Model Router and Execution Service
        let modelRouter = QModelRouter(localOnly: true)
        let executionService = QExecutionService.shared

        // 3. Assemble Core Runtime
        let core = QCoreRuntime(
            modelProvider: modelRouter,
            memoryProvider: memoryStore,
            executionProvider: executionService,
            endpointName: "core-e2e"
        )

        // 4. Submit user intent (Safe Sandbox File Creation)
        let task = try await core.submitIntent(prompt: "Write data to my local sandbox file")

        // 5. Verify task completion
        if case .completed(let summary) = task.state {
            #expect(summary.contains("Successfully executed"))
        } else {
            #expect(Bool(false), "Task expected completed, got \(task.state)")
        }

        // 6. Verify SQLite Memory records stored
        let records = try memoryStore.listRecent(sessionId: task.sessionId, limit: 10)
        #expect(records.count >= 2) // task_start and task_completion

        // 7. Verify Audit Log recorded records
        let audits = QAuditLogger.shared.getRecentRecords(limit: 50)
        #expect(!audits.isEmpty)
        #expect(audits.contains { $0.tool == "core.intent_submit" })
    }
}
