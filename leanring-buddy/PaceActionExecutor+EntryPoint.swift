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
    @discardableResult
    func executeActionPlan(
        _ actionExecutionPlan: PaceActionExecutionPlan,
        screenCaptures: [CompanionScreenCapture]
    ) async -> [PaceActionExecutionObservation] {
        let receipt = await executeActionPlanWithReceipt(actionExecutionPlan, screenCaptures: screenCaptures)
        return receipt.observations
    }

    func executeActionPlanWithReceipt(
        _ actionExecutionPlan: PaceActionExecutionPlan,
        screenCaptures: [CompanionScreenCapture]
    ) async -> PaceActionExecutionReceipt {
        var observations: [PaceActionExecutionObservation] = []
        var executedActions: [PaceParsedAction] = []
        func receipt() -> PaceActionExecutionReceipt {
            .init(observations: observations, executedPlan: .serial(actions: executedActions))
        }
        let executionGeneration = applicationTargetGeneration

        for (stepIndex, step) in actionExecutionPlan.steps.enumerated() {
            guard !Task.isCancelled else { return receipt() }
            guard !step.actions.isEmpty else { continue }

            for (actionIndex, action) in step.actions.enumerated() {
                guard !Task.isCancelled, executionGeneration == applicationTargetGeneration else { return receipt() }

                if let observation = await executeSingleAction(action, screenCaptures: screenCaptures) {
                    observations.append(observation)
                    if observation.stopsActionPlan { return receipt() }
                }
                executedActions.append(action)
                guard !Task.isCancelled else { return receipt() }

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

        return receipt()
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

    func executeSingleAction(
        _ action: PaceParsedAction,
        screenCaptures: [CompanionScreenCapture]
    ) async -> PaceActionExecutionObservation? {
        let observation = await dispatchSingleAction(action, screenCaptures: screenCaptures)
        let outcomeText: String
        if let observation,
            observation.stopsAgentLoop
                || observation.summary.lowercased().contains("fail")
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
        return observation
    }

    func dispatchSingleAction(
        _ action: PaceParsedAction,
        screenCaptures: [CompanionScreenCapture]
    ) async -> PaceActionExecutionObservation? {
        guard managedPowerExecutionCheck?() != false else {
            return .init(
                toolName: action.auditOperationName,
                summary: "Power was disabled, removed, or changed; execution stopped.",
                terminalReason: .managedWorkflowUnavailable)
        }
        // Input posting can silently do nothing without Accessibility access.
        // Return a real observation so the agent does not treat that as success.
        if actionsAreEnabled, Self.requiresAccessibility(action), !accessibilityPermissionCheck() {
            return PaceActionExecutionObservation(
                toolName: action.auditOperationName,
                summary:
                    "Could not control the app: Pace needs Accessibility permission in System Settings → Privacy & Security → Accessibility. No input was sent."
            )
        }
        switch action {
        case .click(let location):
            return await clickWithReceipt(at: location, screenCaptures: screenCaptures, clickCount: 1)
        case .doubleClick(let location):
            return await clickWithReceipt(at: location, screenCaptures: screenCaptures, clickCount: 2)
        case .clickCandidates(let clickCandidateSet):
            return await clickBestCandidate(clickCandidateSet, screenCaptures: screenCaptures)
        case .type(let textToType):
            guard actionsAreEnabled else { return nil }
            guard await typeText(textToType) else {
                return .init(
                    toolName: "type",
                    summary: "Could not finish typing into the frontmost app. No remaining plan actions were run.",
                    userFacingSummary: "I couldn’t finish typing. Check the draft before trying again.",
                    terminalReason: .inspectionInterrupted)
            }
            return .init(
                toolName: "type",
                summary: "Posted keyboard input for \(textToType.count) characters. Inspect the focused field to verify the text. Do not repeat typing if the text already appears.")
        case .setTextValue(let setTextValueRequest):
            return setTextValue(setTextValueRequest)
        case .editSelectedText(let voiceEditRequest):
            return editSelectedText(voiceEditRequest)
        case .undoLastMutation:
            return undoLastMutation()
        case .pressKey(let keyName, let modifiers):
            return await pressKey(named: keyName, withModifiers: modifiers)
        case .readClipboard:
            return readClipboardText()
        case .snapWindow(let snapWindowRequest):
            return snapFocusedWindow(snapWindowRequest)
        case .scroll(let direction, let amount, let location):
            return scroll(
                direction: direction, amountInLines: amount, location: location, screenCaptures: screenCaptures)
        case .openApplication(let applicationName):
            return await openApplication(named: applicationName)
        case .openURL(let urlString):
            return await openURL(urlString)
        case .openBrowser(let request):
            return await openBrowser(request)
        case .codingSession(let command):
            guard !command.requiresExecutionConsent || actionsAreEnabled else {
                return .init(toolName: "coding_session", summary: "Coding not started. EnableActions is disabled.")
            }
            guard let executeCodingSession else {
                return .init(
                    toolName: "coding_session", summary: "Coding is unavailable. The lifecycle binding is missing.")
            }
            return await executeCodingSession(command)
        case .codexSession(let request):
            return startCodexSession(request)
        case .screenCapture(let kind):
            guard actionsAreEnabled else {
                return .init(toolName: "screen_capture", summary: "Would: \(kind.actionDescription).")
            }
            switch kind {
            case .screenshot, .recording: return await openScreenCaptureControls(kind)
            case .startRecording: return await PaceScreenRecordingController.shared.start()
            case .stopRecording: return await PaceScreenRecordingController.shared.stop()
            case .recordingStatus: return PaceScreenRecordingController.shared.status()
            }
        case .meeting(let command):
            return await controlMeeting(command)
        case .controlMusic(let musicCommand):
            return await controlMusic(musicCommand)
        case .adjustVolume(let adjustment):
            await adjustVolume(adjustment)
        case .adjustBrightness(let adjustment):
            await adjustBrightness(adjustment)
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
        case .presentMedia(let request):
            guard actionsAreEnabled else {
                return .init(toolName: "present_media", summary: "Would present \(request.presentationSummary)")
            }
            return await presentLocalMedia?(request)
                ?? .init(
                    toolName: "present_media", summary: "Media unavailable; lifecycle binding missing.",
                    terminalReason: .managedWorkflowUnavailable)
        case .speak(let request):
            guard actionsAreEnabled else { return .init(toolName: "speak", summary: "Would speak local text.") }
            guard let speakLocalText else {
                return .init(
                    toolName: "speak", summary: "Local speech unavailable; lifecycle binding missing.",
                    terminalReason: .managedWorkflowUnavailable)
            }
            return await speakLocalText(request)
        case .startTimer(let timerRequest):
            return await startTimer(timerRequest)
        case .recordFlow(let flowRequest):
            return recordFlow(flowRequest)
        case .runFlow(let flowRequest):
            return runFlow(flowRequest)
        case .mcp(let mcpToolCall):
            return await callMCPTool(mcpToolCall)
        case .generateImage, .showDiagram, .dismissDiagram, .drawAnnotation, .clearAnnotations:
            // Tuition-mode annotation actions are drained out of the
            // plan by `PaceAnnotationActionDrainer` in CompanionManager
            // before it ever reaches the executor. If one slips through
            // (e.g. a future direct caller), no-op silently rather than
            // running an irrelevant local action.
            return nil
        }

        return nil
    }

    static func requiresAccessibility(_ action: PaceParsedAction) -> Bool {
        switch action {
        case .click, .doubleClick, .clickCandidates, .type, .setTextValue,
            .editSelectedText, .undoLastMutation, .pressKey, .snapWindow, .scroll, .screenCapture:
            return true
        default:
            return false
        }
    }
}
