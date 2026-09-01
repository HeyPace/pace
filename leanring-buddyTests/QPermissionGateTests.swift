//
//  QPermissionGateTests.swift
//  leanring-buddyTests
//
//  Unit tests for QPermissionGate (Phase 1c.3)
//

import Testing
import Foundation
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
