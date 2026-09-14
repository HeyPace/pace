//
//  PaceActionExecutor+EntryPoint.swift
//  leanring-buddy
//
//  Extracted from PaceActionExecutor.swift (god-class decomposition Phase B):
//  executeActionPlan dispatch and streaming mail draft entry points.
//

import Foundation

@MainActor
extension PaceActionExecutor {

    // MARK: - High-level entry point

    // MARK: - High-level entry point

    /// Executes a tool plan: outer steps are sequential; actions within one
    /// step are a parallel group at the planner contract level. UI-mutating
    /// actions still run in source order because macOS focus/cursor state is
    /// global and not safe to mutate concurrently.
    /// - Parameter approvalAlreadyObtained: Phase 2H remediation. Whether a real, explicit human
    ///   decision has already been obtained for the actions in this plan — either through
    ///   `requestUserApprovalForActionPlan`'s real, blocking NSAlert (the normal case), or through
    ///   some other genuinely explicit, real-time user action (e.g. the user just selected a
    ///   specific option in a click-target clarification, or physically pressed the undo button).
    ///   No default value: every call site must consciously declare this rather than silently
    ///   inheriting an "approved" assumption. `executeSingleAction` uses this as a fail-closed
    ///   backstop for any action Q's `QActionAuthorizationBridge` classifies as requiring
    ///   approval — see that function's doc comment for why this can't simply always block.
    @discardableResult
    func executeActionPlan(
        _ actionExecutionPlan: PaceActionExecutionPlan,
        screenCaptures: [CompanionScreenCapture],
        approvalAlreadyObtained: Bool
    ) async -> [PaceActionExecutionObservation] {
        guard !actionExecutionPlan.steps.isEmpty else { return [] }

        var observations: [PaceActionExecutionObservation] = []

        for (stepIndex, step) in actionExecutionPlan.steps.enumerated() {
            guard !Task.isCancelled else { return observations }
            guard !step.actions.isEmpty else { continue }

            for (actionIndex, action) in step.actions.enumerated() {
                guard !Task.isCancelled else { return observations }

                if let observation = await executeSingleAction(action, screenCaptures: screenCaptures, approvalAlreadyObtained: approvalAlreadyObtained) {
                    observations.append(observation)
                }
                guard !Task.isCancelled else { return observations }

                let isLastActionInStep = (actionIndex == step.actions.count - 1)
                if !isLastActionInStep {
                    try? await Task.sleep(nanoseconds: UInt64(interActionDelay * 1_000_000_000))
                }
            }

            let isLastStep = (stepIndex == actionExecutionPlan.steps.count - 1)
            if !isLastStep {
                try? await Task.sleep(nanoseconds: UInt64(interActionDelay * 1_000_000_000))
            }
        }

        return observations
    }

    var hasActiveStreamingMailDraft: Bool {
        activeStreamingMailDraftState != nil
    }

    @discardableResult
    func beginOrUpdateStreamingMailDraft(
        _ snapshot: PaceStreamingMailDraftSnapshot
    ) async -> PaceActionExecutionObservation? {
        guard actionsAreEnabled else {
            return PaceActionExecutionObservation(
                toolName: "mail",
                summary: "Would stream mail draft body: \(snapshot.normalizedMailDraft.subject)"
            )
        }

        let now = Date()
        if let activeStreamingMailDraftState,
           now.timeIntervalSince(activeStreamingMailDraftState.lastWriteDate) < 0.033 {
            self.activeStreamingMailDraftState = activeStreamingMailDraftState
                .withPendingSnapshot(snapshot)
            return nil
        }

        return await writeStreamingMailDraft(snapshot, isFinalWrite: false)
    }

    @discardableResult
    func finishActiveStreamingMailDraft(
        finalMailDraft: PaceMailDraft
    ) async -> PaceActionExecutionObservation? {
        guard activeStreamingMailDraftState != nil else {
            return nil
        }

        let finalSnapshot = PaceStreamingMailDraftSnapshot(
            recipients: finalMailDraft.recipients,
            subject: finalMailDraft.subject,
            body: finalMailDraft.body
        )
        let observation = await writeStreamingMailDraft(finalSnapshot, isFinalWrite: true)
        activeStreamingMailDraftState = nil

        return observation ?? PaceActionExecutionObservation(
            toolName: "mail",
            summary: "Created streaming mail draft: \(finalMailDraft.subject)"
        )
    }

