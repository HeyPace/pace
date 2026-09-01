//
//  QCoreRuntime.swift
//  leanring-buddy
//
//  Q Security Architecture — Core Runtime Orchestrator (Phase 1D.4, 2B & Phase 2C).
//  Orchestrates memory retrieval, structured multi-step planning, sequential QPlanExecutor
//  execution, empirical closed-loop goal evaluation (QGoalEvaluator), loop-detecting controlled
//  replanning (QReplanController), and grounded local summary generation.
//

import Foundation

public final class QCoreRuntime: @unchecked Sendable {
    public static let shared = QCoreRuntime()

    private let lock = NSRecursiveLock()
    private var modelProvider: QModelProvider?
    private var memoryProvider: QMemoryProvider?
    private var executionProvider: QExecutionProvider?
    private let ipcChannel: QIPCChannel
    private var tasks: [String: QTask] = [:]

    public init(
        modelProvider: QModelProvider? = nil,
        memoryProvider: QMemoryProvider? = nil,
        executionProvider: QExecutionProvider? = nil,
        endpointName: String = "q-core"
    ) {
        self.modelProvider = modelProvider
        self.memoryProvider = memoryProvider
        self.executionProvider = executionProvider
        self.ipcChannel = QIPCChannel(endpointName: endpointName)
        setupIPCHandlers()
    }

    public func configure(
        modelProvider: QModelProvider? = nil,
        memoryProvider: QMemoryProvider? = nil,
        executionProvider: QExecutionProvider? = nil
    ) {
        lock.lock()
        defer { lock.unlock() }
        if let modelProvider { self.modelProvider = modelProvider }
        if let memoryProvider { self.memoryProvider = memoryProvider }
        if let executionProvider { self.executionProvider = executionProvider }
    }

    private func setupIPCHandlers() {
        ipcChannel.registerHandler(for: .intentSubmit) { [weak self] envelope in
            guard let self else { return nil }
            let prompt = envelope.message.payload["prompt"] ?? ""
            let session = envelope.message.payload["session"] ?? "default"
            do {
                let task = try await self.submitIntent(prompt: prompt, sessionId: session)
                return QIPCMessage(
                    type: .intentResponse,
                    payload: [
                        "taskId": task.taskId,
                        "status": "completed",
                        "summary": "Task executed"
                    ]
                )
            } catch {
                return QIPCMessage(
                    type: .intentResponse,
                    payload: [
                        "status": "failed",
                        "error": error.localizedDescription
                    ]
                )
            }
        }
    }

    // MARK: - Autonomous Closed-Loop Task Lifecycle (Phase 2C)

