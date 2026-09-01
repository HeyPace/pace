//
//  QApprovalCoordinator.swift
//  leanring-buddy
//
//  Q Security Architecture — Approval Resolution Engine (Phase 2E).
//  Tracks pending Level 2/3 approval requests and resolves them into single-use,
//  execution-identity-bound grants. Deliberately in-memory only: a process restart
//  wipes all pending requests and grants, so a persisted "awaiting approval" state
//  can NEVER silently re-authorize an action after crash/recovery — a fresh approval
//  is always required. See QCoreRuntime.resolveApproval and QPlanExecutor.
//

import Foundation

// MARK: - Approval Decision

public enum QApprovalDecision: Sendable, Equatable {
    case approved
    case denied(reason: String)
}

// MARK: - Resolution Outcome

public enum QApprovalResolutionOutcome: Sendable, Equatable {
    /// Approval granted. The one-time grant is bound to `fingerprint`
    /// (`QExecutionIdentity.stepFingerprint`) and can be consumed exactly once.
    case granted(fingerprint: String)
    case rejected(reason: String)
    /// No pending request exists for this id — either it never existed, already expired,
    /// was already resolved, or belonged to a prior process (grants do not survive crash/restart).
    case notFound
    case expired
}

// MARK: - Approval Coordinator

public final class QApprovalCoordinator: @unchecked Sendable {
    public static let shared = QApprovalCoordinator()

    private let lock = NSLock()
    private var pendingRequests: [UUID: QApprovalRequest] = [:]
    private var oneTimeGrants: Set<String> = []

    public init() {}

    /// Registers a request as pending user approval. Deterministic ids mean re-registering
    /// the same execution attempt (e.g. across a resume reconstruction) simply overwrites
    /// the same entry rather than creating a duplicate.
    public func recordPending(_ request: QApprovalRequest) {
        lock.lock()
        defer { lock.unlock() }
        pendingRequests[request.id] = request
    }

    public func pendingRequest(id: UUID) -> QApprovalRequest? {
        lock.lock()
        defer { lock.unlock() }
        return pendingRequests[id]
    }

    /// Resolves a pending approval request. Approving mints a single-use grant scoped to the
    /// request's `executionIdentity` fingerprint — it authorizes ONLY that exact task/plan/step/
    /// action attempt, never a different action, and is consumed on first use (see
    /// `consumeGrantIfPresent`). Denying never mints a grant and is terminal for this request.
    public func resolve(
        approvalId: UUID,
        decision: QApprovalDecision,
        at date: Date = Date()
    ) -> QApprovalResolutionOutcome {
        lock.lock()
        defer { lock.unlock() }

        guard let request = pendingRequests[approvalId] else {
            return .notFound
        }

        guard date < request.expiresAt else {
            pendingRequests.removeValue(forKey: approvalId)
            QAuditLogger.shared.record(
                QAuditRecord(
                    sessionId: request.taskId,
                    taskId: request.taskId,
                    tool: request.toolName,
                    riskLevel: request.riskLevel,
                    rawArguments: request.literalAction,
                    authorizationResult: "deny",
                    provenance: request.isContextTainted ? "untrusted" : "trusted:user",
                    executionSummary: "Approval request \(approvalId) expired before resolution.",
                    error: "expired"
                )
            )
            return .expired
        }

        // Approval is single-resolution: remove it from the pending set regardless of outcome
        // so a second resolve() call for the same id always returns .notFound, never re-grants.
        pendingRequests.removeValue(forKey: approvalId)

        switch decision {
        case .denied(let reason):
            QAuditLogger.shared.record(
                QAuditRecord(
                    sessionId: request.taskId,
                    taskId: request.taskId,
                    tool: request.toolName,
                    riskLevel: request.riskLevel,
                    rawArguments: request.literalAction,
                    authorizationResult: "deny",
                    provenance: request.isContextTainted ? "untrusted" : "trusted:user",
                    executionSummary: "User denied approval request \(approvalId): \(reason)"
                )
            )
            return .rejected(reason: reason)

        case .approved:
            guard let identity = request.executionIdentity else {
                // Fail closed: an approval with no bound execution identity cannot be safely
                // scoped to a single action, so it is never granted.
                QAuditLogger.shared.record(
                    QAuditRecord(
                        sessionId: request.taskId,
                        taskId: request.taskId,
                        tool: request.toolName,
                        riskLevel: request.riskLevel,
                        rawArguments: request.literalAction,
                        authorizationResult: "deny",
                        provenance: request.isContextTainted ? "untrusted" : "trusted:user",
                        executionSummary: "Approval \(approvalId) cannot be granted: no bound execution identity.",
                        error: "missing_execution_identity"
                    )
                )
                return .rejected(reason: "Approval request has no bound execution identity; cannot be safely granted.")
            }

            let fingerprint = identity.stepFingerprint
            oneTimeGrants.insert(fingerprint)

            QAuditLogger.shared.record(
                QAuditRecord(
                    sessionId: request.taskId,
                    taskId: request.taskId,
                    tool: request.toolName,
                    riskLevel: request.riskLevel,
                    rawArguments: request.literalAction,
                    authorizationResult: "allow",
                    provenance: request.isContextTainted ? "untrusted" : "trusted:user",
                    executionSummary: "User approved request \(approvalId); minted single-use grant fingerprint=\(fingerprint)."
                )
            )
            return .granted(fingerprint: fingerprint)
        }
    }

    /// Consumes (single-use) a one-time grant if one is currently present for this exact
    /// execution fingerprint. Returns true at most once per granted approval — a second call
    /// with the same fingerprint returns false, so a prior approval can never re-fire twice
    /// and can never authorize a different step (fingerprints are step-specific).
    public func consumeGrantIfPresent(fingerprint: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if oneTimeGrants.contains(fingerprint) {
            oneTimeGrants.remove(fingerprint)
            return true
        }
        return false
    }

    /// Test-only helper: clears all pending requests and grants. Never invoked by production
    /// code paths — grants otherwise only disappear via consumption, expiry-driven resolve(),
    /// or process restart (this store is intentionally never persisted).
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        pendingRequests.removeAll()
        oneTimeGrants.removeAll()
    }
}
