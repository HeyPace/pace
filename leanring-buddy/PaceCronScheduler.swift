//
//  PaceCronScheduler.swift
//  leanring-buddy
//
//  General-purpose cron-like scheduler for recurring Pace tasks.
//  Inspired by OpenFelix's cron jobs + proactive alerts.
//
//  Unlike PaceMorningTriageScheduler (which fires once daily), this
//  scheduler supports arbitrary intervals: "every 30 minutes check
//  my calendar", "every 2 hours remind me to stand up", etc.
//
//  Due occurrences enter the durable read-only background queue.
//  Deadlines survive restart and sleep; missed intervals coalesce,
//  and interrupted runs require review instead of automatic replay.
//

import AppKit
import CryptoKit
import Combine
import Foundation

/// A scheduled task with a recurring interval and a generator closure.
struct PaceCronTask: Identifiable, Equatable, Codable {
    let id: String
    let displayName: String
    /// Interval between firings, in seconds.
    let intervalSeconds: TimeInterval
    /// Whether to skip weekends (for work-day-only tasks).
    let skipWeekends: Bool
    /// The prompt to send to the planner when this task fires.
    /// The planner generates the spoken response.
    let taskPrompt: String
    /// When this task most recently fired, or nil if it has never run.
    /// Optional so tasks persisted before this field existed still decode:
    /// Swift's synthesized `Codable` maps a missing key for an Optional to
    /// nil, so old `pace.cronScheduler.tasks` JSON stays readable.
    var lastRunAt: Date?
    var nextRunAt: Date?
    var claimedAt: Date?
    var backgroundTaskId: String?
    var lastError: String?
    var isPaused: Bool?
    var hourOfDay: Int?
    var minuteOfHour: Int?

    init(
        id: String,
        displayName: String,
        intervalSeconds: TimeInterval,
        skipWeekends: Bool,
        taskPrompt: String,
        lastRunAt: Date? = nil,
        nextRunAt: Date? = nil,
        hourOfDay: Int? = nil,
        minuteOfHour: Int? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.intervalSeconds = intervalSeconds
        self.skipWeekends = skipWeekends
        self.taskPrompt = taskPrompt
        self.lastRunAt = lastRunAt
        self.nextRunAt = nextRunAt
        self.hourOfDay = hourOfDay
        self.minuteOfHour = minuteOfHour
    }

    static func == (lhs: PaceCronTask, rhs: PaceCronTask) -> Bool {
        lhs.id == rhs.id
    }
}

/// Reconciles durable deadlines against one lightweight timer and wake events.
@MainActor
final class PaceCronScheduler: ObservableObject {
    static let shared = PaceCronScheduler()

    @Published private(set) var tasks: [PaceCronTask] = []
    @Published private(set) var persistenceError: String?
    @Published var isEnabled: Bool = PaceUserPreferencesStore
        .bool(.isCronSchedulerEnabled, default: false)

    private var timer: Timer?
    private var inFlightTaskIds: Set<String> = []
    private var wakeObserver: NSObjectProtocol?
    private let defaults: UserDefaults?
    private let currentTimeProvider: () -> Date
    private let calendar: Calendar

    /// Returns the durable background task identifier, or throws without claiming success.
    var executeTaskCallback: ((PaceCronTask) async throws -> String)?
    var previousRunState: ((String) -> PaceBackgroundAgentState?)?

    init(
        defaults: UserDefaults? = .standard, currentTimeProvider: @escaping () -> Date = Date.init,
        calendar: Calendar = .current
    ) {
        self.defaults = defaults
        self.currentTimeProvider = currentTimeProvider
        self.calendar = calendar
        loadPersistedTasks()
        for index in tasks.indices where tasks[index].claimedAt != nil {
            tasks[index].isPaused = true
            tasks[index].lastError = "Interrupted while starting a run. Review before enabling again."
            tasks[index].claimedAt = nil
        }
        persistTasks()
    }

    @discardableResult
    func addTask(_ task: PaceCronTask) -> Bool {
        guard persistenceError == nil, Self.isValidInterval(task.intervalSeconds),
            !tasks.contains(where: { $0.id == task.id })
        else {
            return false
        }
        var scheduledTask = task
        scheduledTask.nextRunAt = nextDate(for: task, after: currentTimeProvider())
        tasks.append(scheduledTask)
        persistTasks()
        return true
    }

