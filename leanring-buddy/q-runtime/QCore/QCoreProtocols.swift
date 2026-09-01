//
//  QCoreProtocols.swift
//  leanring-buddy
//
//  Q Security Architecture — Core Orchestrator Protocols (Phase 1D.4).
//  Defines strict decoupled provider contracts for Model, Tool, Memory, and Execution.
//

import Foundation

// MARK: - Task State & Model

public enum QTaskState: Equatable, Sendable {
    case pending
    case running
    case awaitingApproval(QApprovalRequest)
    case completed(summary: String)
    case failed(reason: String)

    public var isTerminal: Bool {
        switch self {
        case .completed, .failed:
            return true
        case .pending, .running, .awaitingApproval:
            return false
        }
    }

    public var isCompleted: Bool {
        if case .completed = self { return true }
        return false
    }
}

public struct QTask: Sendable {
    public let taskId: String
    public let sessionId: String
    public let intent: String
    public var state: QTaskState
    public var context: QTaskContext
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        taskId: String = UUID().uuidString,
        sessionId: String = UUID().uuidString,
        intent: String,
        state: QTaskState = .pending,
        context: QTaskContext? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.taskId = taskId
        self.sessionId = sessionId
        self.intent = intent
        self.state = state
        self.context = context ?? QTaskContext(taskId: taskId)
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// MARK: - Execution Request & Result

public struct QActionRequest: Sendable {
    public let actionId: String
    public let toolName: String
    public let toolFamily: String
    public let riskLevel: QCapabilityLevel
    public let literalAction: String
    public let targetResources: [String]
    public let parameters: [String: String]

    public init(
        actionId: String = UUID().uuidString,
        toolName: String,
        toolFamily: String,
        riskLevel: QCapabilityLevel,
        literalAction: String,
        targetResources: [String] = [],
        parameters: [String: String] = [:]
    ) {
        self.actionId = actionId
        self.toolName = toolName
        self.toolFamily = toolFamily
        self.riskLevel = riskLevel
        self.literalAction = literalAction
        self.targetResources = targetResources
        self.parameters = parameters
    }
}

public struct QActionResult: Sendable {
    public let actionId: String
    public let success: Bool
    public let summary: String
    public let outputData: [String: String]
    public let error: String?

    public init(
        actionId: String,
        success: Bool,
        summary: String,
        outputData: [String: String] = [:],
        error: String? = nil
    ) {
        self.actionId = actionId
        self.success = success
        self.summary = summary
        self.outputData = outputData
        self.error = error
    }
}

// MARK: - Decoupled Provider Protocols

public protocol QModelProvider: Sendable {
    func generatePlan(for task: QTask) async throws -> [QActionRequest]
}

public protocol QStructuredModelProvider: QModelProvider {
    func generateStructuredPlan(for task: QTask, memoryContext: String?, failureContext: String?) async throws -> QPlan
    func generateGroundedSummary(for task: QTask, verifiedEvidence: [String], isSuccess: Bool) async throws -> String
}

public protocol QToolProvider: Sendable {
    func canHandle(toolName: String) -> Bool
    func describeTools() -> [String]
}

public protocol QMemoryProvider: Sendable {
    func recordTaskStart(_ task: QTask) async throws
    func recordTaskCompletion(_ task: QTask, result: String) async throws
    func queryContext(for query: String, limit: Int) async throws -> [String]
}

public protocol QExecutionProvider: Sendable {
    func executeAction(_ request: QActionRequest, context: QTaskContext) async throws -> QActionResult
}
