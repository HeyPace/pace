//
//  QPermissionGateTests.swift
//  leanring-buddyTests
//
//  Unit tests for QPermissionGate (Phase 1c.3)
//

import Testing
import Foundation
import CryptoKit
@testable import Pace

@Suite("QPermissionGateTests")
struct QPermissionGateTests {

    @Test("Level 4 capabilities are universally denied and cannot be bypassed")
    func level4Prohibited() {
        let gate = QPermissionGate()
        let req = QToolAuthorizationRequest(
            taskId: "task-001",
            toolName: "sys.extract_keychain",
            toolFamily: "sys",
            baseRisk: .level4Blocked,
            literalAction: "Extract password"
        )

        let decision = gate.evaluate(request: req)
        #expect(decision.isDenied)
        if case .deny(let reason, let violation) = decision {
            #expect(violation == .level4BlockedCapability)
            #expect(reason.contains("Level 4"))
        }
    }

    @Test("Level 0 and Level 1 actions are permitted under default policy")
    func level0And1PermittedByDefault() {
        let gate = QPermissionGate()
        let readReq = QToolAuthorizationRequest(
            taskId: "task-002",
            toolName: "screen.capture",
            toolFamily: "screen",
            baseRisk: .level0ReadOnly,
            literalAction: "Capture screen frame"
        )
        let decision0 = gate.evaluate(request: readReq)
        #expect(decision0.isAllowed)

        let launchReq = QToolAuthorizationRequest(
            taskId: "task-003",
            toolName: "app.launch",
            toolFamily: "app",
            baseRisk: .level1SafeLocalAction,
            literalAction: "Launch Safari"
        )
        let decision1 = gate.evaluate(request: launchReq)
        #expect(decision1.isAllowed)
    }

    @Test("Level 2 and 3 actions without standing grants require approval")
    func level2And3RequireApprovalByDefault() {
        let gate = QPermissionGate()
        let writeReq = QToolAuthorizationRequest(
            taskId: "task-004",
            toolName: "fs.write",
            toolFamily: "fs",
            baseRisk: .level2UserApproval,
            targetScope: .filesystem(pathPrefix: "/Users/hani/Developer/project"),
            literalAction: "Modify main.swift",
            affectedResources: ["/Users/hani/Developer/project/main.swift"]
        )

        let decision = gate.evaluate(request: writeReq)
        #expect(decision.requiresApproval)
        if case .requireApproval(let approval) = decision {
            #expect(approval.riskLevel == .level2UserApproval)
            #expect(approval.literalAction == "Modify main.swift")
            #expect(!approval.signature.isEmpty)
        }
    }

    @Test("Standing grants allow Level 2 actions when context is untainted")
    func standingGrantAllowsUntaintedLevel2() {
        let gate = QPermissionGate()
        let grant = QCapability(
            toolFamily: "fs",
            toolName: "write",
            scope: .filesystem(pathPrefix: "/Users/hani/Developer/project"),
            maxRiskLevel: .level2UserApproval,
            grantedBy: .userInteractive,
            provenanceCeiling: .trustedOnly
        )
        gate.addGrant(grant)

        let writeReq = QToolAuthorizationRequest(
            taskId: "task-005",
            toolName: "fs.write",
            toolFamily: "fs",
            baseRisk: .level2UserApproval,
            targetScope: .filesystem(pathPrefix: "/Users/hani/Developer/project"),
            literalAction: "Modify code",
            isContextTainted: false
        )

        let decision = gate.evaluate(request: writeReq)
        #expect(decision.isAllowed)
    }

    @Test("Tainted context forces approval even when a standing grant exists")
    func taintedContextForcesApprovalOnStandingGrant() {
        let gate = QPermissionGate()
        let grant = QCapability(
            toolFamily: "fs",
            toolName: "write",
            scope: .filesystem(pathPrefix: "/Users/hani/Developer/project"),
            maxRiskLevel: .level2UserApproval,
            grantedBy: .userInteractive,
            provenanceCeiling: .trustedOnly
        )
        gate.addGrant(grant)

        let writeReq = QToolAuthorizationRequest(
            taskId: "task-006",
            toolName: "fs.write",
            toolFamily: "fs",
            baseRisk: .level2UserApproval,
            targetScope: .filesystem(pathPrefix: "/Users/hani/Developer/project"),
            literalAction: "Modify code from web instruction",
            isContextTainted: true // Untrusted web OCR in context!
        )

        let decision = gate.evaluate(request: writeReq)
        #expect(decision.requiresApproval)
        if case .requireApproval(let approval) = decision {
            #expect(approval.isContextTainted)
            #expect(approval.reason.contains("untrusted content"))
        }
    }
}

