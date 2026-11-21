//
//  PaceActionExecutor+SystemToolsCalendarReminders.swift
//  leanring-buddy
//
//  Extracted from PaceActionExecutor.swift (god-class decomposition Phase B):
//  Calendar and Reminders EventKit tools.
//

import EventKit
import Foundation

@MainActor
extension PaceActionExecutor {

    // MARK: - System tools (calendar & reminders)

    func listCalendarEvents(_ calendarQuery: PaceCalendarQuery) async -> PaceActionExecutionObservation {
        print("🧰 Calendar list \(calendarQuery.range.rawValue) (enabled: \(actionsAreEnabled))")
        guard actionsAreEnabled else {
            return PaceActionExecutionObservation(
                toolName: "calendar",
                summary: "Would list calendar events for \(calendarQuery.range.displayName)."
            )
        }

        guard await requestCalendarAccessIfNeeded() else {
            return PaceActionExecutionObservation(
                toolName: "calendar",
                summary: "Calendar access not granted. Open System Settings → Privacy & Security → Calendars and toggle Pace on."
            )
        }

        let now = Date()
        let dateInterval = calendarQuery.dateInterval(relativeTo: now)
        let predicate = eventStore.predicateForEvents(
            withStart: dateInterval.start,
            end: dateInterval.end,
            calendars: nil
        )
        let matchingEvents = eventStore.events(matching: predicate)
            .filter { $0.endDate >= now }
            .sorted { $0.startDate < $1.startDate }
            .prefix(12)

        guard !matchingEvents.isEmpty else {
            return PaceActionExecutionObservation(
                toolName: "calendar",
                summary: "No calendar events found for \(calendarQuery.range.displayName)."
            )
        }

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short

        let eventSummaries = matchingEvents.map { event in
            let title = event.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            let safeTitle = title?.isEmpty == false ? title! : "Untitled event"
            let locationSuffix: String = {
                guard let location = event.location?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !location.isEmpty else {
                    return ""
                }
                return " at \(location)"
            }()
            return "\(formatter.string(from: event.startDate)): \(safeTitle)\(locationSuffix)"
        }

        return PaceActionExecutionObservation(
            toolName: "calendar",
            summary: "Calendar events for \(calendarQuery.range.displayName):\n" + eventSummaries.joined(separator: "\n")
        )
    }

    func createCalendarEvent(
        _ calendarEventRequest: PaceCalendarEventRequest
    ) async -> PaceActionExecutionObservation {
        print("🧰 Calendar create \"\(calendarEventRequest.title)\" (enabled: \(actionsAreEnabled))")
        guard actionsAreEnabled else {
            return PaceActionExecutionObservation(
                toolName: "calendar_create",
                summary: "Would create calendar event: \(calendarEventRequest.displaySummary)"
            )
        }

        guard await requestCalendarAccessIfNeeded() else {
            return PaceActionExecutionObservation(
                toolName: "calendar_create",
                summary: "Calendar access not granted. Open System Settings → Privacy & Security → Calendars and toggle Pace on."
            )
        }

        guard let targetCalendar = calendarForNewEvent(matching: calendarEventRequest.calendarTitle) else {
            return PaceActionExecutionObservation(
                toolName: "calendar_create",
                summary: "Could not find a writable calendar."
            )
        }

        let event = EKEvent(eventStore: eventStore)
        event.calendar = targetCalendar
        event.title = calendarEventRequest.title
        event.startDate = calendarEventRequest.startDate
        event.endDate = calendarEventRequest.endDate
        event.isAllDay = calendarEventRequest.isAllDay
        event.notes = calendarEventRequest.notes
        event.location = calendarEventRequest.location

        do {
            try eventStore.save(event, span: .thisEvent, commit: true)
            return PaceActionExecutionObservation(
                toolName: "calendar_create",
                summary: "Created calendar event: \(calendarEventRequest.displaySummary)"
            )
        } catch {
            return PaceActionExecutionObservation(
                toolName: "calendar_create",
                summary: "Failed to create calendar event: \(error.localizedDescription)"
            )
        }
    }

    func calendarForNewEvent(matching requestedCalendarTitle: String?) -> EKCalendar? {
        guard let requestedCalendarTitle = requestedCalendarTitle?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !requestedCalendarTitle.isEmpty else {
            return eventStore.defaultCalendarForNewEvents
        }

        let matchingCalendar = eventStore
            .calendars(for: .event)
            .first { calendar in
                calendar.allowsContentModifications
                    && calendar.title.compare(
                        requestedCalendarTitle,
                        options: [.caseInsensitive, .diacriticInsensitive]
                    ) == .orderedSame
            }

        return matchingCalendar ?? eventStore.defaultCalendarForNewEvents
    }

