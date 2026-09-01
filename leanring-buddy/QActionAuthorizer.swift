//
//  QActionAuthorizer.swift
//  leanring-buddy
//
//  Q Security Architecture — Pace Action Authorization Integration (Phase 1c.7).
//  Bridges Pace's action executor and tool registry with the Q Permission Gate,
//  Resource Guard, and Audit Logger.
//

import Foundation

struct QActionAuthorizationBridge {

    /// Maps a PaceParsedAction to its canonical Q tool name, tool family, and base risk level.
    static func mapActionToQMetadata(_ action: PaceParsedAction) -> (toolName: String, toolFamily: String, risk: QCapabilityLevel, affectedResources: [String]) {
        switch action {
        case .click, .doubleClick, .clickCandidates:
            return ("input.click", "input", .level2UserApproval, [])
        case .type, .setTextValue, .editSelectedText:
            return ("input.type", "input", .level2UserApproval, [])
        case .pressKey:
            return ("input.key", "input", .level2UserApproval, [])
        case .readClipboard:
            return ("system.clipboard.read", "system", .level0ReadOnly, [])
        case .undoLastMutation:
            return ("system.undo", "system", .level1SafeLocalAction, [])
        case .snapWindow, .scroll:
            return ("window.manage", "window", .level1SafeLocalAction, [])
        case .openApplication(let appName):
            return ("app.launch", "app", .level1SafeLocalAction, [appName])
        case .openURL(let url):
            return ("net.open_url", "net", .level2UserApproval, [url])
        case .controlMusic, .adjustVolume, .adjustBrightness, .startTimer:
            return ("system.media", "system", .level1SafeLocalAction, [])
        case .listCalendarEvents:
            return ("calendar.read", "calendar", .level0ReadOnly, [])
        case .createCalendarEvent:
            return ("calendar.create", "calendar", .level2UserApproval, [])
        case .createReminder:
            return ("reminders.create", "reminders", .level2UserApproval, [])
        case .finder(let req):
            return ("fs.finder", "fs", .level1SafeLocalAction, [req.path])
        case .createNote, .appendNote:
            return ("notes.write", "notes", .level2UserApproval, [])
        case .searchNotes:
            return ("notes.search", "notes", .level0ReadOnly, [])
        case .composeMail(let draft):
            return ("mail.compose", "mail", .level3HighRisk, [draft.recipients.joined(separator: ", ")])
        case .createThingsToDo:
            return ("things.create", "things", .level2UserApproval, [])
        case .runShortcut(let shortcut):
            return ("shortcuts.run", "shortcuts", .level2UserApproval, [shortcut])
        case .openMessages:
            return ("messages.open", "messages", .level2UserApproval, [])
        case .downloadFile(let downloadReq):
            return ("net.download", "net", .level3HighRisk, [downloadReq.url.absoluteString])
        case .recordFlow, .runFlow:
            return ("flow.manage", "flow", .level2UserApproval, [])
        case .mcp(let toolCall):
            return ("mcp.\(toolCall.toolName)", "mcp", .level2UserApproval, [toolCall.serverName])
        case .drawAnnotation, .clearAnnotations:
            return ("ui.annotation", "ui", .level0ReadOnly, [])
        }
    }

    /// Pre-execution security check: validates resource paths with Resource Guard
    /// and authorizes against Permission Gate.
    static func preflightAuthorize(
        action: PaceParsedAction,
        taskId: String = "session",
        isContextTainted: Bool = false
    ) -> QAuthorizationDecision {
        let meta = mapActionToQMetadata(action)

        // 1. Filesystem Resource Guard check for path-bearing actions
        if case .finder(let req) = action, !req.path.isEmpty {
            let guardOutcome = QResourceGuard.validate(path: req.path)
            if case .denied(let reason, let violation) = guardOutcome {
                return .deny(reason: reason, violation: violation)
            }
        }

        // 2. Permission Gate evaluation
        let authReq = QToolAuthorizationRequest(
            taskId: taskId,
            toolName: meta.toolName,
            toolFamily: meta.toolFamily,
            baseRisk: meta.risk,
            literalAction: action.approvalDescription,
            affectedResources: meta.affectedResources,
            isContextTainted: isContextTainted
        )

        return QPermissionGate.shared.evaluate(request: authReq)
    }
}