    func cancelActiveStreamingMailDraftTracking() {
        activeStreamingMailDraftState = nil
    }

    /// Phase 2H remediation.
    ///
    /// Why `.requireApproval` can't simply always block: `QActionAuthorizationBridge
    /// .preflightAuthorize` runs Q's `QPermissionGate` classification on every dispatch, but
    /// `QPermissionGate` is stateless — it has no notion of "the user already approved this plan a
    /// moment ago." Pace's REAL, working, blocking human-approval gate is a separate, earlier,
    /// plan-level mechanism (`requestUserApprovalForActionPlan`'s NSAlert, driven by
    /// `PaceActionApprovalPolicy.requiresExplicitApproval`), not this per-action Q check. Every
    /// action Q classifies as Level 2/3 that Pace's product design has already decided to
    /// auto-permit without a popup (click, openURL, etc. — see
    /// `docs/architecture/systems.md`'s "routine local actions... can execute without the popup")
    /// would ALWAYS see `.requireApproval` here, on every single dispatch, forever — so
    /// unconditionally blocking on it would break that entire, intentional, already-shipped
    /// behavior, not just close a gap.
    ///
    /// `approvalAlreadyObtained` is therefore how the caller tells this function whether a real
    /// human decision already covers what's about to run. When it's `false` and Q says
    /// `.requireApproval`, execution is refused — this is the fail-closed backstop for any action
    /// that reaches here WITHOUT having gone through a real approval gate (today, that's
    /// specifically the keyboard-input actions this remediation added to
    /// `requiresExplicitApproval` — see that function's doc comment).
    func executeSingleAction(
        _ action: PaceParsedAction,
        screenCaptures: [CompanionScreenCapture],
        approvalAlreadyObtained: Bool
    ) async -> PaceActionExecutionObservation? {
        // Q Security Preflight Authorization
        let decision = QActionAuthorizationBridge.preflightAuthorize(action: action)
        if case .deny(let reason, _) = decision {
            let denialObservation = PaceActionExecutionObservation(
                toolName: action.auditOperationName,
                summary: "Security Authorization Denied: \(reason)"
            )
            QAuditLogger.shared.record(
                QAuditRecord(
                    sessionId: "active-session",
                    taskId: "task",
                    tool: action.auditOperationName,
                    riskLevel: .level4Blocked,
                    rawArguments: action.approvalDescription,
                    authorizationResult: "deny",
                    provenance: "trusted:system",
                    error: reason
                )
            )
            return denialObservation
        }

        // Gated on actionsAreEnabled: dry-run mode (actionsAreEnabled == false) never causes a
        // real side effect regardless — each dispatch handler independently checks
        // actionsAreEnabled before doing anything mutating — so simulated "would do X" dry-run
        // observations are never blocked by this backstop, matching how every other mutation gate
        // in this executor already works.
        if case .requireApproval(let req) = decision, actionsAreEnabled, !approvalAlreadyObtained {
            let blockedObservation = PaceActionExecutionObservation(
                toolName: action.auditOperationName,
                summary: "Action requires explicit approval that was not obtained: \(req.reason)"
            )
            QAuditLogger.shared.record(
                QAuditRecord(
                    sessionId: "active-session",
                    taskId: "task",
                    tool: action.auditOperationName,
                    riskLevel: req.riskLevel,
                    rawArguments: action.approvalDescription,
                    authorizationResult: "blocked_no_approval",
                    provenance: "trusted:system",
                    error: "Action requires approval; none was obtained prior to dispatch."
                )
            )
            return blockedObservation
        }

        let observation = await dispatchSingleAction(action, screenCaptures: screenCaptures)
        let outcomeText: String
        if let observation, observation.summary.lowercased().contains("fail")
            || observation.summary.lowercased().contains("error")
            || observation.summary.lowercased().contains("could not") {
            outcomeText = "error"
        } else {
            outcomeText = "ok"
        }
        PaceAPIAuditLog.shared.record(
            subsystem: "action",
            operation: action.auditOperationName,
            target: action.auditTarget,
            durationMilliseconds: 0,
            outcome: outcomeText,
            outputCharacterCount: observation?.summary.count,
            detail: observation?.summary.prefix(160).description
        )
        let meta = QActionAuthorizationBridge.mapActionToQMetadata(action)
        // Honest audit labeling (Phase 2H remediation): a `.requireApproval` decision that reached
        // execution here was NEVER actually approved by Q's own gate — it was either covered by
        // Pace's separate plan-level approval (`approvalAlreadyObtained == true`, verified above)
        // or is one of the actions Pace's product policy intentionally auto-permits without a
        // per-action approval step. Neither of those is "allow" in Q's sense, so this no longer
        // claims the false label "approved" for a decision Q itself never rendered as allowed.
        let authorizationResultLabel: String
        switch decision {
        case .allow:
            authorizationResultLabel = "allow"
        case .requireApproval:
            authorizationResultLabel = "plan_level_approval_or_policy_exempt"
        case .deny:
            authorizationResultLabel = "deny" // unreachable here — handled above
        }
        QAuditLogger.shared.record(
            QAuditRecord(
                sessionId: "active-session",
                taskId: "task",
                tool: meta.toolName,
                riskLevel: meta.risk,
                rawArguments: action.approvalDescription,
                authorizationResult: authorizationResultLabel,
                provenance: "trusted:system",
                executionSummary: observation?.summary
            )
        )
        return observation
    }

