//
//  QCapabilityModelTests.swift
//  leanring-buddyTests
//
//  Unit tests for QCapabilityModel (Phase 1c.2)
//

import Testing
import Foundation
@testable import Pace

@Suite("QCapabilityModelTests")
struct QCapabilityModelTests {

    @Test("Capability levels order correctly and have appropriate properties")
    func capabilityLevelOrdering() {
        #expect(QCapabilityLevel.level0ReadOnly < QCapabilityLevel.level1SafeLocalAction)
        #expect(QCapabilityLevel.level1SafeLocalAction < QCapabilityLevel.level2UserApproval)
        #expect(QCapabilityLevel.level2UserApproval < QCapabilityLevel.level3HighRisk)
        #expect(QCapabilityLevel.level3HighRisk < QCapabilityLevel.level4Blocked)

        #expect(!QCapabilityLevel.level0ReadOnly.requiresExplicitApproval)
        #expect(!QCapabilityLevel.level1SafeLocalAction.requiresExplicitApproval)
        #expect(QCapabilityLevel.level2UserApproval.requiresExplicitApproval)
        #expect(QCapabilityLevel.level3HighRisk.requiresExplicitApproval)
        #expect(QCapabilityLevel.level4Blocked.isProhibited)
    }

    @Test("Level 4 is universally ungrantable and cannot match any request")
    func level4CannotBeGranted() {
        let cap = QCapability(
            toolFamily: "fs",
            toolName: "*",
            scope: .global,
            maxRiskLevel: .level4Blocked
        )

        // Cannot match even if requested for Level 4
        #expect(!cap.matches(tool: "fs.delete", targetScope: .global, risk: .level4Blocked))
        // And when requesting Level 4 on a Level 3 grant, it fails
        let cap3 = QCapability(
            toolFamily: "fs",
            toolName: "*",
            scope: .global,
            maxRiskLevel: .level3HighRisk
        )
        #expect(!cap3.matches(tool: "fs.delete", targetScope: .global, risk: .level4Blocked))
    }

    @Test("Resource scopes properly check path containment")
    func resourceScopeContainment() {
        let parentScope = QResourceScope.filesystem(pathPrefix: "/Users/hani/Developer/project")
        let childScope = QResourceScope.filesystem(pathPrefix: "/Users/hani/Developer/project/src/main.swift")
        let outsideScope = QResourceScope.filesystem(pathPrefix: "/Users/hani/.ssh/id_rsa")

        #expect(parentScope.contains(scope: childScope))
        #expect(!parentScope.contains(scope: outsideScope))

        let globalScope = QResourceScope.global
        #expect(globalScope.contains(scope: childScope))
        #expect(globalScope.contains(scope: outsideScope))

        let netScope = QResourceScope.network(hostPattern: "*.github.com")
        #expect(netScope.contains(scope: .network(hostPattern: "api.github.com")))
        #expect(netScope.contains(scope: .network(hostPattern: "github.com")))
        #expect(!netScope.contains(scope: .network(hostPattern: "gitlab.com")))
    }

    @Test("Capability expiry is strictly enforced")
    func capabilityExpiry() {
        let now = Date()
        let past = now.addingTimeInterval(-60)
        let future = now.addingTimeInterval(60)

        let expiredCap = QCapability(
            toolFamily: "fs",
            toolName: "read",
            scope: .global,
            maxRiskLevel: .level1SafeLocalAction,
            expiresAt: past
        )
        #expect(expiredCap.isExpired(at: now))
        #expect(!expiredCap.matches(tool: "fs.read", targetScope: .global, risk: .level0ReadOnly, at: now))

        let validCap = QCapability(
            toolFamily: "fs",
            toolName: "read",
            scope: .global,
            maxRiskLevel: .level1SafeLocalAction,
            expiresAt: future
        )
        #expect(!validCap.isExpired(at: now))
        #expect(validCap.matches(tool: "fs.read", targetScope: .global, risk: .level0ReadOnly, at: now))
    }

    @Test("Tainted context downgrades standing grants at Level 2 and above")
    func taintDowngradesStandingGrants() {
        let cap = QCapability(
            toolFamily: "fs",
            toolName: "write",
            scope: .filesystem(pathPrefix: "/tmp"),
            maxRiskLevel: .level2UserApproval,
            provenanceCeiling: .trustedOnly
        )

        // Untainted context matches
        #expect(cap.matches(
            tool: "fs.write",
            targetScope: .filesystem(pathPrefix: "/tmp/test.txt"),
            risk: .level2UserApproval,
            isContextTainted: false
        ))

        // Tainted context fails match for Level 2
        #expect(!cap.matches(
            tool: "fs.write",
            targetScope: .filesystem(pathPrefix: "/tmp/test.txt"),
            risk: .level2UserApproval,
            isContextTainted: true
        ))

        // Level 0/1 with anyProvenance still matches
        let readCap = QCapability(
            toolFamily: "fs",
            toolName: "read",
            scope: .global,
            maxRiskLevel: .level1SafeLocalAction,
            provenanceCeiling: .anyProvenance
        )
        #expect(readCap.matches(
            tool: "fs.read",
            targetScope: .global,
            risk: .level0ReadOnly,
            isContextTainted: true
        ))
    }
}
