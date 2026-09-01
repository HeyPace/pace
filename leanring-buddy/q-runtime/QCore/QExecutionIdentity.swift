//
//  QExecutionIdentity.swift
//  leanring-buddy
//
//  Q Security Architecture — Action Execution Identity & Idempotency (Phase 2D).
//  Uniquely identifies physical execution attempts and ensures idempotent action dispatch
//  across crashes and restarts.
//

import Foundation

public struct QExecutionIdentity: Codable, Sendable, Equatable, Hashable {
    public let taskId: String
    public let planId: String
    public let stepId: String
    public let attemptId: String
    public let actionName: String
    public let targetResources: [String]
    public let timestamp: Date

    public init(
        taskId: String,
        planId: String,
        stepId: String,
        attemptId: String = UUID().uuidString,
        actionName: String,
        targetResources: [String] = [],
        timestamp: Date = Date()
    ) {
        self.taskId = taskId
        self.planId = planId
        self.stepId = stepId
        self.attemptId = attemptId
        self.actionName = actionName
        self.targetResources = targetResources
        self.timestamp = timestamp
    }

    /// Computes a unique deterministic idempotent fingerprint for this specific action step
    public var stepFingerprint: String {
        "\(taskId):\(planId):\(stepId):\(actionName)"
    }
}
