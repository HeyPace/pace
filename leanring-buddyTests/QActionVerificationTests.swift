//
//  QActionVerificationTests.swift
//  leanring-buddyTests
//
//  Unit tests for Q Closed-Loop Action Verification (Phase 1D.7)
//

import Testing
import Foundation
@testable import Pace

@Suite("QActionVerificationTests")
struct QActionVerificationTests {

    @Test("Verification confirms file creation and content matching")
    func verifyFileCreation() async throws {
        let testPath = "/tmp/q-verify-test-\(UUID().uuidString).txt"
        let content = "Verification Payload Test"
        try content.write(toFile: testPath, atomically: true, encoding: .utf8)

        let verifier = QActionVerifier.shared
        let action = QActionRequest(toolName: "fs.write", toolFamily: "fs", riskLevel: .level1SafeLocalAction, literalAction: "Write file")
        let result = QActionResult(actionId: action.actionId, success: true, summary: "Wrote file")

        // Exact content verification
        let outcome = await verifier.verify(
            action: action,
            result: result,
            strategy: .fileExists(path: testPath, expectedContent: content)
        )
        #expect(outcome.isVerified == true)

        // Non-existent file verification fails
        let missingOutcome = await verifier.verify(
            action: action,
            result: result,
            strategy: .fileExists(path: "/tmp/non-existent-file-\(UUID().uuidString)")
        )
        #expect(missingOutcome.isVerified == false)

        try? FileManager.default.removeItem(atPath: testPath)
    }

    @Test("Verification fails when action execution reported failure (Invariant 7)")
    func verifyRejectsFailedAction() async {
        let verifier = QActionVerifier.shared
        let action = QActionRequest(toolName: "fs.delete", toolFamily: "fs", riskLevel: .level2UserApproval, literalAction: "Delete file")
        let failedResult = QActionResult(actionId: action.actionId, success: false, summary: "Failed to delete", error: "Permission denied")

        let outcome = await verifier.verify(
            action: action,
            result: failedResult,
            strategy: .fileDeleted(path: "/tmp/some-file.txt")
        )

        #expect(outcome.isVerified == false)
        if case .failed(let reason, _) = outcome {
            #expect(reason.contains("Permission denied") || reason.contains("Execution failed"))
        }
    }

    @Test("Verification runs custom empirical check predicate")
    func verifyCustomCheck() async {
        let verifier = QActionVerifier.shared
        let action = QActionRequest(toolName: "calc", toolFamily: "calc", riskLevel: .level0ReadOnly, literalAction: "Compute")
        let result = QActionResult(actionId: action.actionId, success: true, summary: "Computed")

        let outcomePass = await verifier.verify(
            action: action,
            result: result,
            strategy: .customCheck(description: "Math equality", check: { 2 + 2 == 4 })
        )
        #expect(outcomePass.isVerified == true)

        let outcomeFail = await verifier.verify(
            action: action,
            result: result,
            strategy: .customCheck(description: "Math impossibility", check: { 2 + 2 == 5 })
        )
        #expect(outcomeFail.isVerified == false)
    }
}
