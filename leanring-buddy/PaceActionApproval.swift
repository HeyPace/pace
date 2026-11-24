//
//  PaceActionApproval.swift
//  leanring-buddy
//
//  Pure approval-gate helpers. CompanionManager owns the actual NSAlert UI;
//  this file keeps the allow/cancel contract testable without controlling the
//  user's Mac during unit tests.
//

import Foundation

nonisolated enum PaceActionApprovalDecision: Equatable, Sendable {
    case allowOnce
    case cancel
}

nonisolated struct PaceActionApprovalRequest: Equatable, Sendable {
    let approvalSummary: String
    let preflightSummary: String?

    init?(
        approvalSummary: String,
        preflightSummary: String? = nil,
        requiresActionApproval: Bool
    ) {
        let trimmedApprovalSummary = approvalSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard requiresActionApproval, !trimmedApprovalSummary.isEmpty else {
            return nil
        }
        self.approvalSummary = trimmedApprovalSummary
        let trimmedPreflightSummary = preflightSummary?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.preflightSummary = trimmedPreflightSummary?.isEmpty == false ? trimmedPreflightSummary : nil
    }

    var messageText: String {
        "Allow Pace to control your Mac?"
    }

    var informativeText: String {
        """
        Pace is asking to perform the following:

        \(approvalSummary)\(preflightSummary.map { "\n\n\($0)" } ?? "")

        Choose Allow Once only if these actions match your request.
        """
    }
}

