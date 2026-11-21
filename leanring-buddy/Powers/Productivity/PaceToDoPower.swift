import EventKit
import Foundation

nonisolated enum PaceToDoPower {
    enum Command: Equatable {
        case list
        case add(title: String)
        case complete(title: String, list: String?)

        var operation: String {
            switch self {
            case .list: return "list"
            case .add: return "add"
            case .complete: return "complete"
            }
        }
    }

    static let definition = PacePowerDefinition(
        identifier: "pace.to-do",
        title: "To-do List",
        summary: "Review, add and complete tasks in Apple Reminders.",
        permissionsUsed: [.reminders],
        tools: [],
        promptContributions: [
            .init(order: 9, applies: { _ in true }, render: { _ in
                "The built-in To-do List Power uses Apple Reminders locally. Tell users they can say or type ‘Show my to-do list’, ‘Add task [title]’, or ‘Complete task [exact title]’. ‘Complete task [title] in list [name]’ selects a list. Do not claim that a task was modified without a host result."
            })
        ]
    )

    static func parse(_ input: String) -> Command? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["please ", "can you ", "could you "] where text.lowercased().hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let listWords = #"to[- ]?do(?: list)?"#
        let listPattern = #"^(?:(?:show|list|read)(?: me)? (?:my )?|(?:what['’]s|what is) on my |my )?"#
            + listWords + #"[.!?]*$"#
        let tasksPattern = #"^(?:what are my |(?:show|list|read)(?: me)? my )(?:open )?tasks\s*[.!?]*$"#
        let invocationPattern = #"^(?:run|show) (?:the )?(?:power )?(?:pace\.to-do|to[- ]?do list)(?: power)?[.!?]*$"#
        if text.range(of: listPattern, options: [.caseInsensitive, .regularExpression]) != nil
            || text.range(of: invocationPattern, options: [.caseInsensitive, .regularExpression]) != nil
            || text.range(of: tasksPattern, options: [.caseInsensitive, .regularExpression]) != nil {
            return .list
        }

        for prefix in ["add a task called ", "add task ", "add to my to-do list "] where text.lowercased().hasPrefix(prefix) {
            return taskName(String(text.dropFirst(prefix.count))).map { .add(title: $0) }
        }
        if text.lowercased().hasPrefix("add "),
           let suffix = text.range(of: #" to my to[- ]?do list[.!?]*$"#, options: [.caseInsensitive, .regularExpression]) {
            return taskName(String(text.dropFirst(4)[..<suffix.lowerBound])).map { .add(title: $0) }
        }
        for prefix in ["complete task ", "complete to-do ", "finish task "] where text.lowercased().hasPrefix(prefix) {
            let target = String(text.dropFirst(prefix.count))
            if let separator = target.range(of: " in list ", options: [.caseInsensitive, .backwards]) {
                guard let title = taskName(String(target[..<separator.lowerBound])),
                      let list = taskName(String(target[separator.upperBound...])) else { return nil }
                return .complete(title: title, list: list)
            }
            return taskName(target).map { .complete(title: $0, list: nil) }
        }
        return nil
    }

    private static func taskName(_ text: String) -> String? {
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 250 else { return nil }
        return name
    }

    static func completionMatches(
        title: String, list: String?, reminders: [PaceReminderRetrievalSnapshot]
    ) -> [PaceReminderRetrievalSnapshot] {
        let matching = reminders.filter { reminder in
            sameTaskTitle(reminder.title, title)
                && (list.map { sameTaskTitle(reminder.listTitle ?? "", $0) } ?? true)
        }
        let openMatches = matching.filter { !$0.isCompleted }
        return openMatches.isEmpty ? matching : openMatches
    }

    static func sameTaskTitle(_ first: String, _ second: String) -> Bool {
        let sentencePunctuation = CharacterSet(charactersIn: ".!?")
        return sameName(first.trimmingCharacters(in: sentencePunctuation), second.trimmingCharacters(in: sentencePunctuation))
    }

    static func sameName(_ first: String, _ second: String) -> Bool {
        first.trimmingCharacters(in: .whitespacesAndNewlines).compare(
            second.trimmingCharacters(in: .whitespacesAndNewlines),
            options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }

    private static func compactTitle(_ title: String) -> String {
        String(title.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(120))
    }

    @MainActor
    static func listFeedback(_ reminders: [PaceReminderRetrievalSnapshot]) -> (written: String, spoken: String) {
        let open = reminders.filter { !$0.isCompleted }.sorted(by: PaceRemindersRetrievalConnector.shouldSortBefore)
        guard !open.isEmpty else { return ("Your to-do list is clear.", "Your to-do list is clear.") }
        let lines = open.prefix(12).map { reminder in
            var line = "• " + compactTitle(reminder.title)
            if let list = reminder.listTitle { line += " · " + compactTitle(list) }
            if let due = reminder.dueDate { line += " · " + due.formatted(date: .abbreviated, time: .omitted) }
            return line
        }
        let remainder = open.count > lines.count ? "\nAnd \(open.count - lines.count) more in Apple Reminders." : ""
        let written = "Open in Apple Reminders (\(open.count)):\n" + lines.joined(separator: "\n") + remainder
        let names = open.prefix(3).map { compactTitle($0.title) }.joined(separator: ", ")
        let spoken = "You have \(open.count) open \(open.count == 1 ? "task" : "tasks"). \(names)." +
            (open.count > 3 ? " The list is in chat." : "")
        return (written, spoken)
    }
}

