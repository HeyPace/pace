//
//  PaceTasksSettingsTab.swift
//  leanring-buddy
//
//  Settings → Tasks: typed schedule creation, cadence controls, and durable
//  background results with explicit cancellation and reviewed retry.

import SwiftUI

struct PaceTasksSettingsTab: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject private var cronScheduler = PaceCronScheduler.shared
    @ObservedObject private var backgroundRunner = PaceBackgroundAgentRunner.shared
    @State private var newTaskCommand = ""
    @State private var creationFeedback: String?
    @State private var taskToRetry: PaceBackgroundAgentTask?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Scheduled tasks")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Colors.textSecondary)
                Text(
                    "Recurring things Pace runs for you on a timer. Type a command below or in Conversation — for example, \"every morning at 9, summarize my calendar\" or \"every 2 hours remind me to stand up\"."
                )
                .font(.system(size: 12))
                .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
                .background(DS.Colors.borderSubtle)

            paceSettingsToggleRow(
                title: "Enable scheduling",
                subtitle: "Runs while Pace is open. Missed intervals become one run after wake or restart.",
                isOn: Binding(get: { cronScheduler.isEnabled }, set: { cronScheduler.setEnabled($0) }))
            if let persistenceError = cronScheduler.persistenceError {
                Text(persistenceError).font(.system(size: 12)).foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            TextField("Every 2 hours remind me to stand up", text: $newTaskCommand)
                .textFieldStyle(.roundedBorder)
                .onSubmit { addTaskFromCommand() }
            paceSettingsButton("Add task", systemName: "plus") { addTaskFromCommand() }
            if let creationFeedback {
                Text(creationFeedback).font(.system(size: 12)).foregroundColor(DS.Colors.textSecondary)
            }
            Text(
                "Background runs read-only summaries, research, or drafts. They do not send messages or change files. Review interrupted runs before retrying."
            )
            .font(.system(size: 12)).foregroundColor(DS.Colors.textTertiary).fixedSize(
                horizontal: false, vertical: true)
            scheduledTasksSection
            Divider().background(DS.Colors.borderSubtle)
            backgroundTasksSection
        }
        .alert(
            "Restart this task?",
            isPresented: Binding(get: { taskToRetry != nil }, set: { if !$0 { taskToRetry = nil } })
        ) {
            Button("Cancel", role: .cancel) { taskToRetry = nil }
            Button("Restart") {
                if let taskToRetry, !backgroundRunner.retry(taskId: taskToRetry.id) {
                    creationFeedback =
                        backgroundRunner.persistenceError ?? "This task cannot be restarted in its current state."
                }
                taskToRetry = nil
            }
        } message: {
            Text(
                "Retry starts the original prompt from the beginning. Review its prior result first; this does not resume from a checkpoint."
            )
        }
    }

    private func addTaskFromCommand() {
        guard let task = PaceCronScheduler.parseVoiceCommand(newTaskCommand) else {
            creationFeedback = "Use ‘every 2 hours …’ or ‘every morning at 9 …’ with a positive interval."
            return
        }
        guard cronScheduler.addTask(task) else {
            creationFeedback = cronScheduler.persistenceError ?? "That task is already scheduled."
            return
        }
        cronScheduler.setEnabled(true)
        creationFeedback = "Scheduled: \(task.displayName)"
        newTaskCommand = ""
    }

    private var backgroundTasksSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Background results").font(.system(size: 13, weight: .semibold)).foregroundColor(
                DS.Colors.textSecondary)
            if let persistenceError = backgroundRunner.persistenceError {
                Text(persistenceError).font(.system(size: 12)).foregroundColor(DS.Colors.textSecondary)
            }
            if backgroundRunner.tasks.isEmpty {
                Text("No background runs yet. Results stay here after restarting Pace.").font(.system(size: 12))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            ForEach(backgroundRunner.tasks.reversed()) { task in
                VStack(alignment: .leading, spacing: 6) {
                    Text(task.displayName).font(.system(size: 13, weight: .medium)).foregroundColor(
                        DS.Colors.textPrimary)
                    Text(backgroundRunner.taskDescription(task)).font(.system(size: 12)).foregroundColor(
                        DS.Colors.textSecondary
                    ).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        if task.state == .running || task.state == .queued {
                            paceSettingsButton("Cancel", systemName: "stop") {
                                backgroundRunner.cancel(taskId: task.id)
                            }
                        }
                        switch task.state {
                        case .interrupted, .failed, .cancelled:
                            paceSettingsButton("Review and retry", systemName: "arrow.clockwise") { taskToRetry = task }
                        default: EmptyView()
                        }
                    }
                }.padding(.vertical, 8)
                Divider().background(DS.Colors.borderSubtle)
            }
        }
    }

    private var scheduledTasksSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recurring tasks")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(DS.Colors.textSecondary)

            if cronScheduler.tasks.isEmpty {
                Text(
                    "No scheduled tasks yet. Type something like \"every morning at 9, summarize my calendar\" and it'll show up here."
                )
                .font(.system(size: 12))
                .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 6)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(cronScheduler.tasks) { task in
                        scheduledTaskRow(task)
                    }
                }
            }
        }
    }

    private func scheduledTaskRow(_ task: PaceCronTask) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(task.displayName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Text(Self.humanizedInterval(task.intervalSeconds))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.textTertiary)
                    if task.skipWeekends {
                        Text("· Skips weekends")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(DS.Colors.textTertiary)
                    }
                }
                if task.isPaused == true {
                    Text("Paused").font(.system(size: 11, weight: .medium)).foregroundColor(DS.Colors.textSecondary)
                } else if let nextRunAt = task.nextRunAt {
                    Text("Next run: \(nextRunAt.formatted(date: .abbreviated, time: .shortened))").font(
                        .system(size: 11)
                    ).foregroundColor(DS.Colors.textTertiary)
                }
                if let lastError = task.lastError {
                    Text(lastError).font(.system(size: 11)).foregroundColor(DS.Colors.textSecondary).fixedSize(
                        horizontal: false, vertical: true)
                }
                Text(Self.lastRunDescription(for: task.lastRunAt))
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            Spacer(minLength: 0)
            paceSettingsButton(
                task.isPaused == true ? "Enable" : "Pause future runs",
                systemName: task.isPaused == true ? "play" : "pause"
            ) {
                cronScheduler.setTaskPaused(id: task.id, paused: task.isPaused != true)
            }
            paceSettingsButton("Delete schedule", systemName: "trash") {
                cronScheduler.removeTask(id: task.id)
            }
        }
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) {
            Divider().background(DS.Colors.borderSubtle)
        }
    }

    // MARK: - Formatting helpers

    /// Renders an interval in seconds as a human-readable cadence, e.g.
    /// "Every 30 minutes", "Every 2 hours", or "Daily". Pure so it can
    /// be unit-tested without a scheduler or a view.
    static func humanizedInterval(_ intervalSeconds: TimeInterval) -> String {
        guard PaceCronScheduler.isValidInterval(intervalSeconds) else { return "Invalid interval" }
        let totalSeconds = Int(intervalSeconds.rounded())
        guard totalSeconds > 0 else { return "Every moment" }

        let secondsPerMinute = 60
        let secondsPerHour = 3_600
        let secondsPerDay = 86_400

        if totalSeconds == secondsPerDay {
            return "Daily"
        }
        if totalSeconds % secondsPerDay == 0 {
            let dayCount = totalSeconds / secondsPerDay
            return "Every \(dayCount) days"
        }
        if totalSeconds == secondsPerHour {
            return "Every hour"
        }
        if totalSeconds % secondsPerHour == 0 {
            let hourCount = totalSeconds / secondsPerHour
            return "Every \(hourCount) hours"
        }
        if totalSeconds == secondsPerMinute {
            return "Every minute"
        }
        if totalSeconds % secondsPerMinute == 0 {
            let minuteCount = totalSeconds / secondsPerMinute
            return "Every \(minuteCount) minutes"
        }
        if totalSeconds == 1 {
            return "Every second"
        }
        return "Every \(totalSeconds) seconds"
    }

    private static let relativeDateTimeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    private static func lastRunDescription(for lastRunAt: Date?) -> String {
        guard let lastRunAt else { return "Hasn't run yet" }
        let relativeDescription = relativeDateTimeFormatter.localizedString(
            for: lastRunAt,
            relativeTo: Date()
        )
        return "Last started \(relativeDescription)"
    }
}
