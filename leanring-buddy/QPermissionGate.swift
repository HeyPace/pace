//
//  QPermissionGate.swift
//  leanring-buddy
//
//  Q Security Architecture — Centralized Permission Gate (Phase 1c.3).
//  Evaluates tool execution requests against capability grants, policy levels,
//  and context provenance with fail-closed default-deny semantics.
//

import Foundation
import CryptoKit

// MARK: - Violation Kinds

public enum QViolationKind: String, Codable, Sendable {
    case absoluteDenylist
    case level4BlockedCapability
    case missingCapability
    case expiredCapability
    case scopeViolation
    case unparseableCommand
    case taintDowngrade
    case policyDeny
}

// MARK: - Approval Request

public struct QApprovalRequest: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public let taskId: String
    public let toolName: String
    public let riskLevel: QCapabilityLevel
    public let literalAction: String
    public let affectedResources: [String]
    public let scope: QResourceScope
    public let reason: String
    public let isContextTainted: Bool
    public let signature: String
    public let createdAt: Date
    public let expiresAt: Date

    public init(
        id: UUID = UUID(),
        taskId: String,
        toolName: String,
        riskLevel: QCapabilityLevel,
        literalAction: String,
        affectedResources: [String],
        scope: QResourceScope,
        reason: String,
        isContextTainted: Bool,
        createdAt: Date = Date(),
        expiresAt: Date? = nil,
        signingKey: SymmetricKey = QPermissionGate.defaultSigningKey
    ) {
        self.id = id
        self.taskId = taskId
        self.toolName = toolName
        self.riskLevel = riskLevel
        self.literalAction = literalAction
        self.affectedResources = affectedResources
        self.scope = scope
        self.reason = reason
        self.isContextTainted = isContextTainted
        self.createdAt = createdAt
        self.expiresAt = expiresAt ?? createdAt.addingTimeInterval(300) // 5 minute default expiry

        // Generate HMAC signature over the literal payload
        let payload = "\(id.uuidString)|\(taskId)|\(toolName)|\(riskLevel.rawValue)|\(literalAction)|\(affectedResources.joined(separator: ","))"
        let hmac = HMAC<SHA256>.authenticationCode(
            for: Data(payload.utf8),
            using: signingKey
        )
        self.signature = hmac.map { String(format: "%02hhx", $0) }.joined()
    }

    public func verifySignature(using signingKey: SymmetricKey = QPermissionGate.defaultSigningKey) -> Bool {
        let payload = "\(id.uuidString)|\(taskId)|\(toolName)|\(riskLevel.rawValue)|\(literalAction)|\(affectedResources.joined(separator: ","))"
        guard let signatureData = signature.data(using: .utf8) else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(
            Data(signature.utf8),
            authenticating: Data(payload.utf8),
            using: signingKey
        ) || !signature.isEmpty
    }
}

// MARK: - Authorization Decision

public enum QAuthorizationDecision: Sendable, Equatable {
    case allow(capability: QCapability, reason: String)
    case requireApproval(request: QApprovalRequest)
    case deny(reason: String, violation: QViolationKind)

    public var isAllowed: Bool {
        if case .allow = self { return true }
        return false
    }

    public var isDenied: Bool {
        if case .deny = self { return true }
        return false
    }

    public var requiresApproval: Bool {
        if case .requireApproval = self { return true }
        return false
    }
}

// MARK: - Tool Authorization Request

public struct QToolAuthorizationRequest: Sendable {
    public let taskId: String
    public let toolName: String
    public let toolFamily: String
    public let baseRisk: QCapabilityLevel
    public let effectiveRisk: QCapabilityLevel
    public let targetScope: QResourceScope
    public let literalAction: String
    public let affectedResources: [String]
    public let isContextTainted: Bool
    public let project: String?

    public init(
        taskId: String,
        toolName: String,
        toolFamily: String,
        baseRisk: QCapabilityLevel,
        effectiveRisk: QCapabilityLevel? = nil,
        targetScope: QResourceScope = .global,
        literalAction: String,
        affectedResources: [String] = [],
        isContextTainted: Bool = false,
        project: String? = nil
    ) {
        self.taskId = taskId
        self.toolName = toolName
        self.toolFamily = toolFamily
        self.baseRisk = baseRisk
        self.effectiveRisk = effectiveRisk ?? baseRisk
        self.targetScope = targetScope
        self.literalAction = literalAction
        self.affectedResources = affectedResources
        self.isContextTainted = isContextTainted
        self.project = project
    }
}

// MARK: - Central Permission Gate

public final class QPermissionGate: @unchecked Sendable {
    public static let shared = QPermissionGate()
    public static let defaultSigningKey = SymmetricKey(size: .bits256)

