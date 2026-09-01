//
//  QCapabilityModel.swift
//  leanring-buddy
//
//  Q Security Architecture — Strongly-Typed Capability & Risk Model.
//  Implements Level 0–4 permission hierarchy, resource scopes,
//  and cryptographically scoped capability grants with default-deny semantics.
//

import Foundation

// MARK: - Capability Levels 0–4

public enum QCapabilityLevel: Int, Comparable, Codable, Sendable, CustomStringConvertible {
    /// Level 0: Read-only operations. Zero persistent state mutation. (e.g. screenshot, read file in scope)
    case level0ReadOnly = 0
    /// Level 1: Safe local actions with low blast radius. (e.g. launch app, focus window, temp file)
    case level1SafeLocalAction = 1
    /// Level 2: State-changing operations requiring user approval. (e.g. modify file, edit code, send message)
    case level2UserApproval = 2
    /// Level 3: High-risk, destructive, or external actions. (e.g. delete file, destructive shell/git, email, download)
    case level3HighRisk = 3
    /// Level 4: Blocked operations. Prohibited capabilities that are unimplemented and cannot be granted.
    case level4Blocked = 4

    public var description: String {
        switch self {
        case .level0ReadOnly:
            return "Level 0 (Read Only)"
        case .level1SafeLocalAction:
            return "Level 1 (Safe Local Action)"
        case .level2UserApproval:
            return "Level 2 (User Approval)"
        case .level3HighRisk:
            return "Level 3 (High Risk)"
        case .level4Blocked:
            return "Level 4 (Blocked - Hard Prohibited)"
        }
    }

    public var isProhibited: Bool {
        self == .level4Blocked
    }

    public var requiresExplicitApproval: Bool {
        self >= .level2UserApproval
    }

    public static func < (lhs: QCapabilityLevel, rhs: QCapabilityLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - Resource Scopes

public enum QResourceScope: Codable, Sendable, Equatable, Hashable {
    case filesystem(pathPrefix: String)
    case network(hostPattern: String)
    case accessibility(bundleIdPattern: String)
    case system(domain: String)
    case global
    case none

    public func contains(scope other: QResourceScope) -> Bool {
        switch (self, other) {
        case (.global, _):
            return true
        case (.none, .none):
            return true
        case (.filesystem(let parent), .filesystem(let child)):
            let normalizedParent = parent.hasSuffix("/") ? parent : parent + "/"
            let normalizedChild = child.hasSuffix("/") ? child : child + "/"
            return normalizedChild.hasPrefix(normalizedParent) || parent == child
        case (.network(let parentPattern), .network(let targetHost)):
            if parentPattern == "*" { return true }
            if parentPattern.hasPrefix("*.") {
                let suffix = parentPattern.dropFirst(2)
                return targetHost == suffix || targetHost.hasSuffix("." + suffix)
            }
            return parentPattern.lowercased() == targetHost.lowercased()
        case (.accessibility(let pattern), .accessibility(let targetBundleId)):
            if pattern == "*" { return true }
            return pattern.lowercased() == targetBundleId.lowercased()
        case (.system(let parentDomain), .system(let targetDomain)):
            return parentDomain.lowercased() == targetDomain.lowercased()
        default:
            return false
        }
    }
}

// MARK: - Grant Origin & Provenance Ceiling

public enum QGrantOrigin: String, Codable, Sendable {
    case policyDefault
    case userInteractive
    case sessionGrant
    case projectScoped
}

public enum QProvenanceCeiling: String, Codable, Sendable {
    /// Grant survives only as long as all context items are trusted
    case trustedOnly
    /// Grant survives regardless of context provenance (Level 0 and 1 only)
    case anyProvenance
}

// MARK: - Capability Token

public struct QCapability: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public let toolFamily: String
    public let toolName: String
    public let scope: QResourceScope
    public let maxRiskLevel: QCapabilityLevel
    public let grantedBy: QGrantOrigin
    public let grantedAt: Date
    public let expiresAt: Date?
    public let project: String?
    public let argumentPattern: String?
    public let provenanceCeiling: QProvenanceCeiling

    public init(
        id: UUID = UUID(),
        toolFamily: String,
        toolName: String = "*",
        scope: QResourceScope = .global,
        maxRiskLevel: QCapabilityLevel,
        grantedBy: QGrantOrigin = .policyDefault,
        grantedAt: Date = Date(),
        expiresAt: Date? = nil,
        project: String? = nil,
        argumentPattern: String? = nil,
        provenanceCeiling: QProvenanceCeiling = .trustedOnly
    ) {
        self.id = id
        self.toolFamily = toolFamily
        self.toolName = toolName
        self.scope = scope
        self.maxRiskLevel = maxRiskLevel
        self.grantedBy = grantedBy
        self.grantedAt = grantedAt
        self.expiresAt = expiresAt
        self.project = project
        self.argumentPattern = argumentPattern
        self.provenanceCeiling = provenanceCeiling
    }

    public func isExpired(at date: Date = Date()) -> Bool {
        guard let expiresAt = expiresAt else { return false }
        return date >= expiresAt
    }

    public func matches(
        tool: String,
        targetScope: QResourceScope,
        risk: QCapabilityLevel,
        isContextTainted: Bool = false,
        at date: Date = Date()
    ) -> Bool {
        // Level 4 is universally ungrantable
        if risk == .level4Blocked || maxRiskLevel == .level4Blocked {
            return false
        }

        // Expired grants do not match
        if isExpired(at: date) {
            return false
        }

        // Risk level ceiling
        if risk > maxRiskLevel {
            return false
        }

        // Provenance ceiling check: if context is tainted and capability requires trusted-only
        if isContextTainted && provenanceCeiling == .trustedOnly && risk >= .level2UserApproval {
            return false
        }

        // Tool name / family matching
        let toolMatches: Bool
        if toolName == "*" {
            toolMatches = tool.hasPrefix(toolFamily + ".") || tool == toolFamily
        } else {
            toolMatches = (tool == toolName) || (tool == "\(toolFamily).\(toolName)")
        }

        guard toolMatches else { return false }

        // Scope containment
        return scope.contains(scope: targetScope)
    }
}
