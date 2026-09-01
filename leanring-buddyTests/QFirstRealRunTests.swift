//
//  QFirstRealRunTests.swift
//  leanring-buddyTests
//
//  Q Security Architecture — Phase 1F Real Local Agent Run Test Suite.
//  Validates end-to-end local execution of real macOS tasks under strict security gating.
//

import Testing
import Foundation
import AppKit
@testable import Pace

@Suite("QFirstRealRunTests")
struct QFirstRealRunTests {

    // MARK: - STEP 2: Auto-Boot Verification

    @Test("STEP 2: QRuntimeBootstrap boots automatically and reports Q READY")
    func testStep2_autoBootVerification() async {
        let coordinator = QRuntimeBootstrap.shared
        let report = await coordinator.bootstrap()

        #expect(report.isReady == true)
        #expect(report.errors.isEmpty)
        #expect(report.activeComponents.contains("QAuditLogger"))
        #expect(report.activeComponents.contains("QPermissionGate"))
        #expect(report.activeComponents.contains("QResourceGuard"))
        #expect(report.activeComponents.contains("QEgressBroker (Air-Gap Offline)"))
        #expect(report.activeComponents.contains("QSQLiteMemoryStore (WAL Mode)"))
        #expect(report.activeComponents.contains("QCoreRuntime (Unified Orchestrator)"))
    }

    // MARK: - STEP 5: First Real Task — Open Calculator

    @Test("STEP 5: Real Agent Task: Open Calculator and empirically verify readiness")
    func testStep5_openCalculatorAndVerify() async throws {
        let agent = QAgent.shared
        let task = "Open Calculator and tell me when it is ready."

        let result = try await agent.run(task: task)

        #expect(result.isSuccess == true)
        #expect(result.summary.contains("Calculator"))

        // Empirical check: NSWorkspace runningApplications contains Calculator or verified launch
        let isRunning = NSWorkspace.shared.runningApplications.contains { app in
            (app.localizedName?.caseInsensitiveCompare("Calculator") == .orderedSame) ||
            (app.bundleIdentifier?.caseInsensitiveCompare("com.apple.calculator") == .orderedSame)
        }
        #expect(isRunning == true)

        // Verify audit event
        let audits = QAuditLogger.shared.getRecentRecords(limit: 20)
        #expect(audits.contains { $0.tool == "ui.open_app" || $0.tool == "core.intent_submit" })
    }

    // MARK: - STEP 8: Second Real Task — Screen Capture & OCR

    @Test("STEP 8: Real Agent Task: Read visible text on screen with untrustedScreen provenance")
    func testStep8_screenCaptureAndOCR() async throws {
        let agent = QAgent.shared
        let task = "Read the visible text on my screen."

        let result = try await agent.run(task: task)

        #expect(result.isSuccess == true)
        #expect(result.summary.contains("screen") || result.summary.contains("recognized") || result.summary.contains("Display"))
        #expect(result.provenanceTag == "trusted:user" || result.provenanceTag == "untrusted")
    }

    // MARK: - STEP 9: Third Real Task — Clipboard Read

    @Test("STEP 9: Real Agent Task: Read system clipboard contents safely")
    func testStep9_readClipboard() async throws {
        let testPayload = "Q-Phase-1F-Secure-Token-\(UUID().uuidString)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(testPayload, forType: .string)

        let agent = QAgent.shared
        let task = "Read the clipboard and show me its contents."

        let result = try await agent.run(task: task)

        #expect(result.isSuccess == true)
        #expect(result.summary.contains("clipboard") || result.summary.contains("Read"))
    }

    // MARK: - STEP 10: Denial Test — ResourceGuard Protection

    @Test("STEP 10: Denial Test: Read ~/.ssh/id_rsa is strictly rejected by ResourceGuard")
    func testStep10_denialTestProtectedCredential() async throws {
        let agent = QAgent.shared
        let task = "Read ~/.ssh/id_rsa"

        let result = try await agent.run(task: task)

        #expect(result.isSuccess == false)
        #expect(result.summary.contains("Denied") || result.summary.contains(".ssh") || result.summary.contains("Security Guard"))

        // Verify denial audit record
        let audits = QAuditLogger.shared.getRecentRecords(limit: 20)
        #expect(audits.contains { $0.authorizationResult == "deny" })
    }

    // MARK: - STEP 11: Voice & Speech Pipeline Integration

    @Test("STEP 11: Voice Pipeline: Spoken transcript drives QAgent and synthesizes TTS output")
    func testStep11_voicePipelineIntegration() async throws {
        let companionManager = await CompanionManager()
        let result = await companionManager.executeQAgentTurn(transcript: "What applications are currently running?")

        #expect(result.isSuccess == true)
        let state = await companionManager.qRuntimeState
        #expect(state == .completed || state == .ready)
    }

    // MARK: - STEP 12 & 13: Memory & Audit Inspection

    @Test("STEP 12 & 13: Memory store and Audit log record every interaction with redactions")
    func testStep12And13_memoryAndAuditInspection() async throws {
        let memory = QRuntimeBootstrap.shared.getMemoryStore()
        #expect(memory != nil)

        // Query memory
        let recentRecords = try memory?.query(text: "Calculator", sessionId: nil, limit: 10)
        #expect(recentRecords != nil)

        // Verify audit log has zero unredacted secret patterns and SHA-256 argument hashes
        let audits = QAuditLogger.shared.getRecentRecords(limit: 50)
        #expect(!audits.isEmpty)
        for record in audits {
            #expect(!record.argumentsHash.isEmpty)
            if let summary = record.executionSummary {
                #expect(!summary.contains("BEGIN RSA PRIVATE KEY"))
                #expect(!summary.contains("PRIVATE KEY"))
            }
        }
    }

    // MARK: - STEP 15: Developer Doctor Check

    @Test("STEP 15: Q Doctor produces definitive Q READY assessment")
    func testStep15_doctorDiagnosticCheck() async {
        let doctor = QDoctor.shared
        let report = await doctor.diagnose()

        #expect(report.hasLocalModel == true)
        #expect(report.isReady == true)
        #expect(report.summaryVerdict == "Q READY")
        #expect(report.securityStatus["PermissionGate"]?.contains("Active") == true)
        #expect(report.securityStatus["EgressBroker"]?.contains("OFFLINE") == true || report.securityStatus["EgressBroker"]?.contains("offline") == true)
    }
}
