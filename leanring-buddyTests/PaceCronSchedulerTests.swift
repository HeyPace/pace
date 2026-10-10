//
//  PaceCronSchedulerTests.swift
//  leanring-buddyTests
//
//  Tests for the cron scheduler's voice command parser and
//  task management logic. The actual timer firing is not tested
//  (non-deterministic); instead we test the parsing and state
//  management that the timer triggers.
//

import Foundation
import Testing
@testable import Pace

@MainActor
struct PaceCronSchedulerTests {

    // MARK: - Voice command parsing

    /// "every 30 minutes check my calendar" parses correctly.
    @Test
    func parseEveryNMinutes() {
        let task = PaceCronScheduler.parseVoiceCommand("every 30 minutes check my calendar")

        #expect(task != nil)
        #expect(task?.intervalSeconds == 1800) // 30 * 60
        #expect(task?.taskPrompt == "check my calendar")
        #expect(task?.skipWeekends == false)
    }

    /// "every 2 hours remind me to stand up" parses correctly.
    @Test
    func parseEveryNHours() {
        let task = PaceCronScheduler.parseVoiceCommand("every 2 hours remind me to stand up")

        #expect(task != nil)
        #expect(task?.intervalSeconds == 7200) // 2 * 3600
        #expect(task?.taskPrompt == "remind me to stand up")
    }

    /// "every 15 seconds run a quick check" parses correctly.
    @Test
    func parseEveryNSeconds() {
        let task = PaceCronScheduler.parseVoiceCommand("every 15 seconds run a quick check")

        #expect(task != nil)
        #expect(task?.intervalSeconds == 15)
        #expect(task?.taskPrompt == "run a quick check")
    }

    /// Singular "minute" (not "minutes") also parses.
    @Test
    func parseSingularMinute() {
        let task = PaceCronScheduler.parseVoiceCommand("every 1 minute check email")

        #expect(task != nil)
        #expect(task?.intervalSeconds == 60)
        #expect(task?.taskPrompt == "check email")
    }

    /// Non-matching command returns nil.
    @Test
    func parseNonMatchingCommandReturnsNil() {
        #expect(PaceCronScheduler.parseVoiceCommand("check my email") == nil)
        #expect(PaceCronScheduler.parseVoiceCommand("what time is it") == nil)
        #expect(PaceCronScheduler.parseVoiceCommand("every check") == nil)
    }

    /// Case-insensitive matching works.
    @Test
    func parseCaseInsensitive() {
        let task = PaceCronScheduler.parseVoiceCommand("EVERY 30 MINUTES CHECK CALENDAR")

        #expect(task != nil)
        #expect(task?.intervalSeconds == 1800)
    }

    /// Task ID is unique per command.
    @Test
    func taskIDIsUnique() {
        let task1 = PaceCronScheduler.parseVoiceCommand("every 30 minutes check calendar")
        let task2 = PaceCronScheduler.parseVoiceCommand("every 30 minutes check email")

        #expect(task1?.id != task2?.id)
    }

    // MARK: - Task management

    /// Adding a task increases the task count.
    @Test
    func addTaskIncreasesCount() {
        let scheduler = PaceCronScheduler(defaults: nil)
        let initialCount = scheduler.tasks.count

        let task = PaceCronTask(
            id: "test-add-\(UUID().uuidString.prefix(8))",
            displayName: "Test Task",
            intervalSeconds: 3600,
            skipWeekends: false,
            taskPrompt: "test"
        )
        scheduler.addTask(task)

        #expect(scheduler.tasks.count == initialCount + 1)

        // Cleanup.
        scheduler.removeTask(id: task.id)
    }

    /// Adding a duplicate task (same ID) does not increase count.
    @Test
    func addDuplicateTaskDoesNotIncrease() {
        let scheduler = PaceCronScheduler(defaults: nil)
        let initialCount = scheduler.tasks.count

        let task = PaceCronTask(
            id: "test-dup-\(UUID().uuidString.prefix(8))",
            displayName: "Test Dup",
            intervalSeconds: 3600,
            skipWeekends: false,
            taskPrompt: "test"
        )
        scheduler.addTask(task)
        scheduler.addTask(task) // Same ID.

        #expect(scheduler.tasks.count == initialCount + 1)

        // Cleanup.
        scheduler.removeTask(id: task.id)
    }

    /// Removing a task decreases the count.
    @Test
    func removeTaskDecreasesCount() {
        let scheduler = PaceCronScheduler(defaults: nil)

        let task = PaceCronTask(
            id: "test-remove-\(UUID().uuidString.prefix(8))",
            displayName: "Test Remove",
            intervalSeconds: 3600,
            skipWeekends: false,
            taskPrompt: "test"
        )
        scheduler.addTask(task)
        let countAfterAdd = scheduler.tasks.count

        scheduler.removeTask(id: task.id)

        #expect(scheduler.tasks.count == countAfterAdd - 1)
    }

    // MARK: - Codable conformance

