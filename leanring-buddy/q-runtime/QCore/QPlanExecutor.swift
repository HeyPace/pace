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
            // Every step carries a deterministic execution identity (Phase 2E) so any resulting
            // approval request — and any later grant — is bound to this exact task/plan/step/
            // action attempt and can never authorize a different action.
            let executionIdentity = QExecutionIdentity(
                taskId: plan.taskId,
                planId: plan.id.uuidString,
                stepId: step.id.uuidString,
                attemptId: "step-\(step.id.uuidString)",
                actionName: step.action.actionName,
                targetResources: step.action.targetResources
            )

            // Fast path: resuming after the user already granted a one-time, execution-identity-
            // bound approval for exactly this step (QCoreRuntime.resolveApproval). The grant is
            // consumed here and can never be reused — a second execution attempt of this same
            // step (e.g. a future replan) must go through fresh authorization again.
            var authorizedByPriorGrant = false
            if step.action.riskLevel.requiresExplicitApproval,
               QApprovalCoordinator.shared.consumeGrantIfPresent(fingerprint: executionIdentity.stepFingerprint) {
                authorizedByPriorGrant = true
                QAuditLogger.shared.record(
                    QAuditRecord(
                        sessionId: plan.sessionId,
                        taskId: plan.taskId,
                        tool: step.action.actionName,
                        riskLevel: step.action.riskLevel,
                        rawArguments: step.action.literalAction,
                        authorizationResult: "allow",
                        provenance: context.isTainted ? "untrusted" : "trusted:user",
                        executionSummary: "Executing after explicit user-approved one-time grant (fingerprint=\(executionIdentity.stepFingerprint))."
                    )
                )
            }

            if !authorizedByPriorGrant {
                // Security boundary (Phase 2I remediation): `QToolAuthorizationRequest
                // .literalAction` flows straight into `QApprovalRequest.expectedEffect`
                // (QPermissionGate.evaluate), which the HUD renders verbatim
                // ("Q wants to: \(expectedEffect)" — PaceTurnHUDState.swift). The generic path
                // trusts the model's own free-text step description here, which is fine for
                // targeting metadata (e.g. a click description) but not for a tool whose
                // arguments carry a sensitive literal — the model could describe exactly the
                // text it's about to enter. `approvalSafeLiteralAction` only overrides this for
                // tools `QSensitiveArgumentPolicy` declares sensitive (today: none of the
                // registered/executable capabilities — see QModelPlanParser
                // .registeredCapabilities — so this is a no-op today); every other tool's
                // approval text is byte-for-byte unchanged.
                let approvalSafeLiteralAction = QSensitiveArgumentPolicy.approvalSafeLiteralAction(
                    toolName: step.action.actionName,
                    arguments: step.action.arguments,
                    fallbackLiteralAction: step.action.literalAction
                )
                let authRequest = QToolAuthorizationRequest(
                    taskId: plan.taskId,
                    toolName: step.action.actionName,
                    toolFamily: step.action.toolFamily,
                    baseRisk: step.action.riskLevel,
                    literalAction: approvalSafeLiteralAction,
                    affectedResources: step.action.targetResources,
                    isContextTainted: context.isTainted,
                    executionIdentity: executionIdentity
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
                    QApprovalCoordinator.shared.recordPending(req)
                    step.state = .waitingForPermission(reason: req.reason)
                    plan.steps[i] = step
                    plan.state = .waitingForPermission(stepIndex: i, reason: req.reason)
                    observer?.stepDidTransition(step: step, planId: plan.id)
                    observer?.planDidUpdate(plan: plan)

                    QAuditLogger.shared.record(
                        QAuditRecord(
                            sessionId: plan.sessionId,
                            taskId: plan.taskId,
                            tool: step.action.actionName,
                            riskLevel: step.action.riskLevel,
                            rawArguments: step.action.literalAction,
                            authorizationResult: "approval_required",
                            provenance: context.isTainted ? "untrusted" : "trusted:user",
                            executionSummary: "Halted pending explicit user approval (approvalId=\(req.id.uuidString), fingerprint=\(executionIdentity.stepFingerprint))."
                        )
                    )
                    // For headless/non-interactive, halt until approved via QCoreRuntime.resolveApproval
                    return plan

                case .allow:
                    break
                }
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
            let verificationStrategy = determineVerificationStrategy(for: step.action, result: actionResult)
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
            //
            // Security boundary (Phase 2G remediation): screen/perception-derived action results
            // are untrusted-by-provenance (the same predicate used below to tag context taint) and
            // must never reach anything persisted, logged, or spoken back to the user unredacted —
            // this is where a future real screen.ocr's recognized text would first appear on the
            // result path. QSecretRedactor.redact is the SAME canonical redactor QAuditRecord
            // already applies to executionSummary/error; reusing it here (rather than a second
            // ad-hoc mechanism) closes the one confirmed gap: QAuditRecord never sees this raw
            // string (it logs `stepEvidence`, not `actionResult.summary`, once it's verified), but
            // `QPlanStepResult.summary` — which durable persistence copies verbatim
            // (QDurablePlanStepSnapshot.resultSummary) — previously did.
            //
            // The ORIGINAL, unredacted `actionResult.summary` is still used below for the
            // on-device-only taint propagation into QTaskContext: that value never leaves the
            // device, is never logged or persisted, and the local planner needs the real content
            // to reason about the screen — redacting it there would break the feature for no
            // privacy benefit. Sanitization here also does not change provenance/taint: the
            // sanitized value is still fed into evidence/goal-evaluation/spoken-summary paths that
            // already carry (or, for a tainted task, already are marked with) untrusted provenance
            // — redaction only removes matched secret-shaped substrings, it never marks content as
            // trusted and is never itself treated as an authorization signal.
            let isScreenDerivedStep = step.action.actionName == "screen.ocr" || step.action.toolFamily == "perception"
            let sanitizedResultSummary = isScreenDerivedStep
                ? QSecretRedactor.redact(actionResult.summary)
                : actionResult.summary

            let stepEvidence: String
            if case .verified(let evidence) = verificationOutcome {
                stepEvidence = evidence
            } else {
                stepEvidence = sanitizedResultSummary
            }
            completedStepsEvidence.append(stepEvidence)

            step.state = .completed
            step.result = QPlanStepResult(
                stepId: step.id,
                success: true,
                summary: sanitizedResultSummary,
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

            // Propagate perception/untrusted taint if OCR or untrusted source was ingested.
            // Deliberately uses the RAW (unredacted) actionResult.summary, not
            // sanitizedResultSummary: this value only ever feeds the on-device local planner's own
            // subsequent reasoning (QTaskContext), is never logged, persisted, or spoken back to
            // the user, and the planner needs the real screen content to function correctly.
            // Redacting it here would break the feature with zero privacy benefit, since nothing
            // downstream of QTaskContext.append leaves the device or reaches a logged/durable sink.
            if isScreenDerivedStep {
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
        //
        // Security boundary (Phase 2I remediation): QMemoryStore is a separate, independent
        // durable SQLite store from QDurableTaskStore/QAuditLogger — the confirmed Phase 2I
        // pre-check found it had NO redaction applied at all, unlike every other persistence
        // sink this same `finalSummary` value already flows through (QAuditRecord.executionSummary
        // applies QSecretRedactor.redact internally; QDurablePlanStepSnapshot.resultSummary/
        // verifiedEvidence do the same at construction). Applying the identical canonical
        // redactor here closes that one gap without introducing a second mechanism. This is the
        // same defense-in-depth backstop as those existing call sites, not a general-purpose
        // redactor: QSecretRedactor only strips secret-*shaped* substrings (API keys, PEM blocks,
        // password/token assignments) — it does not, and cannot, generically identify arbitrary
        // sensitive free text. The structural guarantee that a future capability's literal input
        // (e.g. a typed text value) never reaches `finalSummary` in the first place must come
        // from that capability's own executor never placing it in QActionResult.summary/
        // verifiedEvidence — see QSafeTextEntryVerificationEvidence in
        // QTextEntrySecurityContracts.swift and docs/PHASE_2I_TEXT_ENTRY_SECURITY_REMEDIATION.md.
        if let memory = QRuntimeBootstrap.shared.getMemoryStore() {
            let memoryRecord = QMemoryRecord(
                sessionId: plan.sessionId,
                taskId: plan.taskId,
                key: "plan_\(plan.id.uuidString)",
                content: QSecretRedactor.redact(finalSummary),
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

    private func determineVerificationStrategy(for action: QPlannedAction, result: QActionResult) -> QVerificationStrategy {
        if action.actionName == "ui.open_app", let appName = action.arguments["appName"] ?? action.targetResources.first {
            return .windowOrAppActive(appName: appName)
        } else if action.actionName == "fs.write_sandbox", let path = action.arguments["path"] {
            return .fileExists(path: path, expectedContent: action.arguments["content"])
        } else if action.actionName == "fs.read", let path = action.arguments["path"] {
            return .fileExists(path: path)
        } else if action.actionName == "app.quit", let appName = action.arguments["appName"] ?? action.targetResources.first {
            return .appNotRunning(appName: appName)
        } else if action.actionName == "system.clipboard.write", let text = action.arguments["text"] {
            return .customCheck(description: "Clipboard content matches written text") {
                NSPasteboard.general.string(forType: .string) == text
            }
        } else if action.actionName == "ui.click_element",
                  let applicationName = action.arguments["applicationName"],
                  let role = action.arguments["role"] {
            // Reconstructed from the exact arguments used to dispatch, plus the pre-click AX
            // snapshot QExecutionService captured at press time (threaded through outputData) —
            // verification must diff the precise element that was clicked, never a re-derived guess.
            func nonEmpty(_ value: String?) -> String? { value.flatMap { $0.isEmpty ? nil : $0 } }
            let matchIdentifier = nonEmpty(action.arguments["identifier"])
            let matchTitle = nonEmpty(action.arguments["title"])
            let beforeSnapshot = QAXElementSnapshot(
                role: role,
                identifier: nonEmpty(result.outputData["preClickIdentifier"]),
                titleOrDescription: nonEmpty(result.outputData["preClickTitleOrDescription"]),
                isEnabled: result.outputData["preClickEnabled"] == "true"
            )
            return .axElementStateChanged(
                applicationName: applicationName,
                role: role,
                matchIdentifier: matchIdentifier,
                matchTitle: matchTitle,
                beforeSnapshot: beforeSnapshot
            )
        } else if action.actionName == "ui.set_text_value",
                  let applicationName = action.arguments["applicationName"],
                  let role = action.arguments["role"],
                  let targetIdentity = result.outputData["targetIdentity"],
                  let previousLength = result.outputData["previousLength"].flatMap(Int.init),
                  let previousValueHash = result.outputData["previousValueHash"],
                  let intendedValueHash = result.outputData["intendedValueHash"] {
            // Reconstructed from the exact arguments used to dispatch, plus the safe (hash/length
            // only, never plaintext) metadata QExecutionService captured at write time — the
            // independent verification step re-resolves the precise element that was written to
            // and compares only hashes, never the literal value.
            func nonEmpty(_ value: String?) -> String? { value.flatMap { $0.isEmpty ? nil : $0 } }
            return .axTextValueChanged(
                applicationName: applicationName,
                role: role,
                matchIdentifier: nonEmpty(action.arguments["identifier"]),
                matchTitle: nonEmpty(action.arguments["title"]),
                targetIdentity: targetIdentity,
                previousLength: previousLength,
                previousValueHash: previousValueHash,
                intendedValueHash: intendedValueHash
            )
        } else if action.actionName == "ui.set_element_state",
                  let applicationName = action.arguments["applicationName"],
                  let role = action.arguments["role"],
                  let targetIdentity = result.outputData["targetIdentity"],
                  let previousStateHash = result.outputData["previousStateHash"],
                  let desiredStateHash = result.outputData["desiredStateHash"] {
            // Reconstructed from the exact arguments used to dispatch, plus the safe (hash-only,
            // never the raw AX value) metadata QExecutionService captured at state-change time —
            // the independent verification step re-resolves the precise element that was changed
            // and compares only hashes of the small "on"/"off" enum, never a raw AX attribute.
            func nonEmpty(_ value: String?) -> String? { value.flatMap { $0.isEmpty ? nil : $0 } }
            return .axElementStateMatchesDesired(
                applicationName: applicationName,
                role: role,
                matchIdentifier: nonEmpty(action.arguments["identifier"]),
                matchTitle: nonEmpty(action.arguments["title"]),
                targetIdentity: targetIdentity,
                previousStateHash: previousStateHash,
                desiredStateHash: desiredStateHash
            )
        } else if action.actionName == "ui.select_menu_item",
                  let applicationName = action.arguments["applicationName"],
                  let menuBarTitle = action.arguments["menuBarTitle"],
                  let itemTitle = action.arguments["itemTitle"],
                  let targetIdentity = result.outputData["targetIdentity"] {
            // Reconstructed from the exact arguments used to dispatch, plus the safe (non-secret
            // targeting metadata only) outputData QExecutionService captured at selection time —
            // the independent verification step re-resolves the precise menu/item that was
            // selected and evaluates the evidence contract, never fabricating a stronger claim.
            return .axMenuItemSelectionEvidence(
                applicationName: applicationName,
                menuBarTitle: menuBarTitle,
                itemTitle: itemTitle,
                targetIdentity: targetIdentity
            )
        } else if action.actionName == "ui.set_slider_value",
                  let applicationName = action.arguments["applicationName"],
                  let role = action.arguments["role"],
                  let targetIdentity = result.outputData["targetIdentity"],
                  let desiredValueString = action.arguments["desiredValue"],
                  let desiredValue = Double(desiredValueString) {
            // Reconstructed from the exact arguments used to dispatch, plus the safe (plain
            // numeric metadata, never masked — see docs/PHASE_2M_SEMANTIC_SLIDER_VALUE.md)
            // outputData QExecutionService captured at value-change time — the independent
            // verification step re-resolves the precise element that was changed and compares
            // its current value against the desired value directly.
            func nonEmpty(_ value: String?) -> String? { value.flatMap { $0.isEmpty ? nil : $0 } }
            return .axSliderValueMatchesDesired(
                applicationName: applicationName,
                role: role,
                matchIdentifier: nonEmpty(action.arguments["identifier"]),
                matchTitle: nonEmpty(action.arguments["title"]),
                targetIdentity: targetIdentity,
                desiredValue: desiredValue
            )
        } else if action.actionName == "ui.activate_application",
                  let applicationName = action.arguments["applicationName"],
                  let targetProcessIdentifierString = result.outputData["targetProcessIdentifier"],
                  let targetProcessIdentifier = Int32(targetProcessIdentifierString) {
            // Reconstructed from the exact application name used to dispatch, plus the safe
            // (non-secret, stable process identity) outputData QExecutionService captured at
            // resolution time — the independent verification step re-queries
            // NSWorkspace.shared.frontmostApplication itself rather than trusting whatever
            // executeActivateApplication's own bounded poll already observed.
            return .processIsFrontmost(
                applicationName: applicationName,
                targetProcessIdentifier: pid_t(targetProcessIdentifier)
            )
        } else if action.actionName == "ui.focus_element",
                  let applicationName = action.arguments["applicationName"],
                  let role = action.arguments["role"],
                  let targetIdentity = result.outputData["targetIdentity"] {
            // Reconstructed from the exact arguments used to dispatch, plus the safe (non-secret
            // targeting metadata only) outputData QExecutionService captured at focus-change
            // time — the independent verification step re-resolves the precise element that was
            // focused and independently re-reads kAXFocusedUIElementAttribute, never trusting
            // whatever executeFocusElement itself already observed.
            func nonEmpty(_ value: String?) -> String? { value.flatMap { $0.isEmpty ? nil : $0 } }
            return .axElementIsFocused(
                applicationName: applicationName,
                role: role,
                matchIdentifier: nonEmpty(action.arguments["identifier"]),
                matchTitle: nonEmpty(action.arguments["title"]),
                targetIdentity: targetIdentity
            )
        } else if action.actionName == "ui.select_popup_item",
                  let applicationName = action.arguments["applicationName"],
                  let role = action.arguments["role"],
                  let targetIdentity = result.outputData["targetIdentity"],
                  let requestedItemTitle = result.outputData["requestedItemTitle"] {
            // Reconstructed from the exact arguments used to dispatch, plus the safe (plain
            // item-label metadata, never masked — see docs/PHASE_2P_SEMANTIC_POPUP_SELECTION.md)
            // outputData QExecutionService captured at selection time — the independent
            // verification step re-resolves the precise popup that was changed and independently
            // re-reads its own kAXValueAttribute, never trusting whatever executeSelectPopupItem
            // itself already observed.
            func nonEmpty(_ value: String?) -> String? { value.flatMap { $0.isEmpty ? nil : $0 } }
            return .axPopupValueMatchesDesired(
                applicationName: applicationName,
                role: role,
                matchIdentifier: nonEmpty(action.arguments["identifier"]),
                matchTitle: nonEmpty(action.arguments["title"]),
                targetIdentity: targetIdentity,
                requestedItemTitle: requestedItemTitle
            )
        } else if action.actionName == "ui.toggle_disclosure",
                  let applicationName = action.arguments["applicationName"],
                  let role = action.arguments["role"],
                  let targetIdentity = result.outputData["targetIdentity"],
                  let desiredStateRaw = action.arguments["desiredState"],
                  let desiredState = QAXDisclosureState(rawValue: desiredStateRaw) {
            // Reconstructed from the exact arguments used to dispatch, plus the safe (non-secret
            // targeting metadata only) outputData QExecutionService captured at toggle time — the
            // independent verification step re-resolves the precise disclosure triangle that was
            // toggled and independently re-reads its own kAXValueAttribute, never trusting
            // whatever executeToggleDisclosure itself already observed.
            func nonEmpty(_ value: String?) -> String? { value.flatMap { $0.isEmpty ? nil : $0 } }
            return .axDisclosureStateMatchesDesired(
                applicationName: applicationName,
                role: role,
                matchIdentifier: nonEmpty(action.arguments["identifier"]),
                matchTitle: nonEmpty(action.arguments["title"]),
                targetIdentity: targetIdentity,
                desiredState: desiredState
            )
        } else if action.actionName == "ui.select_tab",
                  let applicationName = action.arguments["applicationName"],
                  let role = action.arguments["role"],
                  let targetIdentity = result.outputData["targetIdentity"],
                  let desiredSelectedRaw = action.arguments["desiredSelected"],
                  let desiredSelected = Bool(desiredSelectedRaw) {
            // Reconstructed from the exact arguments used to dispatch, plus the safe (non-secret
            // targeting metadata only) outputData QExecutionService captured at selection time —
            // the independent verification step re-resolves the precise tab that was selected
            // and independently re-reads its own kAXSelectedAttribute, never trusting whatever
            // executeSelectTab itself already observed.
            func nonEmpty(_ value: String?) -> String? { value.flatMap { $0.isEmpty ? nil : $0 } }
            return .axTabSelectionMatchesDesired(
                applicationName: applicationName,
                role: role,
                matchIdentifier: nonEmpty(action.arguments["identifier"]),
                matchTitle: nonEmpty(action.arguments["title"]),
                targetIdentity: targetIdentity,
                desiredSelected: desiredSelected
            )
        } else if action.actionName == "ui.select_table_row",
                  let applicationName = action.arguments["applicationName"],
                  let role = action.arguments["role"],
                  let targetIdentity = result.outputData["targetIdentity"],
                  let desiredSelectedRaw = action.arguments["desiredSelected"],
                  let desiredSelected = Bool(desiredSelectedRaw) {
            // Reconstructed from the exact arguments used to dispatch, plus the safe (non-secret
            // targeting metadata only) outputData QExecutionService captured at selection time —
            // the independent verification step re-resolves the precise table row that was
            // selected and independently re-reads its own kAXSelectedAttribute, never trusting
            // whatever executeSelectTableRow itself already observed.
            func nonEmpty(_ value: String?) -> String? { value.flatMap { $0.isEmpty ? nil : $0 } }
            return .axTableRowSelectionMatchesDesired(
                applicationName: applicationName,
                role: role,
                matchIdentifier: nonEmpty(action.arguments["identifier"]),
                matchTitle: nonEmpty(action.arguments["title"]),
                targetIdentity: targetIdentity,
                desiredSelected: desiredSelected
            )
        } else if action.actionName == "ui.select_outline_row",
                  let applicationName = action.arguments["applicationName"],
                  let role = action.arguments["role"],
                  let targetIdentity = result.outputData["targetIdentity"],
                  let desiredSelectedRaw = action.arguments["desiredSelected"],
                  let desiredSelected = Bool(desiredSelectedRaw) {
            // Reconstructed from the exact arguments used to dispatch, plus the safe (non-secret
            // targeting metadata only) outputData QExecutionService captured at selection time —
            // the independent verification step re-resolves the precise outline row that was
            // selected and independently re-reads its own kAXSelectedAttribute, never trusting
            // whatever executeSelectOutlineRow itself already observed.
            func nonEmpty(_ value: String?) -> String? { value.flatMap { $0.isEmpty ? nil : $0 } }
            return .axOutlineRowSelectionMatchesDesired(
                applicationName: applicationName,
                role: role,
                matchIdentifier: nonEmpty(action.arguments["identifier"]),
                matchTitle: nonEmpty(action.arguments["title"]),
                targetIdentity: targetIdentity,
                desiredSelected: desiredSelected
            )
        } else if action.actionName == "ui.set_window_minimized",
                  let applicationName = action.arguments["applicationName"],
                  let role = action.arguments["role"],
                  let targetIdentity = result.outputData["targetIdentity"],
                  let desiredMinimizedRaw = action.arguments["desiredMinimized"],
                  let desiredMinimized = Bool(desiredMinimizedRaw) {
            // Reconstructed from the exact arguments used to dispatch, plus the safe (non-secret
            // targeting metadata only) outputData QExecutionService captured at mutation time —
            // the independent verification step re-resolves the precise window that was mutated
            // and independently re-reads its own kAXMinimizedAttribute, never trusting whatever
            // executeSetWindowMinimized itself already observed.
            func nonEmpty(_ value: String?) -> String? { value.flatMap { $0.isEmpty ? nil : $0 } }
            return .axWindowMinimizedStateMatchesDesired(
                applicationName: applicationName,
                role: role,
                matchIdentifier: nonEmpty(action.arguments["identifier"]),
                matchTitle: nonEmpty(action.arguments["title"]),
                targetIdentity: targetIdentity,
                desiredMinimized: desiredMinimized
            )
        } else if action.actionName == "ui.set_window_full_screen",
                  let applicationName = action.arguments["applicationName"],
                  let role = action.arguments["role"],
                  let targetIdentity = result.outputData["targetIdentity"],
                  let desiredFullScreenRaw = action.arguments["desiredFullScreen"],
                  let desiredFullScreen = Bool(desiredFullScreenRaw) {
            func nonEmpty(_ value: String?) -> String? { value.flatMap { $0.isEmpty ? nil : $0 } }
            return .axWindowFullScreenMatchesDesired(
                applicationName: applicationName,
                role: role,
                matchIdentifier: nonEmpty(action.arguments["identifier"]),
                matchTitle: nonEmpty(action.arguments["title"]),
                targetIdentity: targetIdentity,
                desiredFullScreen: desiredFullScreen
            )
        } else if action.actionName == "ui.set_application_hidden",
                  let applicationName = action.arguments["applicationName"],
                  let targetProcessIdentifierString = result.outputData["targetProcessIdentifier"],
                  let targetProcessIdentifier = Int32(targetProcessIdentifierString),
                  let desiredHiddenRaw = action.arguments["desiredHidden"],
                  let desiredHidden = Bool(desiredHiddenRaw) {
            // Reconstructed from the exact application name used to dispatch, plus the safe
            // (non-secret, stable process identity) outputData QExecutionService captured at
            // resolution time — the independent verification step re-resolves the exact process
            // by pid and independently re-reads its own isHidden, never trusting whatever
            // executeSetApplicationHidden's own bounded poll already observed.
            return .applicationHiddenStateMatchesDesired(
                applicationName: applicationName,
                targetProcessIdentifier: pid_t(targetProcessIdentifier),
                desiredHidden: desiredHidden
            )
        } else if action.actionName == "ui.set_scroll_position",
                  let applicationName = action.arguments["applicationName"],
                  let role = action.arguments["role"],
                  let orientation = action.arguments["orientation"],
                  let targetIdentity = result.outputData["targetIdentity"],
                  let desiredValueString = action.arguments["desiredValue"],
                  let desiredValue = Double(desiredValueString) {
            // Reconstructed from the exact arguments used to dispatch, plus the safe (plain
            // numeric metadata, never masked) outputData QExecutionService captured at
            // position-change time — the independent verification step re-resolves the ENTIRE
            // identity chain (scroll area -> orientation convenience-reference -> scroll bar
            // role) fresh and compares its current value against the desired value directly,
            // never trusting whatever executeSetScrollPosition itself already observed.
            func nonEmpty(_ value: String?) -> String? { value.flatMap { $0.isEmpty ? nil : $0 } }
            return .scrollPositionMatchesDesired(
                applicationName: applicationName,
                role: role,
                matchIdentifier: nonEmpty(action.arguments["identifier"]),
                matchTitle: nonEmpty(action.arguments["title"]),
                orientation: orientation,
                targetIdentity: targetIdentity,
                desiredValue: desiredValue
            )
        } else if action.actionName == "ui.set_window_main",
                  let applicationName = action.arguments["applicationName"],
                  let role = action.arguments["role"],
                  let targetIdentity = result.outputData["targetIdentity"] {
            // Reconstructed from the exact target-identifying arguments used to dispatch
            // (applicationName/role/identifier/title), plus the targetIdentity captured at
            // mutation time. desiredMain is deliberately NOT threaded through here: the
            // capability contract guarantees desiredMain is always true (false is rejected
            // before any AX call), so the verification strategy has nothing to branch on.
            // Independent verification re-resolves the window fresh, re-validates its role,
            // and re-reads kAXMainAttribute fresh — never trusting whatever
            // executeSetWindowMain itself already observed.
            func nonEmpty(_ value: String?) -> String? { value.flatMap { $0.isEmpty ? nil : $0 } }
            return .windowMainStateMatchesDesired(
                applicationName: applicationName,
                role: role,
                matchIdentifier: nonEmpty(action.arguments["identifier"]),
                matchTitle: nonEmpty(action.arguments["title"]),
                targetIdentity: targetIdentity
            )
        } else if action.actionName == "ui.close_window",
                  let applicationName = action.arguments["applicationName"],
                  let role = action.arguments["role"],
                  let targetIdentity = result.outputData["targetIdentity"] {
            // Reconstructed from the exact target-identifying arguments used to dispatch
            // (applicationName/role/identifier/title), plus the targetIdentity captured at
            // mutation time. Independent verification re-resolves the OWNING APPLICATION first
            // (never conflating application termination with a genuine single-window close),
            // then re-resolves the exact window identity fresh — never trusting whatever
            // executeCloseWindow itself already observed, and never trusting the close-button
            // press's own AXError return value as proof.
            func nonEmpty(_ value: String?) -> String? { value.flatMap { $0.isEmpty ? nil : $0 } }
            return .windowCloseVerified(
                applicationName: applicationName,
                role: role,
                matchIdentifier: nonEmpty(action.arguments["identifier"]),
                matchTitle: nonEmpty(action.arguments["title"]),
                targetIdentity: targetIdentity
            )
        } else if action.actionName == "ui.list_windows",
                  let applicationName = action.arguments["applicationName"],
                  let windowCountString = result.outputData["windowCount"],
                  let windowCount = Int(windowCountString) {
            // Level 0, read-only — reconstructed from the applicationName argument used to
            // dispatch, plus the windowCount captured at read time. Deliberately NOT threaded
            // through here: any individual window's title/identifier — this strategy (and its
            // resulting persisted evidence text) only ever carries an aggregate count, by design
            // (see docs/PHASE_2Z_SEMANTIC_WINDOW_ENUMERATION.md's privacy boundary).
            return .windowEnumerationSucceeded(applicationName: applicationName, windowCount: windowCount)
        } else if action.actionName == "ui.list_menu_items",
                  let applicationName = action.arguments["applicationName"],
                  let menuCountString = result.outputData["topLevelMenuCount"],
                  let menuCount = Int(menuCountString),
                  let itemCountString = result.outputData["totalItemCount"],
                  let itemCount = Int(itemCountString) {
            // Level 0, read-only — reconstructed from the applicationName argument used to
            // dispatch, plus the menu and item counts captured at read time. Deliberately NOT threaded
            // through here: any individual menu/item title or identifier — this strategy only ever
            // carries aggregate counts, by design.
            return .menuEnumerationSucceeded(applicationName: applicationName, menuCount: menuCount, itemCount: itemCount)
        } else if action.actionName == "ui.list_popup_items",
                  let applicationName = action.arguments["applicationName"],
                  let itemCountString = result.outputData["itemCount"],
                  let itemCount = Int(itemCountString) {
            // Level 0, read-only — reconstructed from the applicationName argument used to
            // dispatch, plus the item count captured at read time. Deliberately NOT threaded
            // through here: any individual popup item title or identifier — this strategy only ever
            // carries aggregate counts, by design.
            return .popupEnumerationSucceeded(applicationName: applicationName, itemCount: itemCount)
        } else if action.actionName == "ui.list_table_rows",
                  let applicationName = action.arguments["applicationName"],
                  let rowCountString = result.outputData["rowCount"],
                  let rowCount = Int(rowCountString),
                  let selectedCountString = result.outputData["selectedRowCount"],
                  let selectedCount = Int(selectedCountString) {
            // Level 0, read-only — reconstructed from the applicationName argument used to
            // dispatch, plus the row count and selected row count captured at read time. Deliberately NOT threaded
            // through here: any individual row title or identifier — this strategy only ever
            // carries aggregate counts, by design.
            return .tableRowEnumerationSucceeded(applicationName: applicationName, rowCount: rowCount, selectedCount: selectedCount)
        } else if action.actionName == "ui.list_outline_items",
                  let applicationName = action.arguments["applicationName"],
                  let itemCountString = result.outputData["itemCount"],
                  let itemCount = Int(itemCountString),
                  let selectedCountString = result.outputData["selectedItemCount"],
                  let selectedCount = Int(selectedCountString),
                  let expandedCountString = result.outputData["expandedItemCount"],
                  let expandedCount = Int(expandedCountString) {
            // Level 0, read-only — reconstructed from the applicationName argument used to
            // dispatch, plus the item count, selected count, and expanded count captured at read time. Deliberately NOT threaded
            // through here: any individual outline item title or identifier — this strategy only ever
            // carries aggregate counts, by design.
            return .outlineItemEnumerationSucceeded(applicationName: applicationName, itemCount: itemCount, selectedCount: selectedCount, expandedCount: expandedCount)
        } else if action.actionName == "ui.list_tab_items",
                  let applicationName = action.arguments["applicationName"],
                  let tabCountString = result.outputData["itemCount"],
                  let tabCount = Int(tabCountString),
                  let selectedCountString = result.outputData["selectedItemCount"],
                  let selectedCount = Int(selectedCountString) {
            // Level 0, read-only — reconstructed from the applicationName argument used to
            // dispatch, plus the tab count and selected count captured at read time. Deliberately NOT threaded
            // through here: any individual tab title or identifier — this strategy only ever
            // carries aggregate counts, by design.
            return .tabItemEnumerationSucceeded(applicationName: applicationName, tabCount: tabCount, selectedCount: selectedCount)
        } else if action.actionName == "ui.list_radio_group_items",
                  let applicationName = action.arguments["applicationName"],
                  let itemCountString = result.outputData["itemCount"],
                  let itemCount = Int(itemCountString),
                  let selectedCountString = result.outputData["selectedItemCount"],
                  let selectedCount = Int(selectedCountString) {
            // Level 0, read-only — reconstructed from the applicationName argument used to
            // dispatch, plus the item count and selected count captured at read time. Deliberately NOT threaded
            // through here: any individual radio option title or identifier — this strategy only ever
            // carries aggregate counts, by design.
            return .radioGroupEnumerationSucceeded(applicationName: applicationName, itemCount: itemCount, selectedCount: selectedCount)
        } else if action.actionName == "ui.list_toolbar_items",
                  let applicationName = action.arguments["applicationName"],
                  let itemCountString = result.outputData["itemCount"],
                  let itemCount = Int(itemCountString) {
            // Level 0, read-only — reconstructed from the applicationName argument used to
            // dispatch, plus the item count captured at read time. Deliberately NOT threaded
            // through here: any individual toolbar button title or identifier — this strategy only ever
            // carries aggregate counts, by design.
            return .toolbarItemEnumerationSucceeded(applicationName: applicationName, itemCount: itemCount)
        } else if action.actionName == "ui.list_split_panes",
                  let applicationName = action.arguments["applicationName"],
                  let paneCountString = result.outputData["paneCount"],
                  let paneCount = Int(paneCountString) {
            // Level 0, read-only — reconstructed from the applicationName argument used to
            // dispatch, plus the pane count captured at read time. Deliberately NOT threaded
            // through here: any individual pane title or identifier — this strategy only ever
            // carries aggregate counts, by design.
            return .splitPaneEnumerationSucceeded(applicationName: applicationName, paneCount: paneCount)
        } else if action.actionName == "ui.list_segmented_control_items",
                  let applicationName = action.arguments["applicationName"],
                  let itemCountString = result.outputData["itemCount"],
                  let itemCount = Int(itemCountString),
                  let selectedCountString = result.outputData["selectedItemCount"],
                  let selectedCount = Int(selectedCountString) {
            // Level 0, read-only — reconstructed from the applicationName argument used to
            // dispatch, plus the item count and selected count captured at read time. Deliberately NOT threaded
            // through here: any individual segment title or identifier — this strategy only ever
            // carries aggregate counts, by design.
            return .segmentedControlEnumerationSucceeded(applicationName: applicationName, itemCount: itemCount, selectedCount: selectedCount)
        } else if action.actionName == "ui.list_sheet_dialogs",
                  let applicationName = action.arguments["applicationName"],
                  let sheetCountString = result.outputData["sheetCount"],
                  let sheetCount = Int(sheetCountString) {
            // Level 0, read-only — reconstructed from the applicationName argument used to
            // dispatch, plus the sheet count captured at read time. Deliberately NOT threaded
            // through here: any individual sheet title or identifier — this strategy only ever
            // carries aggregate counts, by design.
            return .sheetEnumerationSucceeded(applicationName: applicationName, sheetCount: sheetCount)
        } else if action.actionName == "ui.list_sheet_actions",
                  let applicationName = action.arguments["applicationName"],
                  let actionCountString = result.outputData["actionCount"],
                  let actionCount = Int(actionCountString) {
            // Level 0, read-only — reconstructed from the applicationName argument used to
            // dispatch, plus the action count captured at read time. Deliberately NOT threaded
            // through here: any individual action title or identifier — this strategy only ever
            // carries aggregate counts, by design.
            return .sheetActionEnumerationSucceeded(applicationName: applicationName, actionCount: actionCount)
        } else if action.actionName == "ui.select_segmented_control_item",
                  let applicationName = action.arguments["applicationName"],
                  let targetIdentity = result.outputData["targetIdentity"] {
            func nonEmpty(_ value: String?) -> String? { value.flatMap { $0.isEmpty ? nil : $0 } }
            let role = action.arguments["role"] ?? "AXSegmentedControl"
            let desiredSelectedRaw = action.arguments["desiredSelected"] ?? "true"
            let desiredSelected = Bool(desiredSelectedRaw) ?? true
            let controlId = nonEmpty(action.arguments["controlIdentifier"]) ?? nonEmpty(action.arguments["identifier"])
            let controlTitle = nonEmpty(action.arguments["controlTitle"]) ?? nonEmpty(action.arguments["title"])
            let segmentId = nonEmpty(action.arguments["segmentIdentifier"]) ?? (action.arguments["controlIdentifier"] != nil ? nonEmpty(action.arguments["identifier"]) : nil)
            let segmentTitle = nonEmpty(action.arguments["segmentTitle"]) ?? nonEmpty(action.arguments["segmentLabel"]) ?? nonEmpty(action.arguments["segment"]) ?? (action.arguments["controlTitle"] != nil ? nonEmpty(action.arguments["title"]) : nil)
            return .axSegmentedControlSelectionMatchesDesired(
                applicationName: applicationName,
                role: role,
                controlIdentifier: controlId,
                controlTitle: controlTitle,
                windowTitle: nonEmpty(action.arguments["windowTitle"]) ?? nonEmpty(action.arguments["window"]),
                windowIdentifier: nonEmpty(action.arguments["windowIdentifier"]) ?? nonEmpty(action.arguments["windowId"]),
                segmentIdentifier: segmentId,
                segmentTitle: segmentTitle,
                targetIdentity: targetIdentity,
                desiredSelected: desiredSelected
            )
        } else if action.actionName == "ui.set_splitter_position",
                  let applicationName = action.arguments["applicationName"],
                  let targetIdentity = result.outputData["targetIdentity"] {
            func nonEmpty(_ value: String?) -> String? { value.flatMap { $0.isEmpty ? nil : $0 } }
            let desiredPositionRaw = action.arguments["desiredPosition"] ?? action.arguments["position"] ?? action.arguments["value"] ?? result.outputData["desiredPosition"] ?? "0"
            let desiredPosition = Double(desiredPositionRaw) ?? 0.0
            let toleranceRaw = action.arguments["tolerance"] ?? result.outputData["tolerance"] ?? "0.5"
            let tolerance = Double(toleranceRaw) ?? 0.5
            let splitterIndexRaw = action.arguments["splitterIndex"] ?? action.arguments["index"] ?? action.arguments["dividerIndex"] ?? result.outputData["splitterIndex"] ?? "0"
            let splitterIndex = Int(splitterIndexRaw) ?? 0
            let splitGroupId = nonEmpty(action.arguments["splitGroupIdentifier"]) ?? nonEmpty(action.arguments["identifier"]) ?? nonEmpty(result.outputData["splitGroupIdentifier"])
            let splitGroupTitle = nonEmpty(action.arguments["splitGroupTitle"]) ?? nonEmpty(action.arguments["title"]) ?? nonEmpty(result.outputData["splitGroupTitle"])
            let windowTitle = nonEmpty(action.arguments["windowTitle"]) ?? nonEmpty(action.arguments["window"]) ?? nonEmpty(result.outputData["windowTitle"])
            let windowIdentifier = nonEmpty(action.arguments["windowIdentifier"]) ?? nonEmpty(action.arguments["windowId"]) ?? nonEmpty(result.outputData["windowIdentifier"])

            return .splitterPositionMatchesDesired(
                applicationName: applicationName,
                windowTitle: windowTitle,
                windowIdentifier: windowIdentifier,
                splitGroupIdentifier: splitGroupId,
                splitGroupTitle: splitGroupTitle,
                splitterIndex: splitterIndex,
                desiredPosition: desiredPosition,
                tolerance: tolerance,
                targetIdentity: targetIdentity
            )
        } else {
            return .customCheck(description: "Default step verification") { true }
        }
    }
}