    /// Builds the observation for a raw-coordinate `.click`/`.doubleClick`
    /// dispatch from `clickAtScreenshotLocation`'s existing `Bool` — no
    /// re-execution, no new AX/CGEvent logic. `coordinatesResolved == false`
    /// is that function's one genuine failure signal (it always returns
    /// `true` once the screenshot pixel maps to a real display point,
    /// dry-run included — see its own doc comment). The literal substring
    /// "Click failed" matches `speakFailureForClickMissedIfApplicable`'s
    /// existing detection convention (already used by `clickBestCandidate`),
    /// so a genuine coordinate-resolution failure here reaches the same
    /// existing failure-narration path.
    /// Internal (not `private`) so the observation-construction contract —
    /// the exact defect this function exists to fix — can be unit-tested
    /// directly and deterministically, without touching live AX/CGEvent
    /// state. See `PaceActionObservationPropagationTests.swift`.
    func observationForCoordinateClick(
        at location: ScreenshotPixelLocation,
        isDoubleClick: Bool,
        coordinatesResolved: Bool
    ) -> PaceActionExecutionObservation {
        let toolName = isDoubleClick ? "double_click" : "click"
        guard coordinatesResolved else {
            return PaceActionExecutionObservation(
                toolName: toolName,
                summary: "Click failed: could not resolve screen coordinates for \(location.approvalDescription)."
            )
        }
        guard actionsAreEnabled else {
            let verb = isDoubleClick ? "double-click" : "click"
            return PaceActionExecutionObservation(
                toolName: toolName,
                summary: "Would \(verb) at \(location.approvalDescription)."
            )
        }
        return PaceActionExecutionObservation(
            toolName: toolName,
            summary: isDoubleClick
                ? "Double-clicked at \(location.approvalDescription)."
                : "Clicked at \(location.approvalDescription)."
        )
    }