    /// PaceCronTask can be encoded and decoded.
    @Test
    func cronTaskIsCodable() throws {
        let task = PaceCronTask(
            id: "codable-test",
            displayName: "Codable Test",
            intervalSeconds: 1800,
            skipWeekends: true,
            taskPrompt: "test prompt"
        )

        let data = try JSONEncoder().encode(task)
        let decoded = try JSONDecoder().decode(PaceCronTask.self, from: data)

        #expect(decoded.id == task.id)
        #expect(decoded.displayName == task.displayName)
        #expect(decoded.intervalSeconds == task.intervalSeconds)
        #expect(decoded.skipWeekends == task.skipWeekends)
        #expect(decoded.taskPrompt == task.taskPrompt)
    }

    // MARK: - lastRunAt (last-run tracking)

    /// OLD persisted JSON — written before `lastRunAt` existed, so the key
    /// is entirely absent — still decodes, with `lastRunAt == nil`.
    @Test
    func cronTaskDecodesLegacyJSONWithoutLastRunAtKey() throws {
        let legacyJSON = """
        {
            "id": "legacy-task",
            "displayName": "Legacy Task",
            "intervalSeconds": 1800,
            "skipWeekends": false,
            "taskPrompt": "check calendar"
        }
        """
        let data = try #require(legacyJSON.data(using: .utf8))
        let decoded = try JSONDecoder().decode(PaceCronTask.self, from: data)

        #expect(decoded.id == "legacy-task")
        #expect(decoded.intervalSeconds == 1800)
        #expect(decoded.lastRunAt == nil)
    }

    /// A `lastRunAt` value survives an encode/decode round-trip.
    @Test
    func cronTaskLastRunAtSurvivesRoundTrip() throws {
        let lastRunAt = Date(timeIntervalSince1970: 1_700_000_000)
        let task = PaceCronTask(
            id: "lastrun-test",
            displayName: "Last Run Test",
            intervalSeconds: 3600,
            skipWeekends: false,
            taskPrompt: "test",
            lastRunAt: lastRunAt
        )

        let data = try JSONEncoder().encode(task)
        let decoded = try JSONDecoder().decode(PaceCronTask.self, from: data)

        #expect(decoded.lastRunAt == lastRunAt)
    }

    /// A brand-new task (no explicit `lastRunAt`) starts with nil.
    @Test
    func cronTaskDefaultsToNilLastRunAt() {
        let task = PaceCronTask(
            id: "default-lastrun",
            displayName: "Default",
            intervalSeconds: 3600,
            skipWeekends: false,
            taskPrompt: "test"
        )
        #expect(task.lastRunAt == nil)
    }

    // MARK: - humanizedInterval formatting

    @Test
    func humanizedIntervalFormatsCommonCadences() {
        #expect(PaceTasksSettingsTab.humanizedInterval(30 * 60) == "Every 30 minutes")
        #expect(PaceTasksSettingsTab.humanizedInterval(60) == "Every minute")
        #expect(PaceTasksSettingsTab.humanizedInterval(3_600) == "Every hour")
        #expect(PaceTasksSettingsTab.humanizedInterval(2 * 3_600) == "Every 2 hours")
        #expect(PaceTasksSettingsTab.humanizedInterval(86_400) == "Daily")
        #expect(PaceTasksSettingsTab.humanizedInterval(2 * 86_400) == "Every 2 days")
        #expect(PaceTasksSettingsTab.humanizedInterval(15) == "Every 15 seconds")
        #expect(PaceTasksSettingsTab.humanizedInterval(1) == "Every second")
        // Non-round intervals fall through to raw seconds.
        #expect(PaceTasksSettingsTab.humanizedInterval(90) == "Every 90 seconds")
    }
    @Test
    func intervalAndDailyParsingRemainExactAndStable() {
        let hourly = PaceCronScheduler.parseVoiceCommand("every 2 hours Research Swift")
        #expect(hourly?.intervalSeconds == 7200)
        #expect(hourly?.displayName == "Every 2 hours: Research Swift")
        #expect(hourly?.id == PaceCronScheduler.parseVoiceCommand("every 2 hours research swift")?.id)
        #expect(hourly?.id != PaceCronScheduler.parseVoiceCommand("every 2 minutes research swift")?.id)
        #expect(PaceCronScheduler.parseVoiceCommand("every 0 seconds check") == nil)
        #expect(PaceCronScheduler.parseVoiceCommand("every 999999999999999999999 hours check") == nil)
        #expect(PaceCronScheduler.parseVoiceCommand("please every 2 hours check") == nil)
        let daily = PaceCronScheduler.parseVoiceCommand("every morning at 9:30 pm, check calendar")
        #expect(daily?.hourOfDay == 21)
        #expect(daily?.minuteOfHour == 30)
        #expect(daily?.taskPrompt == "check calendar")
        #expect(PaceCronScheduler.parseVoiceCommand("every day at 25 check calendar") == nil)
    }

