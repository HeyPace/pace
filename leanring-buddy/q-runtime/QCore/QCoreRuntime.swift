//
//  QCoreRuntime.swift
//  leanring-buddy
//
//  Q Security Architecture — Core Runtime Orchestrator (Phase 1D.4, 2B, 2C & Phase 2D).
//  Orchestrates memory retrieval, structured multi-step planning, sequential QPlanExecutor
//  execution, empirical closed-loop goal evaluation (QGoalEvaluator), loop-detecting controlled
//  replanning (QReplanController), durable state persistence (QDurableTaskStore), budget bounds
//  (QAgentBudget), and crash recovery & resume (QTaskRecoveryManager).
//

import Foundation

public final class QCoreRuntime: @unchecked Sendable {
    public static let shared = QCoreRuntime()

    private let lock = NSRecursiveLock()
    private var modelProvider: QModelProvider?
    private var memoryProvider: QMemoryProvider?
    private var executionProvider: QExecutionProvider?
    private var durableStore: (any QDurableTaskStoreProtocol)?
    private let ipcChannel: QIPCChannel
    private var tasks: [String: QTask] = [:]

    public init(
        modelProvider: QModelProvider? = nil,
        memoryProvider: QMemoryProvider? = nil,
        executionProvider: QExecutionProvider? = nil,
        durableStore: (any QDurableTaskStoreProtocol)? = nil,
        endpointName: String = "q-core-\(UUID().uuidString.prefix(8))"
    ) {
        self.modelProvider = modelProvider
        self.memoryProvider = memoryProvider
        self.executionProvider = executionProvider
        self.durableStore = durableStore ?? QDurableTaskStore.shared
        self.ipcChannel = QIPCChannel(endpointName: endpointName)
        setupIPCHandlers()
    }