    func removeTask(id: String) {
        tasks.removeAll(where: { $0.id == id })
        persistTasks()
    }

    func setTaskPaused(id: String, paused: Bool) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[index].isPaused = paused
        if !paused {
            if let id = tasks[index].backgroundTaskId, previousRunState?(id) == .interrupted {
                // Explicit enabling starts a future cadence; it does not replay the interrupted occurrence.
                tasks[index].backgroundTaskId = nil
            }
            tasks[index].lastError = nil
            tasks[index].nextRunAt = nextDate(for: tasks[index], after: currentTimeProvider())
        }
        persistTasks()
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled && persistenceError == nil
        if defaults === UserDefaults.standard {
            PaceUserPreferencesStore.setBool(isEnabled, for: .isCronSchedulerEnabled)
        }
        timer?.invalidate()
        timer = nil
        if isEnabled {
            timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in await self?.reconcileDueTasks() }
            }
            if let timer {
                timer.tolerance = 0.2
                RunLoop.main.add(timer, forMode: .common)
            }
            if wakeObserver == nil {
                wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                    forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
                ) { [weak self] _ in
                    Task { @MainActor [weak self] in await self?.reconcileDueTasks() }
                }
            }
            Task { await reconcileDueTasks() }
        }
    }

    /// A sleep or restart coalesces missed intervals into one current run, never a backlog.
    func reconcileDueTasks() async {
        guard isEnabled, persistenceError == nil else { return }
        let now = currentTimeProvider()
        for task in tasks {
            guard isEnabled, task.isPaused != true, !inFlightTaskIds.contains(task.id),
                Self.isValidInterval(task.intervalSeconds)
            else { continue }
            guard let index = tasks.firstIndex(where: { $0.id == task.id }) else { continue }
            if tasks[index].nextRunAt == nil {
                tasks[index].nextRunAt =
                    task.lastRunAt.map { nextDate(for: task, after: $0) } ?? nextDate(for: task, after: now)
                persistTasks()
            }
            guard let dueDate = tasks[index].nextRunAt, dueDate <= now else { continue }
            if task.skipWeekends && [1, 7].contains(calendar.component(.weekday, from: now)) { continue }
            if let backgroundTaskId = task.backgroundTaskId, let state = previousRunState?(backgroundTaskId) {
                if state == .running || state == .queued { continue }
                if state == .interrupted {
                    tasks[index].isPaused = true
                    tasks[index].lastError = "Previous run was interrupted. Review its result before enabling again."
                    persistTasks()
                    continue
                }
            }
            guard let executeTaskCallback else { continue }
            inFlightTaskIds.insert(task.id)
            tasks[index].claimedAt = now
            tasks[index].nextRunAt = nextDate(for: task, after: now)
            persistTasks()
            do {
                let backgroundTaskId = try await executeTaskCallback(task)
                if let currentIndex = tasks.firstIndex(where: { $0.id == task.id }) {
                    tasks[currentIndex].backgroundTaskId = backgroundTaskId
                    tasks[currentIndex].lastRunAt = now
                    tasks[currentIndex].lastError = nil
                    tasks[currentIndex].claimedAt = nil
                }
            } catch {
                if let currentIndex = tasks.firstIndex(where: { $0.id == task.id }) {
                    tasks[currentIndex].lastError = error.localizedDescription
                    tasks[currentIndex].claimedAt = nil
                }
            }
            inFlightTaskIds.remove(task.id)
            persistTasks()
        }
    }

    private func nextDate(for task: PaceCronTask, after date: Date) -> Date {
        if let hourOfDay = task.hourOfDay {
            var components = DateComponents()
            components.hour = hourOfDay
            components.minute = task.minuteOfHour ?? 0
            components.second = 0
            return calendar.nextDate(after: date, matching: components, matchingPolicy: .nextTime)
                ?? date.addingTimeInterval(task.intervalSeconds)
        }
        return date.addingTimeInterval(task.intervalSeconds)
    }

    nonisolated static func isValidInterval(_ interval: TimeInterval) -> Bool {
        interval.isFinite && interval >= 1 && interval <= 31_536_000
    }

    private static let tasksKey = "pace.cronScheduler.tasks"

    private func loadPersistedTasks() {
        guard let data = defaults?.data(forKey: Self.tasksKey) else { return }
        do {
            let savedTasks = try JSONDecoder().decode([PaceCronTask].self, from: data)
            guard savedTasks.allSatisfy({ Self.isValidInterval($0.intervalSeconds) }) else {
                throw NSError(domain: "PaceSchedule", code: 1)
            }
            tasks = savedTasks
        } catch {
            persistenceError =
                "Saved schedules could not be read. The original data was preserved; scheduling is paused."
        }
    }

    private func persistTasks() {
        guard persistenceError == nil else { return }
        do {
            let data = try JSONEncoder().encode(tasks)
            defaults?.set(data, forKey: Self.tasksKey)
        } catch {
            persistenceError = "Schedules could not be saved. Scheduling is paused."
            timer?.invalidate()
            timer = nil
            isEnabled = false
        }
    }

    // MARK: - Voice command parsing

    /// Parse a voice command like "every 30 minutes check my calendar"
    /// into a PaceCronTask. Returns nil if the command doesn't match.
    nonisolated static func parseVoiceCommand(_ transcript: String) -> PaceCronTask? {
        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)

        let patterns: [(regex: String, multiplier: Double, unit: String)] = [
            (#"^every (\d+) minutes? (.+)$"#, 60, "minute"),
            (#"^every (\d+) hours? (.+)$"#, 3600, "hour"),
            (#"^every (\d+) seconds? (.+)$"#, 1, "second"),
            (#"^every (\d+) days? (.+)$"#, 86400, "day"),
        ]
        for (pattern, multiplier, unit) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                let match = regex.firstMatch(
                    in: trimmedTranscript, range: NSRange(trimmedTranscript.startIndex..., in: trimmedTranscript)),
                let numberRange = Range(match.range(at: 1), in: trimmedTranscript),
                let taskRange = Range(match.range(at: 2), in: trimmedTranscript),
                let number = Int(trimmedTranscript[numberRange])
            else { continue }
            let interval = Double(number) * multiplier
            guard isValidInterval(interval) else { return nil }
            let prompt = String(trimmedTranscript[taskRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !prompt.isEmpty else { return nil }
            return PaceCronTask(
                id: stableTaskId("\(interval):\(prompt.lowercased())"),
                displayName: "Every \(number) \(unit)\(number == 1 ? "" : "s"): \(prompt)", intervalSeconds: interval,
                skipWeekends: false, taskPrompt: prompt)
        }
        let dailyPattern = #"^every (?:morning|day) at (\d{1,2})(?::(\d{2}))?\s*(am|pm)?[, ]+(.+)$"#
        if let regex = try? NSRegularExpression(pattern: dailyPattern, options: .caseInsensitive),
            let match = regex.firstMatch(
                in: trimmedTranscript, range: NSRange(trimmedTranscript.startIndex..., in: trimmedTranscript)),
            let hourRange = Range(match.range(at: 1), in: trimmedTranscript),
            let promptRange = Range(match.range(at: 4), in: trimmedTranscript),
            var hour = Int(trimmedTranscript[hourRange])
        {
            let minute = Range(match.range(at: 2), in: trimmedTranscript).flatMap { Int(trimmedTranscript[$0]) } ?? 0
            if let periodRange = Range(match.range(at: 3), in: trimmedTranscript) {
                guard (1...12).contains(hour) else { return nil }
                hour = hour % 12 + (trimmedTranscript[periodRange].lowercased() == "pm" ? 12 : 0)
            }
            guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
            let prompt = String(trimmedTranscript[promptRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !prompt.isEmpty else { return nil }
            let time = String(format: "%02d:%02d", hour, minute)
            return PaceCronTask(
                id: stableTaskId("daily:\(time):\(prompt.lowercased())"), displayName: "Daily at \(time): \(prompt)",
                intervalSeconds: 86400, skipWeekends: false, taskPrompt: prompt, hourOfDay: hour, minuteOfHour: minute)
        }
        return nil
    }

    nonisolated private static func stableTaskId(_ description: String) -> String {
        "cron-" + SHA256.hash(data: Data(description.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}
