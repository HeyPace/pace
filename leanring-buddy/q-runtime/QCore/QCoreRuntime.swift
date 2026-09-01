//
//  QCoreRuntime.swift
//  leanring-buddy
//
//  Q Security Architecture — Core Runtime Orchestrator (Phase 1D.4).
//  Orchestrates tasks, evaluates permissions, and coordinates providers without
//  ever executing raw macOS actions directly.
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

    // MARK: - Task Orchestration Lifecycle

    public func submitIntent(prompt: String, sessionId: String = UUID().uuidString) async throws -> QTask {
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

        // 4. Generate plan via Model Provider
        guard let model = modelProvider else {
            task.state = .failed(reason: "No active Model Provider configured in QCoreRuntime.")
            updateTask(task)
            return task
        }

        task.state = .running
        updateTask(task)

        let plan: [QActionRequest]
        do {
            plan = try await model.generatePlan(for: task)
        } catch {
            task.state = .failed(reason: "Planning failed: \(error.localizedDescription)")
            updateTask(task)
            return task
        }

        var actionSummaries: [String] = []
        for action in plan {
            // Resource guard check for filesystem targets
            for res in action.targetResources {
                let guardResult = QResourceGuard.validate(path: res)
                if case .denied(let reason, _) = guardResult {
                    task.state = .failed(reason: "Security Guard Denied Resource '\(res)': \(reason)")
                    updateTask(task)
                    QAuditLogger.shared.record(
                        QAuditRecord(
                            sessionId: sessionId,
                            taskId: task.taskId,
                            tool: action.toolName,
                            riskLevel: .level4Blocked,
                            rawArguments: action.literalAction,
                            authorizationResult: "deny",
                            provenance: task.context.isTainted ? "untrusted" : "trusted:system",
                            error: reason
                        )
                    )
                    return task
                }
            }

            // Centralized Permission Gate evaluation
            let authReq = QToolAuthorizationRequest(
                taskId: task.taskId,
                toolName: action.toolName,
                toolFamily: action.toolFamily,
                baseRisk: action.riskLevel,
                literalAction: action.literalAction,
                affectedResources: action.targetResources,
                isContextTainted: task.context.isTainted
            )

            let decision = QPermissionGate.shared.evaluate(request: authReq)
            if case .deny(let reason, _) = decision {
                task.state = .failed(reason: "Authorization Denied: \(reason)")
                updateTask(task)
                QAuditLogger.shared.record(
                    QAuditRecord(
                        sessionId: sessionId,
                        taskId: task.taskId,
                        tool: action.toolName,
                        riskLevel: action.riskLevel,
                        rawArguments: action.literalAction,
                        authorizationResult: "deny",
                        provenance: task.context.isTainted ? "untrusted" : "trusted:system",
                        error: reason
                    )
                )
                return task
            }

            if case .requireApproval(let approvalReq) = decision {
                task.state = .awaitingApproval(approvalReq)
                updateTask(task)
                // In Phase 1D headless tests, unapproved high-risk actions halt safely
                return task
            }

            // 6. Delegate execution strictly to QExecutionProvider (never executed directly in core)
            guard let exec = executionProvider else {
                task.state = .failed(reason: "No Execution Provider configured.")
                updateTask(task)
                return task
            }

            do {
                let result = try await exec.executeAction(action, context: task.context)
                if !result.success {
                    task.state = .failed(reason: result.error ?? "Action failed")
                    updateTask(task)
                    return task
                }
                actionSummaries.append(result.summary)
            } catch {
                task.state = .failed(reason: "Execution error: \(error.localizedDescription)")
                updateTask(task)
                return task
            }
        }

        // 7. Complete task
        let details = actionSummaries.joined(separator: " ")
        let finalSummary = "Successfully executed \(plan.count) action(s). \(details)".trimmingCharacters(in: .whitespaces)
        task.state = .completed(summary: finalSummary)
        updateTask(task)
        try? await memoryProvider?.recordTaskCompletion(task, result: "Success")

        return task
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