    public func submitIntent(
        prompt: String,
        sessionId: String = UUID().uuidString,
        observer: (any QPlanExecutionObserver)? = nil
    ) async throws -> QTask {
        // 1. Create task and initialize trusted context
        var task = QTask(sessionId: sessionId, intent: prompt)
        task.context.append(content: prompt, provenance: .trustedUser(channel: "direct"), sourceId: "user_prompt")

        lock.lock()
        tasks[task.taskId] = task
        lock.unlock()

        // 2. Audit Intent submission
        QAuditLogger.shared.record(
            QAuditRecord(
                sessionId: sessionId,
                taskId: task.taskId,
                tool: "core.intent_submit",
                riskLevel: .level0ReadOnly,
                rawArguments: prompt,
                authorizationResult: "allow",
                provenance: "trusted:user",
                executionSummary: "Accepted user intent: \(prompt)"
            )
        )

        // 3. Memory store task start
        try? await memoryProvider?.recordTaskStart(task)

        guard let model = modelProvider else {
            task.state = .failed(reason: "No active Model Provider configured in QCoreRuntime.")
            updateTask(task)
            return task
        }

        guard let exec = executionProvider else {
            task.state = .failed(reason: "No Execution Provider configured.")
            updateTask(task)
            return task
        }

        task.state = .running
        updateTask(task)

        // 4. Memory-Aware Context Retrieval (Phase 2B.E)
        var memoryContext: String? = nil
        if let mem = memoryProvider, let contexts = try? await mem.queryContext(for: prompt, limit: 5), !contexts.isEmpty {
            memoryContext = contexts.joined(separator: "\n")
        }

        // 5. Generate Initial Structured Plan
        var currentPlan: QPlan
        do {
            if let structuredModel = model as? QStructuredModelProvider {
                currentPlan = try await structuredModel.generateStructuredPlan(
                    for: task,
                    memoryContext: memoryContext,
                    failureContext: nil
                )
            } else {
                let actions = try await model.generatePlan(for: task)
                let steps = actions.enumerated().map { idx, act in
                    QPlanStep(
                        index: idx,
                        action: QPlannedAction(
                            actionName: act.toolName,
                            toolFamily: act.toolFamily,
                            riskLevel: act.riskLevel,
                            literalAction: act.literalAction,
                            targetResources: act.targetResources,
                            arguments: act.parameters
                        ),
                        description: act.literalAction
                    )
                }
                currentPlan = QPlan(taskId: task.taskId, sessionId: sessionId, taskPrompt: prompt, steps: steps)
            }
        } catch {
            task.state = .failed(reason: "Planning failed: \(error.localizedDescription)")
            updateTask(task)
            return task
        }

        QAuditLogger.shared.record(
            QAuditRecord(
                sessionId: sessionId,
                taskId: task.taskId,
                tool: "plan.created",
                riskLevel: .level0ReadOnly,
                rawArguments: "steps=\(currentPlan.steps.count)",
                authorizationResult: "allow",
                provenance: "trusted:system",
                executionSummary: "Generated initial plan with \(currentPlan.steps.count) steps."
            )
        )

        // 6. Autonomous Closed-Loop Execution, Goal Evaluation & Controlled Replanning (Phase 2C)
        let executor = QPlanExecutor(executionProvider: exec)
        let goalEvaluator = QGoalEvaluator.shared
        let replanController = QReplanController(maxReplans: 2)

        while true {
            QAuditLogger.shared.record(
                QAuditRecord(
                    sessionId: sessionId,
                    taskId: task.taskId,
                    tool: "plan.execution.started",
                    riskLevel: .level0ReadOnly,
                    rawArguments: "planId=\(currentPlan.id.uuidString)",
                    authorizationResult: "allow",
                    provenance: "trusted:system",
                    executionSummary: "Started plan execution iteration."
                )
            )

            let executedPlan = try await executor.execute(
                plan: currentPlan,
                context: task.context,
                observer: observer
            )

            // Handle Permission Approval Halts
            if case .waitingForPermission(let idx, let reason) = executedPlan.state {
                let step = executedPlan.steps[idx]
                let approvalReq = QApprovalRequest(
                    taskId: task.taskId,
                    toolName: step.action.actionName,
                    riskLevel: step.action.riskLevel,
                    literalAction: step.description,
                    affectedResources: step.action.targetResources,
                    scope: .global,
                    reason: reason,
                    isContextTainted: task.context.isTainted
                )
                task.state = .awaitingApproval(approvalReq)
                updateTask(task)
                return task
            }

            // 7. Evidence-First Goal Evaluation
            let goalEvaluation = goalEvaluator.evaluate(
                goal: prompt,
                plan: executedPlan,
                context: task.context
            )

            QAuditLogger.shared.record(
                QAuditRecord(
                    sessionId: sessionId,
                    taskId: task.taskId,
                    tool: "goal.evaluated",
                    riskLevel: .level0ReadOnly,
                    rawArguments: "state=\(goalEvaluation.state.rawValue), confidence=\(String(format: "%.2f", goalEvaluation.confidence))",
                    authorizationResult: "allow",
                    provenance: goalEvaluation.provenance,
                    executionSummary: goalEvaluation.explanation
                )
            )

            // Case A: Goal Satisfied -> Synthesize grounded success summary
            if goalEvaluation.isSatisfied {
                QAuditLogger.shared.record(
                    QAuditRecord(
                        sessionId: sessionId,
                        taskId: task.taskId,
                        tool: "goal.satisfied",
                        riskLevel: .level0ReadOnly,
                        rawArguments: "conditions=\(goalEvaluation.completedConditions.count)",
                        authorizationResult: "allow",
                        provenance: goalEvaluation.provenance,
                        executionSummary: "User goal successfully satisfied."
                    )
                )

                replanController.recordIteration(plan: executedPlan, evaluation: goalEvaluation)

                let finalSummary: String
                if let structuredModel = model as? QStructuredModelProvider {
                    finalSummary = (try? await structuredModel.generateGroundedSummary(
                        for: task,
                        verifiedEvidence: goalEvaluation.evidence,
                        isSuccess: true
                    )) ?? (goalEvaluation.evidence.isEmpty ? "Successfully executed \(task.intent)." : "Successfully executed \(task.intent). \(goalEvaluation.evidence.joined(separator: "; "))")
                } else {
                    finalSummary = goalEvaluation.evidence.isEmpty ? "Successfully executed \(task.intent)." : "Successfully executed \(task.intent). \(goalEvaluation.evidence.joined(separator: "; "))"
                }

                task.state = .completed(summary: finalSummary)
                updateTask(task)
                try? await memoryProvider?.recordTaskCompletion(task, result: finalSummary)

                QAuditLogger.shared.record(
                    QAuditRecord(
                        sessionId: sessionId,
                        taskId: task.taskId,
                        tool: "agent.completed",
                        riskLevel: .level0ReadOnly,
                        rawArguments: "taskId=\(task.taskId)",
                        authorizationResult: "complete",
                        provenance: goalEvaluation.provenance,
                        executionSummary: finalSummary
                    )
                )

                return task
            }

            // Case B: Security Blocked -> Fail immediately without replan
            if goalEvaluation.isBlocked || executedPlan.state.isBlocked {
                let blockReason: String
                if case .blocked(let r, _) = executedPlan.state {
                    blockReason = r
                } else {
                    blockReason = goalEvaluation.explanation
                }
                QAuditLogger.shared.record(
                    QAuditRecord(
                        sessionId: sessionId,
                        taskId: task.taskId,
                        tool: "agent.blocked",
                        riskLevel: .level4Blocked,
                        rawArguments: "goal=\(prompt)",
                        authorizationResult: "deny",
                        provenance: goalEvaluation.provenance,
                        executionSummary: "Task blocked by security boundary: \(blockReason)"
                    )
                )

                task.state = .failed(reason: "Security Guard Denied: \(blockReason)")
                updateTask(task)
                return task
            }

            // Case C: Goal Unsatisfied / Partial -> Consult Replan Controller
            let replanDecision = replanController.evaluateReplan(
                goal: prompt,
                currentPlan: executedPlan,
                evaluation: goalEvaluation
            )

            replanController.recordIteration(
                plan: executedPlan,
                evaluation: goalEvaluation,
                replanReason: goalEvaluation.explanation
            )

            switch replanDecision {
            case .allow(let replanReq):
                QAuditLogger.shared.record(
                    QAuditRecord(
                        sessionId: sessionId,
                        taskId: task.taskId,
                        tool: "replan.created",
                        riskLevel: .level0ReadOnly,
                        rawArguments: "attempt=\(replanReq.attemptNumber)/\(replanReq.maxAttempts)",
                        authorizationResult: "allow",
                        provenance: "trusted:system",
                        executionSummary: "Requesting replan from local model."
                    )
                )

                guard let structuredModel = model as? QStructuredModelProvider else {
                    task.state = .failed(reason: "Execution halted: Goal not satisfied and model provider cannot generate structured replans.")
                    updateTask(task)
                    return task
                }

                do {
                    currentPlan = try await structuredModel.generateStructuredPlan(
                        for: task,
                        memoryContext: memoryContext,
                        failureContext: replanReq.sanitizedPrompt
                    )
                    continue
                } catch {
                    task.state = .failed(reason: "Replanning failed: \(error.localizedDescription)")
                    updateTask(task)
                    return task
                }

            case .denied(let denialReason):
                QAuditLogger.shared.record(
                    QAuditRecord(
                        sessionId: sessionId,
                        taskId: task.taskId,
                        tool: "goal.unsatisfied",
                        riskLevel: .level0ReadOnly,
                        rawArguments: "denial=\(denialReason)",
                        authorizationResult: "halt",
                        provenance: goalEvaluation.provenance,
                        executionSummary: "Goal unsatisfied and replanning halted: \(denialReason)"
                    )
                )

                QAuditLogger.shared.record(
                    QAuditRecord(
                        sessionId: sessionId,
                        taskId: task.taskId,
                        tool: "agent.failed",
                        riskLevel: .level0ReadOnly,
                        rawArguments: "taskId=\(task.taskId)",
                        authorizationResult: "halt",
                        provenance: goalEvaluation.provenance,
                        executionSummary: "Agent execution terminated unsatisfied: \(denialReason)"
                    )
                )

                let finalFailureSummary: String
                if let structuredModel = model as? QStructuredModelProvider {
                    finalFailureSummary = (try? await structuredModel.generateGroundedSummary(
                        for: task,
                        verifiedEvidence: goalEvaluation.evidence,
                        isSuccess: false
                    )) ?? "Task halted: \(goalEvaluation.explanation) (Replan stopped: \(denialReason))"
                } else {
                    finalFailureSummary = "Task halted: \(goalEvaluation.explanation) (Replan stopped: \(denialReason))"
                }

                task.state = .failed(reason: finalFailureSummary)
                updateTask(task)
                try? await memoryProvider?.recordTaskCompletion(task, result: "Failed: \(denialReason)")
                return task
            }
        }
    }

    private func updateTask(_ task: QTask) {
        lock.lock()
        defer { lock.unlock() }
        var updated = task
        updated.updatedAt = Date()
        tasks[task.taskId] = updated
    }

    public func getTask(taskId: String) -> QTask? {
        lock.lock()
        defer { lock.unlock() }
        return tasks[taskId]
    }
}