// MARK: - QApprovalRequest.verifySignature (H-1 regression)

/// Regression coverage for a fixed logic bug: `verifySignature()` used to be
/// `HMAC.isValidAuthenticationCode(...) || !signature.isEmpty`, which meant
/// ANY non-empty signature string — valid or not — passed verification. The
/// fix makes the HMAC result the entire verdict. These tests exist because
/// the bug previously shipped with zero coverage anywhere in the suite.
@Suite("QApprovalRequestSignatureTests")
struct QApprovalRequestSignatureTests {

    private func makeRequest(signingKey: SymmetricKey = QPermissionGate.defaultSigningKey) -> QApprovalRequest {
        QApprovalRequest(
            taskId: "task-sig-001",
            toolName: "ui.click_element",
            riskLevel: .level2UserApproval,
            literalAction: "Click Submit",
            affectedResources: ["Submit"],
            scope: .global,
            reason: "Test",
            isContextTainted: false,
            signingKey: signingKey
        )
    }

    @Test("A genuinely-signed request verifies as true (allow path)")
    func genuineSignatureVerifies() {
        let key = SymmetricKey(size: .bits256)
        let request = makeRequest(signingKey: key)
        #expect(request.verifySignature(using: key) == true)
    }

    @Test("A forged non-empty signature is rejected, not accepted (deny path)")
    func forgedNonEmptySignatureIsRejected() {
        let key = SymmetricKey(size: .bits256)
        let request = makeRequest(signingKey: key)
        // Simulate a tampered/forged approval carrying an arbitrary non-empty
        // signature string. Before the H-1 fix, `|| !signature.isEmpty` made
        // this verify as true regardless of the HMAC.
        let forged = QApprovalRequest(forgedForTestingWithSignature: "forged-but-not-empty", basedOn: request)
        #expect(forged.verifySignature(using: key) == false)
    }

    @Test("An empty signature is rejected")
    func emptySignatureIsRejected() {
        let key = SymmetricKey(size: .bits256)
        let request = makeRequest(signingKey: key)
        let empty = QApprovalRequest(forgedForTestingWithSignature: "", basedOn: request)
        #expect(empty.verifySignature(using: key) == false)
    }

    @Test("Verifying with the wrong signing key is rejected")
    func wrongSigningKeyIsRejected() {
        let signingKey = SymmetricKey(size: .bits256)
        let request = makeRequest(signingKey: signingKey)
        let wrongKey = SymmetricKey(size: .bits256)
        #expect(request.verifySignature(using: wrongKey) == false)
    }

    @Test("A tampered payload with the original hex signature fails verification")
    func tamperedPayloadFailsVerification() {
        let key = SymmetricKey(size: .bits256)
        let original = makeRequest(signingKey: key)
        // Same signature string, but the toolName it's supposedly signing
        // over has changed — the recomputed payload no longer matches what
        // was actually signed.
        let tampered = QApprovalRequest(
            forgedForTestingWithSignature: original.signature,
            basedOn: QApprovalRequest(
                taskId: original.taskId,
                toolName: "ui.click_element_TAMPERED",
                riskLevel: original.riskLevel,
                literalAction: original.literalAction,
                affectedResources: original.affectedResources,
                scope: original.scope,
                reason: original.reason,
                isContextTainted: original.isContextTainted,
                signingKey: key
            )
        )
        #expect(tampered.verifySignature(using: key) == false)
    }

    @Test("A malformed (non-hex) signature is rejected without crashing")
    func malformedHexSignatureIsRejected() {
        let key = SymmetricKey(size: .bits256)
        let request = makeRequest(signingKey: key)
        let malformed = QApprovalRequest(forgedForTestingWithSignature: "zzz-not-hex-zzz", basedOn: request)
        #expect(malformed.verifySignature(using: key) == false)
    }

    @Test("An odd-length hex-looking signature is rejected without crashing")
    func oddLengthSignatureIsRejected() {
        let key = SymmetricKey(size: .bits256)
        let request = makeRequest(signingKey: key)
        let oddLength = QApprovalRequest(forgedForTestingWithSignature: "abc", basedOn: request)
        #expect(oddLength.verifySignature(using: key) == false)
    }
}
