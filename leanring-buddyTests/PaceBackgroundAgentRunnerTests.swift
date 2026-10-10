//
//  PaceBackgroundAgentRunnerTests.swift
//  leanring-buddyTests
//
//  Tests for the background agent runner. Verifies task lifecycle,
//  concurrency limits, cancellation, and callback wiring.
//

import Foundation
import Testing
@testable import Pace

@MainActor
@Suite(.serialized)
struct PaceBackgroundAgentRunnerTests {

    // MARK: - Task lifecycle

    /// Enqueuing a task adds it to the task list.
    @Test
    func enqueueAddsTaskToList() {
        let runner = PaceBackgroundAgentRunner()
        let initialCount = runner.tasks.count

        let id = runner.enqueue(prompt: "test prompt", displayName: "Test Task")

        #expect(runner.tasks.count == initialCount + 1)
        #expect(runner.tasks.contains(where: { $0.id == id }))

        // Cleanup.
        runner.cancel(taskId: id)
    }

    /// A task that completes successfully reports .completed state.
    @Test
    func taskCompletesSuccessfully() async {
        let runner = PaceBackgroundAgentRunner()

        runner.executePlannerTurn = { prompt in
            return "Done: \(prompt)"
        }
        defer { runner.executePlannerTurn = nil }

        let id = runner.enqueue(prompt: "do something", displayName: "Success Task")

        // Wait for the background task to complete. Background priority
        // tasks may take a while to schedule.
        for _ in 0..<10 {
            try? await Task.sleep(for: .milliseconds(200))
            if let task = runner.tasks.first(where: { $0.id == id }),
               task.state == .completed || task.state == .failed("") {
                break
            }
        }

        let task = runner.tasks.first(where: { $0.id == id })
        #expect(task != nil)
        #expect(task?.state == .completed)
        #expect(task?.resultSummary?.contains("Done: do something") == true)

        // Cleanup.
        runner.cancel(taskId: id)
    }

    /// Cancelling a running task sets state to .cancelled.
    @Test
    func cancelRunningTaskSetsCancelledState() async {
        let runner = PaceBackgroundAgentRunner()

        // Make the planner turn take a while so we can cancel it.
        runner.executePlannerTurn = { _ in
            try? await Task.sleep(for: .seconds(10))
            return "should not reach"
        }
        defer { runner.executePlannerTurn = nil }

        let id = runner.enqueue(prompt: "long task", displayName: "Long Task")

        // Give it a moment to start.
        try? await Task.sleep(for: .milliseconds(500))

        runner.cancel(taskId: id)

        try? await Task.sleep(for: .milliseconds(200))

        let task = runner.tasks.first(where: { $0.id == id })
        #expect(task?.state == .cancelled)
    }

    /// A task with no planner callback fails gracefully.
    @Test
    func taskWithoutCallbackFailsGracefully() async {
        let runner = PaceBackgroundAgentRunner()
        runner.executePlannerTurn = nil

        let id = runner.enqueue(prompt: "no callback", displayName: "No Callback")

        // Wait for the background task to process.
        for _ in 0..<10 {
            try? await Task.sleep(for: .milliseconds(200))
            if let task = runner.tasks.first(where: { $0.id == id }),
               case .failed = task.state {
                break
            }
        }

        let task = runner.tasks.first(where: { $0.id == id })
        if case .failed(let message) = task?.state {
            #expect(message.contains("No planner callback"))
        } else {
            #expect(Bool(false), "Task should be in failed state")
        }

        // Cleanup.
        runner.cancel(taskId: id)
    }

    // MARK: - State tracking

