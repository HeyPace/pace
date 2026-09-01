//
//  QAgent.swift
//  leanring-buddy
//
//  Q Security Architecture — Local Agent Public API (Phase 1E.3).
//  Provides the high-level orchestration entrypoint for local tasks,
//  strictly routing through Provenance, Model, Permission Gate, Exec, Verification, and Audit.
//

import Foundation

public enum QAgentStatus: Sendable, Codable, Equatable {
    case completed
    case failed(reason: String)
    case awaitingApproval(toolName: String, riskLevel: String)
}

public struct QAgentResult: Sendable, Codable, Equatable {
    public let taskId: String
    public let sessionId: String
    public let intent: String
    public let status: QAgentStatus
    public let summary: String
    public let provenanceTag: String
    public let modelUsed: String
    public let durationSeconds: Double

    public var isSuccess: Bool {
        if case .completed = status { return true }
        return false
    }

    public init(
        taskId: String,
        sessionId: String,
        intent: String,
        status: QAgentStatus,
        summary: String,
        provenanceTag: String = "trusted:user",
        modelUsed: String = "apple.foundation",
        durationSeconds: Double = 0.0
    ) {
        self.taskId = taskId
        self.sessionId = sessionId
        self.intent = intent
        self.status = status
        self.summary = summary
        self.provenanceTag = provenanceTag
        self.modelUsed = modelUsed
        self.durationSeconds = durationSeconds
    }
}

public final class QAgent: Sendable {
    public static let shared = QAgent()

    public init() {}

    /// Runs a real local agent task end-to-end through the verified Q security pipeline.
    public func run(task: String, sessionId: String = UUID().uuidString) async throws -> QAgentResult {
        let start = Date()

        // 1. Ensure runtime is bootstrapped
        let bootstrap = QRuntimeBootstrap.shared
        if bootstrap.getCoreRuntime() == nil {
            await bootstrap.bootstrap()
        }

        guard let core = bootstrap.getCoreRuntime() else {
            throw QAgentError.runtimeNotBootstrapped("Q Runtime failed to initialize core orchestrator.")
        }

        // 2. Submit intent to Core Runtime
        let executedTask: QTask
        do {
            executedTask = try await core.submitIntent(prompt: task, sessionId: sessionId)
        } catch {
            let duration = Date().timeIntervalSince(start)
            return QAgentResult(
                taskId: UUID().uuidString,
                sessionId: sessionId,
                intent: task,
                status: .failed(reason: error.localizedDescription),
                summary: "Execution failed: \(error.localizedDescription)",
                durationSeconds: duration
            )
        }

        let duration = Date().timeIntervalSince(start)
        let modelUsed = await bootstrap.getModelRouter()?.selectBestBackend()?.capabilities.modelIdentifier ?? "apple/on-device-3b"

        // 3. Map Task Outcome to Agent Result
        switch executedTask.state {
        case .completed(let summary):
            return QAgentResult(
                taskId: executedTask.taskId,
                sessionId: executedTask.sessionId,
                intent: task,
                status: .completed,
                summary: summary,
                provenanceTag: executedTask.context.isTainted ? "untrusted" : "trusted:user",
                modelUsed: modelUsed,
                durationSeconds: duration
            )

        case .failed(let reason):
            return QAgentResult(
                taskId: executedTask.taskId,
                sessionId: executedTask.sessionId,
                intent: task,
                status: .failed(reason: reason),
                summary: "Task halted: \(reason)",
                provenanceTag: executedTask.context.isTainted ? "untrusted" : "trusted:user",
                modelUsed: modelUsed,
                durationSeconds: duration
            )

        case .awaitingApproval(let approvalReq):
            return QAgentResult(
                taskId: executedTask.taskId,
                sessionId: executedTask.sessionId,
                intent: task,
                status: .awaitingApproval(toolName: approvalReq.toolName, riskLevel: approvalReq.riskLevel.description),
                summary: "Action requires user approval: \(approvalReq.reason)",
                provenanceTag: executedTask.context.isTainted ? "untrusted" : "trusted:user",
                modelUsed: modelUsed,
                durationSeconds: duration
            )

        case .pending, .running:
            return QAgentResult(
                taskId: executedTask.taskId,
                sessionId: executedTask.sessionId,
                intent: task,
                status: .failed(reason: "Task did not terminate in expected lifecycle state"),
                summary: "Incomplete task execution",
                durationSeconds: duration
            )
        }
    }
}

public enum QAgentError: Error, Equatable, Sendable {
    case runtimeNotBootstrapped(String)
}