nonisolated enum PaceActionApprovalPolicy {
    static func needsAnswerAfterInspection(
        _ actionExecutionPlan: PaceActionExecutionPlan,
        observations: [PaceActionExecutionObservation] = []
    ) -> Bool {
        observations.contains(where: \.requiresFreshInspectionPlan)
            || !actionExecutionPlan.flattenedActions.isEmpty
                && actionExecutionPlan.flattenedActions.allSatisfy { action in
                    guard case .mcp(let toolCall) = action else { return false }
                    // Focus recovery changes permission requirements, but the result
                    // is still evidence that must return to the planner for an answer.
                    if toolCall.serverName == "peekaboo", toolCall.toolName == "see" { return true }
                    return permitsObservationOnly(.serial(actions: [action]))
            }
    }

    static func requestsObservationOnly(_ transcript: String) -> Bool {
        if PaceIntentClassifier.isCurrentScreenQuestion(transcript) { return true }
        let normalizedTranscript = transcript.lowercased()
            .replacingOccurrences(of: "’", with: "'")
        return [
            "do not change anything", "don't change anything",
            "do not click or change anything", "don't click or change anything",
            "do not take any actions", "don't take any actions",
        ].contains(where: normalizedTranscript.contains)
            || normalizedTranscript.hasPrefix("read-only ")
            || normalizedTranscript.hasPrefix("read only ")
            || (normalizedTranscript.contains("point")
                && ["without clicking", "do not click", "don't click"]
                    .contains(where: normalizedTranscript.contains))
    }

    static func permitsObservationOnly(
        _ actionExecutionPlan: PaceActionExecutionPlan,
        configuredServers: [String: PaceMCPServerConfiguration] = PaceMCPServerRegistry.loadConfiguredServers()
    ) -> Bool {
        actionExecutionPlan.flattenedActions.allSatisfy { action in
            // Image generation creates a file even when the tool needs no approval dialog.
            if case .generateImage = action { return false }
            if case .mcp(let toolCall) = action {
                switch toolCall.serverName {
                case "peekaboo":
                    return (toolCall.toolName == "see" && toolCall.arguments["web_focus"] != .bool(true))
                        || (["app", "window"].contains(toolCall.toolName)
                            && toolCall.arguments["action"] == .string("list"))
                case "playwright":
                    return ["browser_snapshot", "browser_take_screenshot"].contains(toolCall.toolName)
                case "linear":
                    // The official endpoint exposes read tools only. Custom commands,
                    // extra bridge arguments, and write endpoints must fail closed.
                    guard let entry = PaceMCPServerCatalog.entry(forSlug: "linear") else { return false }
                    return configuredServers["linear"]
                        == PaceMCPServerConfiguration(
                            command: entry.command, args: entry.arguments)
                default:
                    return false
                }
            }
            return PaceToolRegistry.definition(for: action)?.riskLevel == .readOnly
        }
    }

    static func requiresExplicitApproval(
        for actionExecutionPlan: PaceActionExecutionPlan,
        preflightIssues: [PaceToolPreflightIssue] = []
    ) -> Bool {
        if preflightIssues.contains(where: { $0.severity == .blocking }) {
            return true
        }

        return actionExecutionPlan.flattenedActions.contains(where: requiresExplicitApproval)
    }

    static func shouldExecuteActions(
        request: PaceActionApprovalRequest?,
        decision: PaceActionApprovalDecision
    ) -> Bool {
        guard request != nil else {
            return true
        }
        return decision == .allowOnce
    }

    static func suppressesInitialSpokenFeedback(
        for actionExecutionPlan: PaceActionExecutionPlan,
        preflightIssues: [PaceToolPreflightIssue] = []
    ) -> Bool {
        let flattenedActions = actionExecutionPlan.flattenedActions
        guard !flattenedActions.isEmpty else { return false }
        guard !requiresExplicitApproval(
            for: actionExecutionPlan,
            preflightIssues: preflightIssues
        ) else {
            return false
        }

        return flattenedActions.allSatisfy(canRelyOnVisualOrObservationFeedback)
    }

    static func suppressesInitialSpokenFeedback(
        forPlannerResponseText plannerResponseText: String,
        preflightIssues: [PaceToolPreflightIssue] = []
    ) -> Bool {
        let parsedActions = PaceActionTagParser.parseActions(from: plannerResponseText)
        guard !parsedActions.executionPlan.flattenedActions.isEmpty else {
            return false
        }
        return suppressesInitialSpokenFeedback(
            for: parsedActions.executionPlan,
            preflightIssues: preflightIssues
        )
    }

    private static func requiresExplicitApproval(_ action: PaceParsedAction) -> Bool {
        switch action {
        case .createCalendarEvent, .createReminder, .createNote, .appendNote,
             .composeMail, .createThingsToDo, .runShortcut, .downloadFile,
             .recordFlow, .runFlow, .mcp:
            return true
        case .codingSession(let command): return command.requiresExecutionConsent
        case .openMessages(let messageRequest):
            return messageRequest.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        case .click, .doubleClick, .clickCandidates, .type, .setTextValue, .editSelectedText,
            .undoLastMutation, .pressKey, .readClipboard, .snapWindow, .scroll, .openApplication, .openBrowser,
            .screenCapture, .meeting, .codexSession,
             .openURL, .controlMusic, .adjustVolume, .adjustBrightness,
             .listCalendarEvents, .finder, .searchNotes, .startTimer,
            .generateImage, .showDiagram, .dismissDiagram, .drawAnnotation, .clearAnnotations, .presentMedia, .speak:
            return false
        }
    }

    /// Whether the parsed action is in the reversible-mutation set —
    /// i.e., the same set for which `canRelyOnVisualOrObservationFeedback`
    /// returns false. These actions get an undo banner because they
    /// produce a visible artifact the user can undo via `Undo.last` or
    /// app-specific delete. Irreversible inputs like `click` / `type`
    /// don't appear here because there's nothing to undo.
    ///
    /// Kept separate from `canRelyOnVisualOrObservationFeedback` so the
    /// reversibility list can evolve independently of the
    /// initial-spoken-feedback suppression policy.
    static func actionIsReversibleMutation(_ action: PaceParsedAction) -> Bool {
        switch action {
        case .createCalendarEvent, .createReminder, .createNote, .appendNote,
             .composeMail, .createThingsToDo, .runShortcut, .downloadFile,
            .recordFlow, .runFlow, .setTextValue, .editSelectedText:
            return true
        case .mcp:
            return !permitsObservationOnly(.serial(actions: [action]))
        case .codingSession: return false
        case .openMessages(let messageRequest):
            // Messages with body text creates a visible Messages draft;
            // opening Messages without body text doesn't.
            return messageRequest.text?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty == false
        case .click, .doubleClick, .clickCandidates, .type,
             .undoLastMutation, .pressKey, .readClipboard, .snapWindow, .scroll,
            .openApplication, .openBrowser, .screenCapture, .meeting, .codexSession, .openURL, .controlMusic,
            .adjustVolume, .adjustBrightness,
             .listCalendarEvents, .finder, .searchNotes, .startTimer,
            .generateImage, .showDiagram, .dismissDiagram, .drawAnnotation, .clearAnnotations, .presentMedia, .speak:
            return false
        }
    }

    private static func canRelyOnVisualOrObservationFeedback(_ action: PaceParsedAction) -> Bool {
        switch action {
        case .click, .doubleClick, .clickCandidates, .type, .setTextValue, .editSelectedText,
            .undoLastMutation, .pressKey, .readClipboard, .snapWindow, .scroll, .openApplication, .openBrowser,
            .screenCapture, .meeting, .codexSession,
             .openURL, .controlMusic, .adjustVolume, .adjustBrightness,
             .listCalendarEvents, .finder, .searchNotes, .startTimer,
            .dismissDiagram, .clearAnnotations, .presentMedia, .speak:
            // clearAnnotations: pure overlay cleanup, no speech needed.
            return true
        case .codingSession: return false
        case .openMessages(let messageRequest):
            return messageRequest.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
        case .createCalendarEvent, .createReminder, .createNote, .appendNote,
             .composeMail, .createThingsToDo, .runShortcut, .downloadFile,
             .recordFlow, .runFlow, .mcp,
            .generateImage, .showDiagram, .drawAnnotation:
            // drawAnnotation: the spoken narration IS the teaching
            // value — the drawing alone isn't sufficient feedback. So
            // do NOT suppress initial spoken feedback for this action,
            // even though it's read-only.
            return false
        }
    }
}
