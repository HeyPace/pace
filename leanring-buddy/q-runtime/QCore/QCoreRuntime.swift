//
//  QCoreRuntime.swift
//  leanring-buddy
//
//  Q Security Architecture — Core Runtime Orchestrator (Phase 1D.4 & Phase 2B).
//  Orchestrates memory retrieval, structured multi-step planning, sequential QPlanExecutor
//  execution, controlled replanning on failure, and grounded local summary generation.
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

    // MARK: - Task Orchestration Lifecycle (Phase 2B)

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
                executionSummary: "Accepted user intent"
            )
        )

        // 3. Memory store task start
        try? await memoryProvider?.recordTaskStart(task)

        guard let model = modelProvider else {
            task.state = .failed(reason: "No active Model Provider configured in QCoreRuntime.")
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

        // 5. Generate Structured Plan (Phase 2B.A & 2B.B)
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

        guard let exec = executionProvider else {
            task.state = .failed(reason: "No Execution Provider configured.")
            updateTask(task)
            return task
        }

        // 6. Sequential Plan Execution with Controlled Replanning (Phase 2B.F)
        let executor = QPlanExecutor(executionProvider: exec)
        var replanCount = 0
        let maxReplans = 2
        var executedPlan: QPlan

        while true {
            executedPlan = try await executor.execute(
                plan: currentPlan,
                context: task.context,
                observer: observer
            )

            if executedPlan.isComplete {
                break
            }

            if executedPlan.state.isBlocked {
                break
            }

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

            // Controlled Replanning on Failure
            if case .failed(let failureReason, let failedIdx) = executedPlan.state {
                if replanCount < maxReplans, let structuredModel = model as? QStructuredModelProvider {
                    replanCount += 1
                    let failedStepDesc = (failedIdx != nil && failedIdx! < executedPlan.steps.count) ? executedPlan.steps[failedIdx!].description : "Step \(failedIdx ?? 0)"
                    let failurePrompt = "Prior step failed: '\(failedStepDesc)' - Reason: \(failureReason). Attempting replan \(replanCount)/\(maxReplans)."

                    do {
                        currentPlan = try await structuredModel.generateStructuredPlan(
                            for: task,
                            memoryContext: memoryContext,
                            failureContext: failurePrompt
                        )
                        continue
                    } catch {
                        break
                    }
                } else {
                    break
                }
            }
            break
        }

        // 7. Grounded Natural Language Response Generation (Phase 2B.G)
        if executedPlan.isComplete {
            let evidence = executedPlan.steps.compactMap { $0.result?.verifiedEvidence }
            let finalSummary: String
            if let structuredModel = model as? QStructuredModelProvider {
                finalSummary = (try? await structuredModel.generateGroundedSummary(
                    for: task,
                    verifiedEvidence: evidence,
                    isSuccess: true
                )) ?? (evidence.isEmpty ? "Successfully executed \(task.intent)." : "Successfully executed \(task.intent). \(evidence.joined(separator: "; "))")
            } else {
                finalSummary = evidence.isEmpty ? "Successfully executed \(task.intent)." : "Successfully executed \(task.intent). \(evidence.joined(separator: "; "))"
            }

            task.state = .completed(summary: finalSummary)
            updateTask(task)
            try? await memoryProvider?.recordTaskCompletion(task, result: finalSummary)
            return task
        } else if case .blocked(let reason, _) = executedPlan.state {
            task.state = .failed(reason: "Security Guard blocked action: \(reason)")
            updateTask(task)
            return task
        } else if case .failed(let reason, _) = executedPlan.state {
            task.state = .failed(reason: "Execution halted: \(reason)")
            updateTask(task)
            return task
        } else {
            task.state = .failed(reason: "Task execution halted unexpectedly")
            updateTask(task)
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