    func dispatchSingleAction(
        _ action: PaceParsedAction,
        screenCaptures: [CompanionScreenCapture]
    ) async -> PaceActionExecutionObservation? {
        switch action {
        case .click(let location):
            let coordinatesResolved = await clickAtScreenshotLocation(
                location, screenCaptures: screenCaptures, clickCount: 1
            )
            return observationForCoordinateClick(
                at: location, isDoubleClick: false, coordinatesResolved: coordinatesResolved
            )
        case .doubleClick(let location):
            let coordinatesResolved = await clickAtScreenshotLocation(
                location, screenCaptures: screenCaptures, clickCount: 2
            )
            return observationForCoordinateClick(
                at: location, isDoubleClick: true, coordinatesResolved: coordinatesResolved
            )
        case .clickCandidates(let clickCandidateSet):
            return await clickBestCandidate(clickCandidateSet, screenCaptures: screenCaptures)
        case .type(let textToType):
            await typeText(textToType)
            let characterCountDescription =
                "\(textToType.count) character\(textToType.count == 1 ? "" : "s")"
            return PaceActionExecutionObservation(
                toolName: "type",
                summary: actionsAreEnabled
                    ? "Typed \(characterCountDescription)."
                    : "Would type \(characterCountDescription)."
            )
        case .setTextValue(let setTextValueRequest):
            return setTextValue(setTextValueRequest)
        case .editSelectedText(let voiceEditRequest):
            return editSelectedText(voiceEditRequest)
        case .undoLastMutation:
            return undoLastMutation()
        case .pressKey(let keyName, let modifiers):
            let keyWasRecognized = await pressKey(named: keyName, withModifiers: modifiers)
            let keyDescription = modifiers.isEmpty
                ? keyName
                : "\(modifiers.map(\.rawValue).joined(separator: "+"))+\(keyName)"
            let summary: String
            if !actionsAreEnabled {
                summary = "Would press \(keyDescription)."
            } else if !keyWasRecognized {
                summary = "Key press failed: unrecognized key \(keyName)."
            } else {
                summary = "Pressed \(keyDescription)."
            }
            return PaceActionExecutionObservation(toolName: "key_press", summary: summary)
        case .readClipboard:
            return readClipboardText()
        case .snapWindow(let snapWindowRequest):
            return snapFocusedWindow(snapWindowRequest)
        case .scroll(let direction, let amount):
            let scrollEventPosted = await scroll(direction: direction, amountInLines: amount)
            let summary: String
            if !actionsAreEnabled {
                summary = "Would scroll \(direction) by \(amount) line\(amount == 1 ? "" : "s")."
            } else if !scrollEventPosted {
                summary = "Scroll failed: could not construct scroll event."
            } else {
                summary = "Scrolled \(direction) by \(amount) line\(amount == 1 ? "" : "s")."
            }
            return PaceActionExecutionObservation(toolName: "scroll", summary: summary)
        case .openApplication(let applicationName):
            return await openApplication(named: applicationName)
        case .openURL(let urlString):
            return await openURL(urlString)
        case .controlMusic(let musicCommand):
            return await controlMusic(musicCommand)
        case .adjustVolume(let adjustment):
            await adjustVolume(adjustment)
            let stepsDescription = "\(adjustment.stepCount) step\(adjustment.stepCount == 1 ? "" : "s")"
            return PaceActionExecutionObservation(
                toolName: "volume",
                summary: actionsAreEnabled
                    ? "Adjusted volume \(adjustment.direction.rawValue) by \(stepsDescription)."
                    : "Would adjust volume \(adjustment.direction.rawValue) by \(stepsDescription)."
            )
        case .adjustBrightness(let adjustment):
            await adjustBrightness(adjustment)
            let stepsDescription = "\(adjustment.stepCount) step\(adjustment.stepCount == 1 ? "" : "s")"
            return PaceActionExecutionObservation(
                toolName: "brightness",
                summary: actionsAreEnabled
                    ? "Adjusted brightness \(adjustment.direction.rawValue) by \(stepsDescription)."
                    : "Would adjust brightness \(adjustment.direction.rawValue) by \(stepsDescription)."
            )
        case .listCalendarEvents(let calendarQuery):
            return await listCalendarEvents(calendarQuery)
        case .createCalendarEvent(let calendarEventRequest):
            return await createCalendarEvent(calendarEventRequest)
        case .createReminder(let reminderRequest):
            return await createReminder(reminderRequest)
        case .finder(let finderRequest):
            return await performFinderRequest(finderRequest)
        case .createNote(let noteRequest):
            return await createNote(noteRequest)
        case .appendNote(let noteRequest):
            return await appendNote(noteRequest)
        case .searchNotes(let query):
            return await searchNotes(query: query)
        case .composeMail(let mailDraft):
            return await composeMail(mailDraft)
        case .createThingsToDo(let thingsToDoRequest):
            return await createThingsToDo(thingsToDoRequest)
        case .runShortcut(let shortcutName):
            return await runShortcut(named: shortcutName)
        case .openMessages(let messageRequest):
            return await openMessages(messageRequest)
        case .downloadFile(let downloadRequest):
            return await downloadFile(downloadRequest)
        case .startTimer(let timerRequest):
            return await startTimer(timerRequest)
        case .recordFlow(let flowRequest):
            return recordFlow(flowRequest)
        case .runFlow(let flowRequest):
            return runFlow(flowRequest)
        case .mcp(let mcpToolCall):
            return await callMCPTool(mcpToolCall)
        case .drawAnnotation, .clearAnnotations:
            // Tuition-mode annotation actions are drained out of the
            // plan by `PaceAnnotationActionDrainer` in CompanionManager
            // before it ever reaches the executor. If one slips through
            // (e.g. a future direct caller), no-op silently rather than
            // running an irrelevant local action.
            return nil
        }
    }
}