@MainActor
extension CompanionManager {
    func handleToDoPower(
        _ command: PaceToDoPower.Command, transcript: String, turnLease: PaceTurnLease, allowsPermissionPrompt: Bool
    ) async {
        guard isActiveTurn(turnLease) else { return }
        func respond(_ text: String, outcome: String, spokenSummary: String? = nil) {
            guard isActiveTurn(turnLease) else { return }
            PaceAPIAuditLog.shared.record(subsystem: "reminders", operation: command.operation,
                target: "EventKit", durationMilliseconds: 0, outcome: outcome)
            recordConversationTurn(userTranscript: transcript, assistantResponse: text, recordsAssistantDerivedMemory: false)
            handleImmediateLocalModeResponse(transcript: transcript, spokenText: text,
                shouldRecordConversationTurn: false, spokenSummary: spokenSummary, showsResponseOverlay: false)
        }

        if command != .list, !actionExecutor.actionsAreEnabled {
            respond("Enable Pace actions to change tasks in Apple Reminders.", outcome: "actions_disabled")
            return
        }
        let accessStatus = EKEventStore.authorizationStatus(for: .reminder)
        if PacePermissionService.canPromptForReminders(
            status: accessStatus, isForegroundRequest: allowsPermissionPrompt && activePacePadTurnIdentifier == nil
        ) {
            currentTurnHUDState = .understanding("Waiting for Apple Reminders permission…")
            revealRequestFeedback()
            PaceAPIAuditLog.shared.record(subsystem: "reminders", operation: "permission_prompt",
                target: "EventKit", durationMilliseconds: 0, outcome: "requested")
            let granted = await PacePermissionService.shared.requestRemindersAccess(using: permissionEventStore)
            refreshAllPermissions()
            guard isActiveTurn(turnLease) else { return }
            guard granted else {
                respond("Reminders access wasn’t granted. You can enable it in Pace Settings → Permissions.",
                    outcome: "permission_missing")
                return
            }
        }
        guard PaceActionExecutor.isEventKitAccessAlreadyGranted(for: .reminder) else {
            if accessStatus == .notDetermined, !allowsPermissionPrompt {
                respond("Ask Pace for your to-do list in chat or by voice to request Reminders access.", outcome: "permission_missing")
            } else {
                respond("Enable Apple Reminders access in Pace Settings → Permissions to use your to-do list.", outcome: "permission_missing")
            }
            return
        }
        if case .add(let title) = command {
            let request = PaceReminderRequest(title: title, notes: nil)
            guard requestUserApprovalForActionPlan(.serial(actions: [.createReminder(request)])) else {
                respond("Cancelled adding the task.", outcome: "cancelled")
                return
            }
            guard isActiveTurn(turnLease) else { return }
            let result = await actionExecutor.createReminder(request, maySave: { self.isActiveTurn(turnLease) })
            guard isActiveTurn(turnLease) else { return }
            let outcome: String
            switch result.summary {
            case let summary where summary.hasPrefix("Created reminder:"): outcome = "created"
            case let summary where summary.hasPrefix("Already in Apple Reminders:"): outcome = "already_exists"
            case let summary where summary.hasPrefix("Already saving reminder:"): outcome = "already_saving"
            default: outcome = "failed"
            }
            respond(result.summary, outcome: outcome)
            return
        }

        let eventStore = actionExecutor.eventStore
        let connector = PaceRemindersRetrievalConnector(eventStore: eventStore)
        let predicate: NSPredicate
        if command == .list {
            predicate = eventStore.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        } else {
            predicate = eventStore.predicateForReminders(in: nil)
        }
        let reminders = await connector.fetchReminders(matching: predicate)
        guard isActiveTurn(turnLease) else { return }
        guard PaceActionExecutor.isEventKitAccessAlreadyGranted(for: .reminder) else {
            respond("Apple Reminders access changed. Check Pace Settings → Permissions.", outcome: "permission_missing")
            return
        }
        guard let reminders else {
            respond("Apple Reminders didn’t return your tasks. Try again.", outcome: "fetch_failed")
            return
        }
        let snapshots = reminders.map(PaceReminderRetrievalSnapshot.init(reminder:))
        if command == .list {
            let feedback = PaceToDoPower.listFeedback(snapshots)
            respond(feedback.written, outcome: "listed", spokenSummary: feedback.spoken)
            return
        }
        guard case .complete(let title, let list) = command else { return }
        let matches = PaceToDoPower.completionMatches(title: title, list: list, reminders: snapshots)
        guard let match = matches.first else {
            respond("I couldn’t find an exact match for “\(title).” Say “Show my to-do list” to check the task name.", outcome: "no_match")
            return
        }
        guard !match.isCompleted else {
            respond("“\(match.title)” is already complete.", outcome: "already_complete")
            return
        }
        guard matches.count == 1 else {
            let lists = Set(matches.compactMap(\.listTitle)).sorted()
            let hint = (list == nil && lists.count > 1)
                ? " Say “Complete task \(title) in list [name].” Matching lists: \(lists.prefix(6).joined(separator: ", "))."
                : " Open Apple Reminders to choose the exact item."
            respond("More than one task matches “\(title).”" + hint, outcome: "ambiguous")
            return
        }
        let selectedList = match.listTitle.map { " in “\($0)”" } ?? ""
        if let approval = PaceActionApprovalRequest(
            approvalSummary: "Complete “\(match.title)”\(selectedList) in Apple Reminders.",
            requiresActionApproval: requiresActionApproval
        ), !presentActionApproval(approval) {
            respond("Cancelled completing the task.", outcome: "cancelled")
            return
        }
        guard isActiveTurn(turnLease) else { return }
        guard PaceActionExecutor.isEventKitAccessAlreadyGranted(for: .reminder) else {
            respond("Apple Reminders access changed. Check Pace Settings → Permissions.", outcome: "permission_missing")
            return
        }
        guard let reminder = eventStore.calendarItem(withIdentifier: match.stableIdentifier) as? EKReminder,
              let calendar = reminder.calendar, calendar.allowsContentModifications,
              PaceToDoPower.sameTaskTitle(reminder.title ?? "", title),
              PaceToDoPower.sameName(calendar.title, match.listTitle ?? "") else {
            respond("That task changed or can’t be edited. Check it in Apple Reminders and retry.", outcome: "item_unavailable")
            return
        }
        guard !reminder.isCompleted else {
            respond("“\(match.title)” is already complete.", outcome: "already_complete")
            return
        }
        do {
            reminder.isCompleted = true
            try eventStore.save(reminder, commit: true)
            respond("Completed “\(match.title)” in Apple Reminders.", outcome: "completed")
        } catch {
            respond("Apple Reminders couldn’t complete “\(match.title).” Try again.", outcome: "save_failed")
        }
    }
}