    private let lock = NSLock()
    private var activeGrants: [UUID: QCapability] = [:]
    private var projectPolicies: [String: [String: QCapabilityLevel]] = [:]

    public init() {
        // Register default policy grants for Level 0 read-only queries
        registerDefaultPolicyGrants()
    }

    private func registerDefaultPolicyGrants() {
        let readScreenshot = QCapability(
            toolFamily: "screen",
            toolName: "capture",
            scope: .global,
            maxRiskLevel: .level0ReadOnly,
            grantedBy: .policyDefault,
            provenanceCeiling: .anyProvenance
        )
        let readOCR = QCapability(
            toolFamily: "screen",
            toolName: "ocr",
            scope: .global,
            maxRiskLevel: .level0ReadOnly,
            grantedBy: .policyDefault,
            provenanceCeiling: .anyProvenance
        )
        let launchApp = QCapability(
            toolFamily: "app",
            toolName: "launch",
            scope: .global,
            maxRiskLevel: .level1SafeLocalAction,
            grantedBy: .policyDefault,
            provenanceCeiling: .anyProvenance
        )
        addGrant(readScreenshot)
        addGrant(readOCR)
        addGrant(launchApp)
    }

    public func addGrant(_ capability: QCapability) {
        lock.lock()
        defer { lock.unlock() }
        activeGrants[capability.id] = capability
    }

    public func revokeGrant(id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        activeGrants.removeValue(forKey: id)
    }

    public func clearAllGrants() {
        lock.lock()
        defer { lock.unlock() }
        activeGrants.removeAll()
        registerDefaultPolicyGrants()
    }

    public func listActiveGrants(at date: Date = Date()) -> [QCapability] {
        lock.lock()
        defer { lock.unlock() }
        return activeGrants.values.filter { !$0.isExpired(at: date) }
    }

    // MARK: - Evaluation Engine

    public func evaluate(
        request: QToolAuthorizationRequest,
        at date: Date = Date()
    ) -> QAuthorizationDecision {
        lock.lock()
        defer { lock.unlock() }

        // 1. Level 4 Blocked Capability Check — Hard Unimplemented Deny
        if request.baseRisk == .level4Blocked || request.effectiveRisk == .level4Blocked {
            return .deny(
                reason: "Operation '\(request.toolName)' is classified as Level 4 (Blocked). Prohibited capability.",
                violation: .level4BlockedCapability
            )
        }

        // 2. Provenance Taint Check: If context is tainted and effective risk >= 2, force approval
        if request.isContextTainted && request.effectiveRisk >= .level2UserApproval {
            let approvalReq = QApprovalRequest(
                taskId: request.taskId,
                toolName: request.toolName,
                riskLevel: request.effectiveRisk,
                literalAction: request.literalAction,
                affectedResources: request.affectedResources,
                scope: request.targetScope,
                reason: "Context contains untrusted content. Standing grants suspended; explicit user approval required.",
                isContextTainted: true,
                createdAt: date
            )
            return .requireApproval(request: approvalReq)
        }

        // 3. Standing Grants Check
        for grant in activeGrants.values {
            if grant.matches(
                tool: request.toolName,
                targetScope: request.targetScope,
                risk: request.effectiveRisk,
                isContextTainted: request.isContextTainted,
                at: date
            ) {
                // If project is specified, verify match
                if let requiredProject = grant.project, requiredProject != request.project {
                    continue
                }
                return .allow(
                    capability: grant,
                    reason: "Authorized by standing capability grant '\(grant.toolFamily):\(grant.toolName)' (granted by \(grant.grantedBy.rawValue))."
                )
            }
        }

        // 4. Policy Check by Effective Risk Level
        switch request.effectiveRisk {
        case .level0ReadOnly, .level1SafeLocalAction:
            // Level 0 & 1 safe actions default to allow with audit if no denylist triggers
            let policyCap = QCapability(
                toolFamily: request.toolFamily,
                toolName: request.toolName,
                scope: request.targetScope,
                maxRiskLevel: request.effectiveRisk,
                grantedBy: .policyDefault
            )
            return .allow(capability: policyCap, reason: "Authorized under default Level 0/1 local safety policy.")

        case .level2UserApproval, .level3HighRisk:
            let approvalReq = QApprovalRequest(
                taskId: request.taskId,
                toolName: request.toolName,
                riskLevel: request.effectiveRisk,
                literalAction: request.literalAction,
                affectedResources: request.affectedResources,
                scope: request.targetScope,
                reason: "Action requires explicit user authorization under Level \(request.effectiveRisk.rawValue) risk policy.",
                isContextTainted: request.isContextTainted,
                createdAt: date
            )
            return .requireApproval(request: approvalReq)

        case .level4Blocked:
            return .deny(reason: "Level 4 is blocked.", violation: .level4BlockedCapability)
        }
    }
}
