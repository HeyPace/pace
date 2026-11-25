import EventKit
import Foundation
import Testing

@testable import Pace

struct PaceToDoPowerTests {
    @MainActor @Test func eventKitReminderCarriesItsDueTimeAndAlarm() throws {
        let date = try #require(ISO8601DateFormatter().date(from: "2026-11-22T14:00:00+05:30"))
        let request = PaceReminderRequest(
            title: "Pick up the library books", notes: nil, schedule: .init(date: date, isDateOnly: false)
        )
        let eventStore = EKEventStore()
        let reminder = EKReminder(eventStore: eventStore)
        reminder.title = "pick up  the library books"
        request.applySchedule(to: reminder)
        #expect(reminder.dueDateComponents?.calendar?.identifier == .gregorian)
        #expect(reminder.dueDateComponents?.date == date)
        #expect(reminder.alarms?.map(\.absoluteDate) == [date])
        #expect(request.matchesOpenReminder(reminder))

        let laterRequest = PaceReminderRequest(
            title: request.title, notes: nil, schedule: .init(date: date.addingTimeInterval(3_600), isDateOnly: false)
        )
        #expect(!laterRequest.matchesOpenReminder(reminder))
        #expect(!PaceReminderRequest(title: request.title, notes: nil).matchesOpenReminder(reminder))
        reminder.isCompleted = true
        #expect(!request.matchesOpenReminder(reminder))
    }

    @MainActor @Test func dateOnlyReminderDoesNotInventATimeOrAlarm() throws {
        let request = try #require(
            PaceActionTagParser.parseReminderRequest(from: [
                "title": .string("Check in with Sam"), "due": .string("2026-11-22"),
            ]))
        let eventStore = EKEventStore()
        let reminder = EKReminder(eventStore: eventStore)
        reminder.title = request.title
        request.applySchedule(to: reminder)
        #expect(reminder.dueDateComponents?.day == 22)
        #expect(reminder.dueDateComponents?.hour == nil)
        #expect(reminder.alarms?.isEmpty ?? true)
        #expect(request.matchesOpenReminder(reminder))
    }

    @MainActor @Test func appleMCPReminderCreationUsesTheSameNativeRequest() async throws {
        let nativeRequest = try #require(
            PaceActionTagParser.parseReminderRequest(from: [
                "title": .string("Pick up the library books"), "due": .string("2026-11-22T14:00:00+05:30"),
            ]))
        let toolCall = PaceMCPToolCall(
            serverName: "apple", toolName: "reminders",
            arguments: [
                "operation": .string("create"), "name": .string(nativeRequest.title),
                "dueDate": .string("2026-11-22T14:00:00+05:30"),
            ])
        let executor = PaceActionExecutor(actionsAreEnabledOverride: false)
        let native = await executor.createReminder(nativeRequest)
        let alias = await executor.callMCPTool(toolCall)
        #expect(alias.toolName == native.toolName)
        #expect(alias.summary == native.summary)
    }

    @Test func onlyFirstUseOnThisMacMayRequestRemindersAccess() {
        #expect(PacePermissionService.canPromptForReminders(status: .notDetermined, isForegroundRequest: true))
        #expect(!PacePermissionService.canPromptForReminders(status: .notDetermined, isForegroundRequest: false))
        #expect(!PacePermissionService.canPromptForReminders(status: .denied, isForegroundRequest: true))
        #expect(!PacePermissionService.canPromptForReminders(status: .restricted, isForegroundRequest: true))
        #expect(!PacePermissionService.canPromptForReminders(status: .fullAccess, isForegroundRequest: true))
    }

    @Test func parsesTypedAndSpokenToDoCommandsWithoutStealingOtherCommands() {
        #expect(PaceToDoPower.parse("Show my to-do list") == .list)
        #expect(PaceToDoPower.parse("what are my tasks ?") == .list)
        #expect(PaceToDoPower.parse("what are my tasks in Linear?") == nil)
        #expect(PaceToDoPower.parse("What’s on my to do list?") == .list)
        #expect(PaceToDoPower.parse("Run Power To-do List") == .list)
        #expect(PaceToDoPower.parse("Add Renew passport to my to-do list") == .add(title: "Renew passport"))
        #expect(PaceToDoPower.parse("Add task Check in with Sam.") == .add(title: "Check in with Sam"))
        #expect(
            PaceToDoPower.parse("Complete task Renew passport in list Personal")
                == .complete(title: "Renew passport", list: "Personal"))
        #expect(PaceToDoPower.parse("Complete task ") == nil)
        #expect(PaceToDoPower.parse("Open my to-do list in Chrome") == nil)
        #expect(PaceToDoPower.parse("Add a task manager to my dock") == nil)
    }

    @Test func completionPreservesAmbiguityAndRecognizesAlreadyCompletedTasks() {
        let personal = PaceReminderRetrievalSnapshot(
            stableIdentifier: "personal", title: "Renew passport",
            listTitle: "Personal", isCompleted: true)
        let work = PaceReminderRetrievalSnapshot(stableIdentifier: "work", title: "Renew passport", listTitle: "Work")
        let reminders = [personal, work]

        #expect(PaceToDoPower.completionMatches(title: "passport", list: nil, reminders: reminders).isEmpty)
        #expect(PaceToDoPower.completionMatches(title: "Renew passport", list: nil, reminders: reminders) == [work])
        let otherOpen = PaceReminderRetrievalSnapshot(
            stableIdentifier: "new-personal", title: "Renew passport",
            listTitle: "Personal")
        #expect(
            PaceToDoPower.completionMatches(title: "Renew passport", list: nil, reminders: reminders + [otherOpen])
                == [work, otherOpen])
        #expect(
            PaceToDoPower.completionMatches(
                title: "Renew passport", list: "Personal.", reminders: reminders + [otherOpen])
                == [otherOpen])
        #expect(
            PaceToDoPower.completionMatches(title: "Renew passport.", list: "personal", reminders: reminders) == [
                personal
            ])
        #expect(PaceToDoPower.completionMatches(title: "Renew passport", list: "Work", reminders: reminders) == [work])
    }

    @MainActor @Test func writtenReviewListsOpenTasksAndSpokenReviewIsShort() {
        let open = (1...15).map {
            PaceReminderRetrievalSnapshot(stableIdentifier: "task-\($0)", title: "Task \($0)")
        }
        let completed = PaceReminderRetrievalSnapshot(
            stableIdentifier: "completed", title: "Finished", isCompleted: true)
        let feedback = PaceToDoPower.listFeedback(open + [completed])
        #expect(feedback.written.contains("(15)"))
        #expect(feedback.written.contains("And 3 more"))
        #expect(!feedback.written.contains("Finished"))
        #expect(feedback.spoken.contains("15 open tasks"))
        #expect(feedback.spoken.contains("The list is in chat."))
    }
}