    @Test
    func overdueIntervalsCoalesceAndRunningTasksNeverOverlap() async {
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        let scheduler = PaceCronScheduler(defaults: nil, currentTimeProvider: { now })
        var fireCount = 0
        var runState: PaceBackgroundAgentState = .running
        scheduler.executeTaskCallback = { _ in
            fireCount += 1
            return "background-1"
        }
        scheduler.previousRunState = { _ in runState }
        let task = PaceCronTask(
            id: "coalesce", displayName: "Coalesce", intervalSeconds: 60, skipWeekends: false, taskPrompt: "draft")
        #expect(scheduler.addTask(task))
        scheduler.isEnabled = true
        now = now.addingTimeInterval(3600)
        await scheduler.reconcileDueTasks()
        #expect(fireCount == 1)
        #expect(scheduler.tasks.first?.nextRunAt == now.addingTimeInterval(60))
        now = now.addingTimeInterval(120)
        await scheduler.reconcileDueTasks()
        #expect(fireCount == 1)
        runState = .completed
        await scheduler.reconcileDueTasks()
        #expect(fireCount == 2)
        runState = .interrupted
        now = now.addingTimeInterval(120)
        await scheduler.reconcileDueTasks()
        #expect(fireCount == 2)
        #expect(scheduler.tasks.first?.isPaused == true)
    }

    @Test
    func failedEnqueueNeverClaimsSuccessfulRun() async {
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        let scheduler = PaceCronScheduler(defaults: nil, currentTimeProvider: { now })
        _ = scheduler.addTask(
            PaceCronTask(
                id: "failure", displayName: "Failure", intervalSeconds: 60, skipWeekends: false, taskPrompt: "draft"))
        scheduler.isEnabled = true
        scheduler.executeTaskCallback = { _ in
            throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Blocked"])
        }
        now = now.addingTimeInterval(60)
        await scheduler.reconcileDueTasks()
        #expect(scheduler.tasks.first?.lastRunAt == nil)
        #expect(scheduler.tasks.first?.lastError == "Blocked")
        #expect(scheduler.tasks.first?.claimedAt == nil)
    }

    @Test
    func restartPreservesDeadlineAndInterruptedClaimRequiresReview() async throws {
        let suite = "pace.scheduler.test.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let scheduler = PaceCronScheduler(defaults: defaults, currentTimeProvider: { now })
        _ = scheduler.addTask(
            PaceCronTask(
                id: "restart", displayName: "Restart", intervalSeconds: 60, skipWeekends: false, taskPrompt: "draft"))
        let restored = PaceCronScheduler(defaults: defaults, currentTimeProvider: { now.addingTimeInterval(120) })
        #expect(restored.tasks.first?.nextRunAt == now.addingTimeInterval(60))
        var claimed = try #require(restored.tasks.first)
        claimed.claimedAt = now
        defaults.set(try JSONEncoder().encode([claimed]), forKey: "pace.cronScheduler.tasks")
        let interrupted = PaceCronScheduler(defaults: defaults)
        #expect(interrupted.tasks.first?.isPaused == true)
        #expect(interrupted.tasks.first?.lastError?.contains("Interrupted") == true)
    }

    @Test
    func schedulePreservesCaseSensitivePaths() {
        let command = PaceCronScheduler.parseVoiceCommand("EVERY 2 HOURS Read ~/Desktop/Fleet/İstanbul.md")
        #expect(command?.taskPrompt == "Read ~/Desktop/Fleet/İstanbul.md")
    }

    @Test
    func corruptedSchedulesRemainPreservedAndCannotRun() async throws {
        let suite = "pace.scheduler.corrupt.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let originalData = Data("invalid schedules".utf8)
        defaults.set(originalData, forKey: "pace.cronScheduler.tasks")
        let scheduler = PaceCronScheduler(defaults: defaults)
        var executionCount = 0
        scheduler.executeTaskCallback = { _ in
            executionCount += 1
            return "unexpected"
        }
        scheduler.setEnabled(true)
        await scheduler.reconcileDueTasks()
        #expect(scheduler.persistenceError != nil)
        #expect(!scheduler.isEnabled)
        #expect(executionCount == 0)
        #expect(defaults.data(forKey: "pace.cronScheduler.tasks") == originalData)
    }

    @Test
    func malformedPersistedIntervalCannotCrashTasksOrExecute() throws {
        let suite = "pace.scheduler.invalid.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let task = PaceCronTask(
            id: "invalid", displayName: "Invalid", intervalSeconds: 1e300, skipWeekends: false, taskPrompt: "draft")
        let originalData = try JSONEncoder().encode([task])
        defaults.set(originalData, forKey: "pace.cronScheduler.tasks")
        let scheduler = PaceCronScheduler(defaults: defaults)
        #expect(scheduler.persistenceError != nil)
        #expect(scheduler.tasks.isEmpty)
        #expect(defaults.data(forKey: "pace.cronScheduler.tasks") == originalData)
        #expect(PaceTasksSettingsTab.humanizedInterval(1e300) == "Invalid interval")
        #expect(PaceTasksSettingsTab.humanizedInterval(.nan) == "Invalid interval")
    }

}