    func createReminder(_ reminderRequest: PaceReminderRequest, maySave: () -> Bool = { true }) async -> PaceActionExecutionObservation {
        print("🧰 Create reminder \"\(reminderRequest.title)\" (enabled: \(actionsAreEnabled))")
        guard actionsAreEnabled else {
            return PaceActionExecutionObservation(
                toolName: "reminder",
                summary: "Would create reminder: \(reminderRequest.displayTitle)"
            )
        }

        let creationGeneration = applicationTargetGeneration
        guard await requestReminderAccessIfNeeded() else {
            return PaceActionExecutionObservation(
                toolName: "reminder",
                summary: "Reminders access not granted. Open System Settings → Privacy & Security → Reminders and toggle Pace on."
            )
        }

        guard creationGeneration == applicationTargetGeneration, maySave(), !Task.isCancelled else {
            return PaceActionExecutionObservation(toolName: "reminder", summary: "Reminder creation cancelled.")
        }
        let reminderCalendar: EKCalendar
        if let listName = reminderRequest.listName {
            let matchingLists = eventStore.calendars(for: .reminder).filter { list in
                list.allowsContentModifications && list.title.caseInsensitiveCompare(listName) == .orderedSame
            }
            guard matchingLists.count == 1, let matchingList = matchingLists.first else {
                let reason = matchingLists.isEmpty
                    ? "Could not find a writable Reminders list called \(listName)."
                    : "More than one Reminders list is called \(listName)."
                return PaceActionExecutionObservation(toolName: "reminder", summary: reason)
            }
            reminderCalendar = matchingList
        } else {
            guard let defaultList = eventStore.defaultCalendarForNewReminders() else {
                return PaceActionExecutionObservation(toolName: "reminder", summary: "Could not find a default reminders list.")
            }
            reminderCalendar = defaultList
        }

        let key = ReminderCreationKey(
            calendarIdentifier: reminderCalendar.calendarIdentifier,
            title: PaceReminderRequest.comparisonTitle(reminderRequest.title),
            dueDateComponents: reminderRequest.dueDateComponents
        )
        let existingReminder = PaceActionExecutionObservation(
            toolName: "reminder",
            summary: "Already in Apple Reminders: \(reminderRequest.displayTitle)"
        )
        if remindersSavedThisTurn.contains(key) { return existingReminder }
        guard reminderCreationsInFlight.insert(key).inserted else {
            return PaceActionExecutionObservation(
                toolName: "reminder",
                summary: "Already saving reminder: \(reminderRequest.displayTitle)"
            )
        }
        defer { reminderCreationsInFlight.remove(key) }

        let connector = PaceRemindersRetrievalConnector(eventStore: eventStore)
        let predicate = eventStore.predicateForIncompleteReminders(
            withDueDateStarting: nil, ending: nil, calendars: [reminderCalendar]
        )
        let openReminders = await connector.fetchReminders(matching: predicate)
        guard creationGeneration == applicationTargetGeneration, maySave(), !Task.isCancelled, actionsAreEnabled else {
            return PaceActionExecutionObservation(toolName: "reminder", summary: "Reminder creation cancelled.")
        }
        guard let openReminders else {
            return PaceActionExecutionObservation(
                toolName: "reminder",
                summary: "Could not check the existing reminders. Try again."
            )
        }
        if openReminders.contains(where: reminderRequest.matchesOpenReminder) { return existingReminder }

        let reminder = EKReminder(eventStore: eventStore)
        reminder.calendar = reminderCalendar
        reminder.title = reminderRequest.title
        reminder.notes = reminderRequest.notes
        reminderRequest.applySchedule(to: reminder)

        do {
            try eventStore.save(reminder, commit: true)
            remindersSavedThisTurn.insert(key)
            return PaceActionExecutionObservation(
                toolName: "reminder",
                summary: "Created reminder: \(reminderRequest.displayTitle)"
            )
        } catch {
            return PaceActionExecutionObservation(
                toolName: "reminder",
                summary: "Failed to create reminder: \(error.localizedDescription)"
            )
        }
    }

}

extension PaceReminderRequest {
    var dueDateComponents: DateComponents? {
        guard let schedule else { return nil }
        // EventKit requires Gregorian components even on Macs using another calendar.
        var calendar = Calendar(identifier: .gregorian)
        let localTimeZone = TimeZone.current
        calendar.timeZone = TimeZone(secondsFromGMT: localTimeZone.secondsFromGMT(for: schedule.date)) ?? localTimeZone
        let fields: Set<Calendar.Component> = schedule.isDateOnly
            ? [.year, .month, .day]
            : [.year, .month, .day, .hour, .minute]
        var components = calendar.dateComponents(fields, from: schedule.date)
        components.calendar = calendar
        if !schedule.isDateOnly {
            components.timeZone = calendar.timeZone
        }
        return components
    }

    func applySchedule(to reminder: EKReminder) {
        reminder.dueDateComponents = dueDateComponents
        if let schedule, !schedule.isDateOnly {
            reminder.addAlarm(EKAlarm(absoluteDate: schedule.date))
        }
    }

    func matchesOpenReminder(_ reminder: EKReminder) -> Bool {
        guard !reminder.isCompleted, Self.comparisonTitle(reminder.title ?? "") == Self.comparisonTitle(title) else {
            return false
        }
        guard let expected = dueDateComponents else { return reminder.dueDateComponents == nil }
        guard let actual = reminder.dueDateComponents else { return false }
        if expected.hour == nil {
            return actual.hour == nil && expected.year == actual.year && expected.month == actual.month
                && expected.day == actual.day
        }
        guard actual.hour != nil, let requestedDate = schedule?.date else { return false }
        let actualDate = actual.date ?? Calendar.current.date(from: actual)
        return actualDate.map { Calendar.current.isDate($0, equalTo: requestedDate, toGranularity: .minute) } ?? false
    }
}