    public func configure(
        modelProvider: QModelProvider? = nil,
        memoryProvider: QMemoryProvider? = nil,
        executionProvider: QExecutionProvider? = nil,
        durableStore: (any QDurableTaskStoreProtocol)? = nil
    ) {
        lock.lock()
        defer { lock.unlock() }
        if let modelProvider { self.modelProvider = modelProvider }
        if let memoryProvider { self.memoryProvider = memoryProvider }
        if let executionProvider { self.executionProvider = executionProvider }
        if let durableStore { self.durableStore = durableStore }
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

    // MARK: - Autonomous Closed-Loop Task Lifecycle (Phase 2C & 2D)

    public func submitIntent(
        prompt: String,
        sessionId: String = UUID().uuidString,
        observer: (any QPlanExecutionObserver)? = nil
    ) async throws -> QTask {
        // 1. Create task and initialize trusted context
        var task = QTask(sessionId: sessionId, intent: prompt)
        task.context.append(content: prompt, provenance: .trustedUser(channel: "direct"), sourceId: "user_prompt")

        var budget = QAgentBudget()

        lock.lock()
        tasks[task.taskId] = task
        lock.unlock()

        // 2. Audit Intent submission and persist durable lifecycle event
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

        var durableState = QDurableTaskState(from: task, budget: budget)
        try? durableStore?.saveTask(durableState)
        try? durableStore?.recordEvent(
            QTaskLifecycleEvent(
                taskId: task.taskId,
                sessionId: sessionId,
                eventType: .taskCreated,
                payload: ["intent": prompt]
            )
        )

        // 3. Memory store task start
        try? await memoryProvider?.recordTaskStart(task)

        guard let model = modelProvider else {
            task.state = .failed(reason: "No active Model Provider configured in QCoreRuntime.")
            updateTask(task)
            durableState.lifecycleState = .failed
            durableState.lastKnownError = "No active Model Provider configured."
            try? durableStore?.saveTask(durableState)
            try? durableStore?.recordEvent(
                QTaskLifecycleEvent(taskId: task.taskId, sessionId: sessionId, eventType: .taskFailed, payload: ["reason": "No active Model Provider configured"])
            )
            return task
        }

        guard let exec = executionProvider else {
            task.state = .failed(reason: "No Execution Provider configured.")
            updateTask(task)
            durableState.lifecycleState = .failed
            durableState.lastKnownError = "No Execution Provider configured."
            try? durableStore?.saveTask(durableState)
            try? durableStore?.recordEvent(
                QTaskLifecycleEvent(taskId: task.taskId, sessionId: sessionId, eventType: .taskFailed, payload: ["reason": "No Execution Provider configured"])
            )
            return task
        }

        task.state = .running
        updateTask(task)
        durableState.lifecycleState = .running
        try? durableStore?.saveTask(durableState)

        // 4. Memory-Aware Context Retrieval (Phase 2B.E)
        var memoryContext: String? = nil
        if let mem = memoryProvider, let contexts = try? await mem.queryContext(for: prompt, limit: 5), !contexts.isEmpty {
            memoryContext = contexts.joined(separator: "\n")
        }

        // 5. Generate Initial Structured Plan
        var currentPlan: QPlan
        budget.recordModelCall()
        durableState.budget = budget

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
            durableState.lifecycleState = .failed
            durableState.lastKnownError = "Planning failed: \(error.localizedDescription)"
            try? durableStore?.saveTask(durableState)
            try? durableStore?.recordEvent(
                QTaskLifecycleEvent(taskId: task.taskId, sessionId: sessionId, eventType: .taskFailed, payload: ["error": error.localizedDescription])
            )
            return task
        }

        let planSnapshot = QDurablePlanSnapshot(from: currentPlan)
        durableState.currentPlanId = planSnapshot.planId
        try? durableStore?.savePlan(planSnapshot)
        try? durableStore?.saveTask(durableState)
        try? durableStore?.recordEvent(
            QTaskLifecycleEvent(
                taskId: task.taskId,
                sessionId: sessionId,
                eventType: .taskPlanned,
                payload: ["planId": planSnapshot.planId, "steps": "\(currentPlan.steps.count)"]
            )
        )

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

        // 6. Autonomous Closed-Loop Execution, Goal Evaluation & Controlled Replanning (Phase 2C & 2D)
        let executor = QPlanExecutor(executionProvider: exec)
        let goalEvaluator = QGoalEvaluator.shared
        let replanController = QReplanController(maxReplans: budget.maxReplans)

        while true {
            // Check budget before execution iteration
            if case .exhausted(let reason, let explanation) = budget.evaluateBudget() {
                task.state = .failed(reason: "Execution halted: \(explanation)")
                updateTask(task)
                durableState.lifecycleState = .failed
                durableState.lastKnownError = explanation
                durableState.budget = budget
                try? durableStore?.saveTask(durableState)
                try? durableStore?.recordEvent(
                    QTaskLifecycleEvent(taskId: task.taskId, sessionId: sessionId, eventType: .taskFailed, payload: ["budgetExhaustion": reason.rawValue])
                )
                return task
            }

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

            try? durableStore?.recordEvent(
                QTaskLifecycleEvent(
                    taskId: task.taskId,
                    sessionId: sessionId,
                    eventType: .stepStarted,
                    payload: ["planId": currentPlan.id.uuidString]
                )
            )

            let executedPlan = try await executor.execute(
                plan: currentPlan,
                context: task.context,
                observer: observer
            )

            // Record executed step budget & lifecycle events
            for step in executedPlan.steps {
                budget.recordStepExecution(success: step.isComplete || step.state == .completed)
                if step.isComplete || step.state == .completed {
                    if !durableState.completedStepIds.contains(step.id.uuidString) {
                        durableState.completedStepIds.append(step.id.uuidString)
                    }
                    try? durableStore?.recordEvent(
                        QTaskLifecycleEvent(
                            taskId: task.taskId,
                            sessionId: sessionId,
                            eventType: .stepCompleted,
                            payload: ["stepIndex": "\(step.index)", "actionName": step.action.actionName]
                        )
                    )
                } else if step.isFailed {
                    if !durableState.failedStepIds.contains(step.id.uuidString) {
                        durableState.failedStepIds.append(step.id.uuidString)
                    }
                    try? durableStore?.recordEvent(
                        QTaskLifecycleEvent(
                            taskId: task.taskId,
                            sessionId: sessionId,
                            eventType: .stepFailed,
                            payload: ["stepIndex": "\(step.index)", "actionName": step.action.actionName]
                        )
                    )
                }
            }

            durableState.budget = budget
            let updatedSnapshot = QDurablePlanSnapshot(from: executedPlan)
            try? durableStore?.savePlan(updatedSnapshot)
            try? durableStore?.saveTask(durableState)

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
                durableState.lifecycleState = .awaitingApproval
                durableState.securityBlockReason = reason
                try? durableStore?.saveTask(durableState)
                try? durableStore?.recordEvent(
                    QTaskLifecycleEvent(
                        taskId: task.taskId,
                        sessionId: sessionId,
                        eventType: .permissionRequested,
                        payload: ["tool": step.action.actionName, "reason": reason]
                    )
                )
                return task
            }

            // 7. Evidence-First Goal Evaluation
            let goalEvaluation = goalEvaluator.evaluate(
                goal: prompt,
                plan: executedPlan,
                context: task.context
            )

            durableState.goalEvaluationState = goalEvaluation.state.rawValue
            durableState.verificationEvidenceReferences = goalEvaluation.evidence
            try? durableStore?.saveTask(durableState)
            try? durableStore?.recordEvent(
                QTaskLifecycleEvent(
                    taskId: task.taskId,
                    sessionId: sessionId,
                    eventType: .goalEvaluated,
                    payload: ["state": goalEvaluation.state.rawValue, "confidence": "\(goalEvaluation.confidence)"]
                )
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
                durableState.lifecycleState = .completed
                durableState.lastUpdatedTimestamp = Date()
                try? durableStore?.saveTask(durableState)
                try? durableStore?.recordEvent(
                    QTaskLifecycleEvent(
                        taskId: task.taskId,
                        sessionId: sessionId,
                        eventType: .taskCompleted,
                        payload: ["summary": finalSummary]
                    )
                )

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
                durableState.lifecycleState = .blocked
                durableState.securityBlockReason = blockReason
                try? durableStore?.saveTask(durableState)
                try? durableStore?.recordEvent(
                    QTaskLifecycleEvent(
                        taskId: task.taskId,
                        sessionId: sessionId,
                        eventType: .securityBlocked,
                        payload: ["reason": blockReason]
                    )
                )
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
                budget.recordReplan()
                budget.recordModelCall()
                durableState.replanAttemptCount = replanReq.attemptNumber
                durableState.budget = budget
                try? durableStore?.saveTask(durableState)
                try? durableStore?.recordEvent(
                    QTaskLifecycleEvent(
                        taskId: task.taskId,
                        sessionId: sessionId,
                        eventType: .replanRequested,
                        payload: ["attempt": "\(replanReq.attemptNumber)", "max": "\(replanReq.maxAttempts)"]
                    )
                )

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
                    durableState.lifecycleState = .failed
                    durableState.lastKnownError = "Model cannot generate structured replans"
                    try? durableStore?.saveTask(durableState)
                    return task
                }

                do {
                    currentPlan = try await structuredModel.generateStructuredPlan(
                        for: task,
                        memoryContext: memoryContext,
                        failureContext: replanReq.sanitizedPrompt
                    )
                    let newSnapshot = QDurablePlanSnapshot(from: currentPlan)
                    durableState.currentPlanId = newSnapshot.planId
                    try? durableStore?.savePlan(newSnapshot)
                    try? durableStore?.saveTask(durableState)
                    try? durableStore?.recordEvent(
                        QTaskLifecycleEvent(
                            taskId: task.taskId,
                            sessionId: sessionId,
                            eventType: .replanCreated,
                            payload: ["newPlanId": newSnapshot.planId, "steps": "\(currentPlan.steps.count)"]
                        )
                    )
                    continue
                } catch {
                    task.state = .failed(reason: "Replanning failed: \(error.localizedDescription)")
                    updateTask(task)
                    durableState.lifecycleState = .failed
                    durableState.lastKnownError = error.localizedDescription
                    try? durableStore?.saveTask(durableState)
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
                durableState.lifecycleState = .failed
                durableState.lastKnownError = finalFailureSummary
                try? durableStore?.saveTask(durableState)
                try? durableStore?.recordEvent(
                    QTaskLifecycleEvent(
                        taskId: task.taskId,
                        sessionId: sessionId,
                        eventType: .taskFailed,
                        payload: ["reason": finalFailureSummary]
                    )
                )
                try? await memoryProvider?.recordTaskCompletion(task, result: "Failed: \(denialReason)")
                return task
            }
        }
    }

    // MARK: - Recovery & Resume (Phase 2D)

    public func resumeTask(
        taskId: String,
        observer: (any QPlanExecutionObserver)? = nil
    ) async throws -> QTask {
        let recoveryManager = QTaskRecoveryManager(store: durableStore ?? QDurableTaskStore.shared)
        let recoveryDecision = try await recoveryManager.evaluateTaskRecovery(taskId: taskId)

        switch recoveryDecision {
        case .completed(let taskState):
            return taskState.toTask()

        case .failed(let taskState, _):
            return taskState.toTask()

        case .securityBlocked(let taskState, _):
            return taskState.toTask()

        case .corrupted(let id, let reason):
            var task = QTask(taskId: id, sessionId: "recovery", intent: "Corrupted Task")
            task.state = .failed(reason: "Task corrupted: \(reason)")
            return task

        case .notFound:
            var task = QTask(taskId: taskId, sessionId: "recovery", intent: "Not Found")
            task.state = .failed(reason: "Task \(taskId) not found in durable storage")
            return task

        case .needsPermission(let taskState, _, _, let reason):
            var task = taskState.toTask()
            task.state = .awaitingApproval(
                QApprovalRequest(
                    taskId: taskId,
                    toolName: "recovered.permission",
                    riskLevel: .level2UserApproval,
                    literalAction: "Recovered action awaiting user permission",
                    affectedResources: [],
                    scope: .global,
                    reason: reason,
                    isContextTainted: taskState.provenance.contains("untrusted")
                )
            )
            updateTask(task)
            return task

        case .needsVerification(let taskState, let planSnapshot, let stepIdx, let uncertainStep):
            let resolution = try await recoveryManager.resolveUncertainStep(
                task: taskState,
                plan: planSnapshot,
                stepIndex: stepIdx,
                uncertainStep: uncertainStep
            )
            return try await executeResumedPlan(
                taskState: resolution.updatedTask,
                planSnapshot: resolution.updatedPlan,
                observer: observer
            )

        case .recoverable(let taskState, let planSnapshot):
            return try await executeResumedPlan(
                taskState: taskState,
                planSnapshot: planSnapshot,
                observer: observer
            )
        }
    }

    private func executeResumedPlan(
        taskState: QDurableTaskState,
        planSnapshot: QDurablePlanSnapshot,
        observer: (any QPlanExecutionObserver)? = nil
    ) async throws -> QTask {
        var task = taskState.toTask()
        task.state = .running
        updateTask(task)

        guard let exec = executionProvider else {
            task.state = .failed(reason: "No Execution Provider configured for recovery execution.")
            updateTask(task)
            return task
        }

        let plan = try planSnapshot.validate()
        let executor = QPlanExecutor(executionProvider: exec)
        let goalEvaluator = QGoalEvaluator.shared

        // If all steps in the plan are already complete, evaluate goal
        let executedPlan: QPlan
        let pendingSteps = plan.steps.filter { !$0.isComplete && $0.state != .completed }
        if pendingSteps.isEmpty {
            executedPlan = plan
        } else {
            executedPlan = try await executor.execute(
                plan: plan,
                context: task.context,
                observer: observer
            )
        }

        let goalEval = goalEvaluator.evaluate(
            goal: taskState.originalIntent,
            plan: executedPlan,
            context: task.context
        )

        if goalEval.isSatisfied {
            let summary = goalEval.evidence.isEmpty ? "Successfully recovered and completed \(task.intent)." : "Successfully recovered and completed \(task.intent). \(goalEval.evidence.joined(separator: "; "))"
            task.state = .completed(summary: summary)
            updateTask(task)

            var updatedDurable = taskState
            updatedDurable.lifecycleState = .completed
            updatedDurable.goalEvaluationState = "satisfied"
            try? durableStore?.saveTask(updatedDurable)
            try? durableStore?.recordEvent(
                QTaskLifecycleEvent(taskId: task.taskId, sessionId: task.sessionId, eventType: .taskCompleted, payload: ["summary": summary, "resumed": "true"])
            )
            return task
        } else {
            let failureMsg = "Recovered plan unsatisfied: \(goalEval.explanation)"
            task.state = .failed(reason: failureMsg)
            updateTask(task)

            var updatedDurable = taskState
            updatedDurable.lifecycleState = .failed
            updatedDurable.lastKnownError = failureMsg
            try? durableStore?.saveTask(updatedDurable)
            return task
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
