import EventKit
import Foundation
import Testing
@testable import Pace

struct PaceToDoPowerTests {
    @Test func onlyFirstUseOnThisMacMayRequestRemindersAccess() {
        #expect(PacePermissionService.canPromptForReminders(status: .notDetermined, isForegroundRequest: true))
        #expect(!PacePermissionService.canPromptForReminders(status: .notDetermined, isForegroundRequest: false))
        #expect(!PacePermissionService.canPromptForReminders(status: .denied, isForegroundRequest: true))
        #expect(!PacePermissionService.canPromptForReminders(status: .restricted, isForegroundRequest: true))
        #expect(!PacePermissionService.canPromptForReminders(status: .fullAccess, isForegroundRequest: true))
    }

    @Test func parsesTypedAndSpokenToDoCommandsWithoutStealingOtherCommands() {
        #expect(PaceToDoPower.parse("Show my to-do list") == .list)
        #expect(PaceToDoPower.parse("What’s on my to do list?") == .list)
        #expect(PaceToDoPower.parse("Run Power To-do List") == .list)
        #expect(PaceToDoPower.parse("Add Renew passport to my to-do list") == .add(title: "Renew passport"))
        #expect(PaceToDoPower.parse("Add task Check in with Sam.") == .add(title: "Check in with Sam"))
        #expect(PaceToDoPower.parse("Complete task Renew passport in list Personal")
            == .complete(title: "Renew passport", list: "Personal"))
        #expect(PaceToDoPower.parse("Complete task ") == nil)
        #expect(PaceToDoPower.parse("Open my to-do list in Chrome") == nil)
        #expect(PaceToDoPower.parse("Add a task manager to my dock") == nil)
    }

    @Test func completionPreservesAmbiguityAndRecognizesAlreadyCompletedTasks() {
        let personal = PaceReminderRetrievalSnapshot(stableIdentifier: "personal", title: "Renew passport",
            listTitle: "Personal", isCompleted: true)
        let work = PaceReminderRetrievalSnapshot(stableIdentifier: "work", title: "Renew passport", listTitle: "Work")
        let reminders = [personal, work]

        #expect(PaceToDoPower.completionMatches(title: "passport", list: nil, reminders: reminders).isEmpty)
        #expect(PaceToDoPower.completionMatches(title: "Renew passport", list: nil, reminders: reminders) == [work])
        let otherOpen = PaceReminderRetrievalSnapshot(stableIdentifier: "new-personal", title: "Renew passport",
            listTitle: "Personal")
        #expect(PaceToDoPower.completionMatches(title: "Renew passport", list: nil, reminders: reminders + [otherOpen])
            == [work, otherOpen])
        #expect(PaceToDoPower.completionMatches(title: "Renew passport", list: "Personal.", reminders: reminders + [otherOpen])
            == [otherOpen])
        #expect(PaceToDoPower.completionMatches(title: "Renew passport.", list: "personal", reminders: reminders) == [personal])
        #expect(PaceToDoPower.completionMatches(title: "Renew passport", list: "Work", reminders: reminders) == [work])
    }

    @MainActor @Test func writtenReviewListsOpenTasksAndSpokenReviewIsShort() {
        let open = (1...15).map {
            PaceReminderRetrievalSnapshot(stableIdentifier: "task-\($0)", title: "Task \($0)")
        }
        let completed = PaceReminderRetrievalSnapshot(stableIdentifier: "completed", title: "Finished", isCompleted: true)
        let feedback = PaceToDoPower.listFeedback(open + [completed])
        #expect(feedback.written.contains("(15)"))
        #expect(feedback.written.contains("And 3 more"))
        #expect(!feedback.written.contains("Finished"))
        #expect(feedback.spoken.contains("15 open tasks"))
        #expect(feedback.spoken.contains("The list is in chat."))
    }
}
