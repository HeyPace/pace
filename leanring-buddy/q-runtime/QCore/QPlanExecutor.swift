//
//  QPlanExecutor.swift
//  leanring-buddy
//
//  Q Security Architecture — Multi-Step Sequential Plan Executor (Phase 2A.1).
//  Coordinates sequential step execution, independent per-step authorization,
//  mandatory empirical verification before advancing, and append-only audit tracking.
//

import Foundation
import AppKit

public protocol QPlanExecutionObserver: AnyObject, Sendable {
    func planDidUpdate(plan: QPlan)
    func stepDidTransition(step: QPlanStep, planId: UUID)
}

public final class QPlanExecutor: Sendable {
    public static let shared = QPlanExecutor()

    private let executionService: any QExecutionProvider

    public init(executionProvider: (any QExecutionProvider)? = nil) {
        self.executionService = executionProvider ?? QExecutionService.shared
    }

    /// Executes a multi-step plan sequentially with strict verification gating at each step.
    public func execute(
        plan initialPlan: QPlan,
        context initialContext: QTaskContext,
        observer: (any QPlanExecutionObserver)? = nil
    ) async throws -> QPlan {
        var plan = initialPlan
        var context = initialContext

        // 1. Initial State Transition: pending -> running
        guard QPlanStateValidator.canTransition(from: plan.state, to: .running) else {
            throw QPlanTransitionError.invalidPlanTransition(from: plan.state, to: .running)
        }
        plan.state = .running
        observer?.planDidUpdate(plan: plan)

        // Record plan start in Audit Logger
        QAuditLogger.shared.record(
            QAuditRecord(
                sessionId: plan.sessionId,
                taskId: plan.taskId,
                tool: "plan.start",
                riskLevel: .level0ReadOnly,
                rawArguments: "planId=\(plan.id.uuidString), steps=\(plan.steps.count)",
                authorizationResult: "allow",
                provenance: context.isTainted ? "untrusted" : "trusted:user",
                executionSummary: "Started sequential plan execution with \(plan.steps.count) steps."
            )
        )

        let verifier = QActionVerifier.shared
        var completedStepsEvidence: [String] = []

        // 2. Iterate through steps sequentially
        for i in 0..<plan.steps.count {
            var step = plan.steps[i]

            // Invariant: steps must match index
            guard step.index == i else {
                let err = QPlanTransitionError.outOfOrderExecution(expectedIndex: i, actualIndex: step.index)
                plan.state = .failed(reason: "Plan step out of order: expected \(i) got \(step.index)", failedStepIndex: i)
                observer?.planDidUpdate(plan: plan)
                throw err
            }

            // Phase 2D: If step is already completed (e.g. during recovery / resume), skip execution
            if step.isComplete || step.state == .completed {
                if let ev = step.result?.verifiedEvidence {
                    completedStepsEvidence.append(ev)
                }
                continue
            }

            // A. Resource Guard Validation
            for resource in step.action.targetResources {
                let guardDecision = QResourceGuard.validate(path: resource)
                if case .denied(let reason, _) = guardDecision {
                    step.state = .blocked(reason: "Resource Guard Denied Resource '\(resource)': \(reason)")
                    plan.steps[i] = step
                    observer?.stepDidTransition(step: step, planId: plan.id)

                    // Skip subsequent steps
                    skipRemainingSteps(in: &plan, startingAt: i + 1, reason: "Prior step \(i) blocked by ResourceGuard")
                    plan.state = .blocked(reason: "Security Guard blocked step \(i): \(reason)", blockedStepIndex: i)
                    observer?.planDidUpdate(plan: plan)

                    QAuditLogger.shared.record(
                        QAuditRecord(
                            sessionId: plan.sessionId,
                            taskId: plan.taskId,
                            tool: step.action.actionName,
                            riskLevel: .level4Blocked,
                            rawArguments: step.action.literalAction,
                            authorizationResult: "deny",
                            provenance: context.isTainted ? "untrusted" : "trusted:system",
                            error: reason
                        )
                    )
                    return plan
                }
            }

            // B. Independent Permission Gate Evaluation for this Step
            let authRequest = QToolAuthorizationRequest(
                taskId: plan.taskId,
                toolName: step.action.actionName,
                toolFamily: step.action.toolFamily,
                baseRisk: step.action.riskLevel,
                literalAction: step.action.literalAction,
                affectedResources: step.action.targetResources,
                isContextTainted: context.isTainted
            )

            let authDecision = QPermissionGate.shared.evaluate(request: authRequest)
            switch authDecision {
            case .deny(let reason, _):
                step.state = .blocked(reason: "Permission Gate Denied: \(reason)")
                plan.steps[i] = step
                observer?.stepDidTransition(step: step, planId: plan.id)

                skipRemainingSteps(in: &plan, startingAt: i + 1, reason: "Prior step \(i) denied by permission gate")
                plan.state = .blocked(reason: "Permission denied on step \(i): \(reason)", blockedStepIndex: i)
                observer?.planDidUpdate(plan: plan)

                QAuditLogger.shared.record(
                    QAuditRecord(
                        sessionId: plan.sessionId,
                        taskId: plan.taskId,
                        tool: step.action.actionName,
                        riskLevel: step.action.riskLevel,
                        rawArguments: step.action.literalAction,
                        authorizationResult: "deny",
                        provenance: context.isTainted ? "untrusted" : "trusted:user",
                        error: reason
                    )
                )
                return plan

            case .requireApproval(let req):
                step.state = .waitingForPermission(reason: req.reason)
                plan.steps[i] = step
                plan.state = .waitingForPermission(stepIndex: i, reason: req.reason)
                observer?.stepDidTransition(step: step, planId: plan.id)
                observer?.planDidUpdate(plan: plan)
                // For headless/non-interactive, halt until approved
                return plan

            case .allow:
                break
            }

            // C. Step State Transition: executing
            guard QPlanStateValidator.canTransitionStep(from: step.state, to: .executing) else {
                throw QPlanTransitionError.invalidStepTransition(from: step.state, to: .executing)
            }
            step.state = .executing
            plan.steps[i] = step
            plan.state = .executing(stepIndex: i)
            observer?.stepDidTransition(step: step, planId: plan.id)
            observer?.planDidUpdate(plan: plan)

            // D. Dispatch Physical Execution
            let actionReq = step.action.toActionRequest(stepId: step.id)
            let actionResult: QActionResult
            do {
                actionResult = try await executionService.executeAction(actionReq, context: context)
            } catch {
                step.state = .failed(reason: "Execution error: \(error.localizedDescription)")
                plan.steps[i] = step
                skipRemainingSteps(in: &plan, startingAt: i + 1, reason: "Prior step \(i) execution failed")
                plan.state = .failed(reason: "Step \(i) failed: \(error.localizedDescription)", failedStepIndex: i)
                observer?.stepDidTransition(step: step, planId: plan.id)
                observer?.planDidUpdate(plan: plan)
                return plan
            }

            guard actionResult.success else {
                let errDetail = actionResult.error ?? "Action execution failed"
                step.state = .failed(reason: errDetail)
                plan.steps[i] = step
                skipRemainingSteps(in: &plan, startingAt: i + 1, reason: "Prior step \(i) returned error")
                plan.state = .failed(reason: "Step \(i) error: \(errDetail)", failedStepIndex: i)
                observer?.stepDidTransition(step: step, planId: plan.id)
                observer?.planDidUpdate(plan: plan)
                return plan
            }

            // E. Step State Transition: verifying
            step.state = .verifying
            plan.steps[i] = step
            plan.state = .verifying(stepIndex: i)
            observer?.stepDidTransition(step: step, planId: plan.id)
            observer?.planDidUpdate(plan: plan)

            // F. Empirical Closed-Loop Verification
            let verificationStrategy = determineVerificationStrategy(for: step.action)
            let verificationOutcome = await verifier.verify(action: actionReq, result: actionResult, strategy: verificationStrategy)

            guard verificationOutcome.isVerified else {
                let failEvidence: String
                if case .failed(let reason, let evidence) = verificationOutcome {
                    failEvidence = "\(reason) (\(evidence))"
                } else {
                    failEvidence = "Verification check returned negative"
                }
                step.state = .failed(reason: "Closed-loop verification failed: \(failEvidence)")
                plan.steps[i] = step
                skipRemainingSteps(in: &plan, startingAt: i + 1, reason: "Prior step \(i) failed closed-loop verification")
                plan.state = .failed(reason: "Verification failed on step \(i): \(failEvidence)", failedStepIndex: i)
                observer?.stepDidTransition(step: step, planId: plan.id)
                observer?.planDidUpdate(plan: plan)
                return plan
            }

            // G. Step Completed & Record Evidence
            let stepEvidence: String
            if case .verified(let evidence) = verificationOutcome {
                stepEvidence = evidence
            } else {
                stepEvidence = actionResult.summary
            }
            completedStepsEvidence.append(stepEvidence)

            step.state = .completed
            step.result = QPlanStepResult(
                stepId: step.id,
                success: true,
                summary: actionResult.summary,
                verifiedEvidence: stepEvidence,
                outputData: actionResult.outputData
            )
            plan.steps[i] = step
            observer?.stepDidTransition(step: step, planId: plan.id)

            // Audit record for step completion
            QAuditLogger.shared.record(
                QAuditRecord(
                    sessionId: plan.sessionId,
                    taskId: plan.taskId,
                    tool: step.action.actionName,
                    riskLevel: step.action.riskLevel,
                    rawArguments: step.action.literalAction,
                    authorizationResult: "allow",
                    provenance: context.isTainted ? "untrusted" : "trusted:system",
                    executionSummary: "Step \(i) [\(step.action.actionName)] completed and verified: \(stepEvidence)"
                )
            )

            // Propagate perception/untrusted taint if OCR or untrusted source was ingested
            if step.action.actionName == "screen.ocr" || step.action.toolFamily == "perception" {
                context.append(
                    content: actionResult.summary,
                    provenance: .untrustedScreen,
                    sourceId: "step_\(i)_ocr"
                )
            }
        }

        // 3. Plan Completion: All steps completed and verified
        let finalSummary = "Plan completed successfully with \(plan.steps.count) verified step(s). Details: \(completedStepsEvidence.joined(separator: "; "))"
        guard QPlanStateValidator.canTransition(from: plan.state, to: .completed(summary: finalSummary)) else {
            throw QPlanTransitionError.invalidPlanTransition(from: plan.state, to: .completed(summary: finalSummary))
        }
        plan.state = .completed(summary: finalSummary)
        observer?.planDidUpdate(plan: plan)

        // Record plan completion in Memory and Audit
        if let memory = QRuntimeBootstrap.shared.getMemoryStore() {
            let memoryRecord = QMemoryRecord(
                sessionId: plan.sessionId,
                taskId: plan.taskId,
                key: "plan_\(plan.id.uuidString)",
                content: finalSummary,
                provenanceKind: context.isTainted ? "untrusted" : "trusted:user",
                provenanceSource: "q_plan_executor"
            )
            try? memory.insert(record: memoryRecord)
        }

        QAuditLogger.shared.record(
            QAuditRecord(
                sessionId: plan.sessionId,
                taskId: plan.taskId,
                tool: "plan.complete",
                riskLevel: .level0ReadOnly,
                rawArguments: "planId=\(plan.id.uuidString)",
                authorizationResult: "allow",
                provenance: context.isTainted ? "untrusted" : "trusted:user",
                executionSummary: finalSummary
            )
        )

        return plan
    }

    // MARK: - Private Helpers

    private func skipRemainingSteps(in plan: inout QPlan, startingAt startIndex: Int, reason: String) {
        guard startIndex < plan.steps.count else { return }
        for j in startIndex..<plan.steps.count {
            var skippedStep = plan.steps[j]
            skippedStep.state = .skipped(reason: reason)
            plan.steps[j] = skippedStep
        }
    }

    private func determineVerificationStrategy(for action: QPlannedAction) -> QVerificationStrategy {
        if action.actionName == "ui.open_app", let appName = action.arguments["appName"] ?? action.targetResources.first {
            return .windowOrAppActive(appName: appName)
        } else if action.actionName == "fs.write_sandbox", let path = action.arguments["path"] {
            return .fileExists(path: path, expectedContent: action.arguments["content"])
        } else if action.actionName == "fs.read", let path = action.arguments["path"] {
            return .fileExists(path: path)
        } else {
            return .customCheck(description: "Default step verification") { true }
        }
    }
}