    /// hasRunningTasks is true when a task is running.
    @Test
    func hasRunningTasksReflectsState() async {
        let runner = PaceBackgroundAgentRunner()

        runner.executePlannerTurn = { _ in
            try? await Task.sleep(for: .seconds(2))
            return "done"
        }
        defer { runner.executePlannerTurn = nil }

        let id = runner.enqueue(prompt: "running test", displayName: "Running Test")

        // Wait for the task to start running.
        try? await Task.sleep(for: .milliseconds(500))
        #expect(runner.hasRunningTasks == true)

        // Wait for completion.
        for _ in 0..<15 {
            try? await Task.sleep(for: .milliseconds(300))
            if !runner.hasRunningTasks { break }
        }
        #expect(runner.hasRunningTasks == false)

        // Cleanup.
        runner.cancel(taskId: id)
    }

    /// clearCompleted removes completed/cancelled/failed tasks.
    @Test
    func clearCompletedRemovesFinishedTasks() async {
        let runner = PaceBackgroundAgentRunner()

        runner.executePlannerTurn = { _ in "done" }
        defer { runner.executePlannerTurn = nil }

        let id = runner.enqueue(prompt: "clear test", displayName: "Clear Test")

        // Poll until THIS task reaches a finished state — a fixed sleep
        // flakes under CI load (the detached execution task may not have
        // completed yet), and asserting on the task's own id keeps the
        // test immune to other tests' tasks in the shared runner.
        for _ in 0..<100 {
            let enqueuedTask = runner.tasks.first(where: { $0.id == id })
            if enqueuedTask?.state == .completed {
                break
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        let enqueuedTaskState = runner.tasks.first(where: { $0.id == id })?.state
        #expect(enqueuedTaskState == .completed)

        runner.clearCompleted()
        #expect(runner.tasks.contains(where: { $0.id == id }) == false)
    }

    // MARK: - Priority queue (Sprint 2.2)

    /// High-priority tasks should be started before low-priority ones
    /// when both are queued.
    @Test
    func highPriorityTaskStartsFirst() async {
        let runner = PaceBackgroundAgentRunner()

        // Block all slots with slow tasks so we can queue more.
        runner.executePlannerTurn = { _ in
            try? await Task.sleep(for: .seconds(5))
            return "done"
        }
        defer { runner.executePlannerTurn = nil }

        // Fill all 4 concurrent slots with normal-priority tasks.
        var blockerIds: [String] = []
        for i in 0..<4 {
            blockerIds.append(runner.enqueue(prompt: "blocker \(i)", displayName: "Blocker \(i)"))
        }

        try? await Task.sleep(for: .milliseconds(500))

        // Now queue a low-priority and a high-priority task.
        let lowId = runner.enqueue(prompt: "low priority", displayName: "Low", priority: .low)
        let highId = runner.enqueue(prompt: "high priority", displayName: "High", priority: .high)

        // Both should be queued (all slots are full).
        #expect(runner.tasks.first(where: { $0.id == lowId })?.state == .queued)
        #expect(runner.tasks.first(where: { $0.id == highId })?.state == .queued)

        // Cancel one blocker to free a slot.
        runner.cancel(taskId: blockerIds[0])
        try? await Task.sleep(for: .milliseconds(500))

        // The high-priority task should have started, not the low one.
        let highTask = runner.tasks.first(where: { $0.id == highId })
        let lowTask = runner.tasks.first(where: { $0.id == lowId })
        #expect(highTask?.state == .running || highTask?.state == .completed || highTask?.state == .failed(""))
        #expect(lowTask?.state == .queued)

        // Cleanup.
        for id in blockerIds { runner.cancel(taskId: id) }
        runner.cancel(taskId: lowId)
        runner.cancel(taskId: highId)
    }

    // MARK: - Progress tracking (Sprint 2.2)

    /// updateProgress should update the step description and count.
    @Test
    func updateProgressSetsStepDescription() {
        let runner = PaceBackgroundAgentRunner()
        let id = runner.enqueue(prompt: "progress test", displayName: "Progress Test")

        runner.updateProgress(taskId: id, stepDescription: "Searching...", stepCount: 2)

        let task = runner.tasks.first(where: { $0.id == id })
        #expect(task?.currentStepDescription == "Searching...")
        #expect(task?.stepCount == 2)

        runner.cancel(taskId: id)
    }

    // MARK: - Queue summary (Sprint 2.2)

    /// queueSummary should report correct counts.
    @Test
    func queueSummaryReportsCorrectCounts() {
        let runner = PaceBackgroundAgentRunner()
        let id1 = runner.enqueue(prompt: "summary 1", displayName: "Summary 1")
        let id2 = runner.enqueue(prompt: "summary 2", displayName: "Summary 2")

        let summary = runner.queueSummary
        // At least 2 tasks should be running or queued.
        #expect(summary.running + summary.queued >= 2)

        runner.cancel(taskId: id1)
        runner.cancel(taskId: id2)
    }
    @Test
    func restartPreservesResultsAndRequiresExplicitRetry() async throws {
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "pace-background-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let runner = PaceBackgroundAgentRunner(storageURL: fileURL)
        runner.executePlannerTurn = { _ in "Cited result https://example.com" }
        let completedId = runner.enqueue(prompt: "research completed", displayName: "Completed research")
        for _ in 0..<100 {
            if runner.tasks.first(where: { $0.id == completedId })?.state == .completed { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        runner.executePlannerTurn = { _ in
            try await Task.sleep(for: .seconds(20))
            return "old execution"
        }
        let interruptedId = runner.enqueue(prompt: "research interrupted", displayName: "Interrupted research")
        let restored = PaceBackgroundAgentRunner(storageURL: fileURL)
        var replayCount = 0
        restored.executePlannerTurn = { _ in
            replayCount += 1
            return "retried result"
        }
        #expect(
            restored.tasks.first(where: { $0.id == completedId })?.resultSummary == "Cited result https://example.com")
        #expect(restored.tasks.first(where: { $0.id == interruptedId })?.state == .interrupted)
        #expect(replayCount == 0)
        #expect(restored.retry(taskId: interruptedId))
        for _ in 0..<100 {
            if restored.tasks.first(where: { $0.id == interruptedId })?.state == .completed { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(replayCount == 1)
        #expect(restored.tasks.first(where: { $0.id == interruptedId })?.resultSummary == "retried result")
        runner.cancel(taskId: interruptedId)
    }

    @Test
    func plannerFailureIsNotCompletedAndQueueContinues() async {
        let runner = PaceBackgroundAgentRunner()
        runner.executePlannerTurn = { _ in
            throw NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Research unavailable"])
        }
        let id = runner.enqueue(prompt: "research", displayName: "Research")
        for _ in 0..<100 {
            if case .failed = runner.tasks.first(where: { $0.id == id })?.state { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(runner.tasks.first(where: { $0.id == id })?.state == .failed("Research unavailable"))
        #expect(runner.tasks.first(where: { $0.id == id })?.resultSummary == nil)
        runner.executePlannerTurn = { _ in "Recovered" }
        #expect(runner.retry(taskId: id))
        for _ in 0..<100 {
            if runner.tasks.first(where: { $0.id == id })?.state == .completed { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(runner.tasks.first(where: { $0.id == id })?.resultSummary == "Recovered")
    }

    @Test
    func corruptedQueueIsReportedAndPreserved() throws {
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "pace-background-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let originalData = Data("invalid queue".utf8)
        try originalData.write(to: fileURL)
        let runner = PaceBackgroundAgentRunner(storageURL: fileURL)
        #expect(runner.persistenceError != nil)
        let id = runner.enqueue(prompt: "draft", displayName: "Draft")
        runner.cancel(taskId: id)
        #expect(try Data(contentsOf: fileURL) == originalData)
    }

    @Test
    func commandParserPreservesCaseAndSeparatesBackgroundCancellation() {
        if case .run(let prompt, _) = PaceBackgroundAgentCommandParser.parse("Background: Research MLX vs Swift") {
            #expect(prompt == "Research MLX vs Swift")
        } else {
            Issue.record("Background research did not parse")
        }
        #expect(PaceCronCommandParser.parse("cancel background task bg-123") == nil)
        if case .cancel(let name) = PaceBackgroundAgentCommandParser.parse("cancel background task bg-123") {
            #expect(name == "bg-123")
        } else {
            Issue.record("Background cancellation did not parse")
        }
        if case .retry(let name) = PaceBackgroundAgentCommandParser.parse("resume background task bg-123") {
            #expect(name == "bg-123")
        } else {
            Issue.record("Background retry did not parse")
        }
    }

    @Test
    func restoredScheduledTaskKeepsItsExecutionPolicy() async throws {
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "pace-scheduled-background-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let runner = PaceBackgroundAgentRunner(storageURL: fileURL)
        runner.executeScheduledPlannerTurn = { _ in
            try await Task.sleep(for: .seconds(20))
            return "old attempt"
        }
        let taskId = runner.enqueue(prompt: "research", displayName: "Scheduled research", isScheduled: true)
        let restored = PaceBackgroundAgentRunner(storageURL: fileURL)
        var scheduledExecutions = 0
        var manualExecutions = 0
        restored.executeScheduledPlannerTurn = { _ in
            scheduledExecutions += 1
            return "scheduled result"
        }
        restored.executePlannerTurn = { _ in
            manualExecutions += 1
            return "manual result"
        }
        #expect(restored.tasks.first?.isScheduled == true)
        #expect(restored.retry(taskId: taskId))
        for _ in 0..<100 {
            if restored.tasks.first?.state == .completed { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(scheduledExecutions == 1)
        #expect(manualExecutions == 0)
        #expect(restored.tasks.first?.resultSummary == "scheduled result")
        runner.cancel(taskId: taskId)
    }

    @Test
    func duplicateNamesRequireTaskId() {
        let runner = PaceBackgroundAgentRunner()
        let firstId = runner.enqueue(prompt: "first", displayName: "Research")
        let secondId = runner.enqueue(prompt: "second", displayName: "Research")
        #expect(runner.matchingTask(named: "Research") == nil)
        #expect(runner.matchingTask(named: firstId)?.id == firstId)
        runner.cancel(taskId: firstId)
        runner.cancel(taskId: secondId)
    }

    @Test
    func failedRetrySaveRetainsPreviousState() async throws {
        let folderURL = FileManager.default.temporaryDirectory.appendingPathComponent("pace-retry-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folderURL) }
        let fileURL = folderURL.appendingPathComponent("queue.json")
        let runner = PaceBackgroundAgentRunner(storageURL: fileURL)
        var executionCount = 0
        runner.executePlannerTurn = { _ in
            executionCount += 1
            throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed"])
        }
        let taskId = runner.enqueue(prompt: "draft", displayName: "Draft")
        for _ in 0..<100 {
            if case .failed = runner.tasks.first?.state { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        try FileManager.default.moveItem(at: fileURL, to: folderURL.appendingPathComponent("saved.json"))
        try FileManager.default.createDirectory(at: fileURL, withIntermediateDirectories: false)
        #expect(!runner.retry(taskId: taskId))
        #expect(runner.persistenceError != nil)
        #expect(runner.tasks.first?.state == .failed("Failed"))
        #expect(executionCount == 1)
    }

    @Test
    func explicitBackgroundRequestsAreNotHijackedByManagementWords() {
        for request in ["list my calendar", "research what changed in Swift", "list my scheduled tasks"] {
            let transcript = "background: \(request)"
            #expect(PaceCronCommandParser.parse(transcript) == nil)
            if case .run(let prompt, _) = PaceBackgroundAgentCommandParser.parse(transcript) {
                #expect(prompt == request)
            } else {
                Issue.record("Explicit background request was intercepted")
            }
        }
    }

}
