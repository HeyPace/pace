//
//  PaceBackgroundAgentRunner.swift
//  leanring-buddy
//
//  Background agent execution — runs multi-step tasks asynchronously
//  while the user continues working. Inspired by ChatGPT App's
//  background task queue and Shiro's parallel sub-agents.
//
//  Unlike the synchronous agent loop (which blocks the UI and TTS
//  pipeline), background agents:
//    - Run on a detached Task with background priority
//    - Report progress via a published state object
//    - Can be cancelled by the user
//    - Speak results only when done (or on failure)
//    - Respect the restraint gate for proactive speech
//
//  Use cases:
//    - "Build a Linear ticket for the bug I just described"
//    - "Draft a Gmail response to the last email"
//    - "Research the top 5 competitors for X"
//
//  Sprint 2.2 enhancements:
//    - Increased concurrency from 2 → 4 (matches subagent coordinator)
//    - Progress tracking: currentStep description + step count
//    - Priority queue: high-priority tasks jump the queue
//    - Elapsed time tracking for UI display
//

import Combine
import Foundation

/// State of a background agent task.
enum PaceBackgroundAgentState: Equatable, Codable {
    case queued
    case running
    case interrupted
    case completed
    case cancelled
    case failed(String)
}

/// Priority of a background agent task. Higher priority tasks
/// jump ahead of lower priority ones in the queue.
enum PaceBackgroundAgentPriority: Int, Comparable, Codable {
    case low = 0
    case normal = 1
    case high = 2

    static func < (lhs: PaceBackgroundAgentPriority, rhs: PaceBackgroundAgentPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// A background agent task. Created by voice command or cron trigger.
struct PaceBackgroundAgentTask: Identifiable, Equatable, Codable {
    let id: String
    let displayName: String
    let prompt: String
    let priority: PaceBackgroundAgentPriority
    var state: PaceBackgroundAgentState
    var startedAt: Date?
    var completedAt: Date?
    var resultSummary: String?
    var stepCount: Int
    /// Human-readable description of the current step, for UI display.
    /// e.g. "Searching Linear...", "Drafting ticket...", "Done".
    var currentStepDescription: String?
    var isScheduled: Bool? = nil

    static func == (lhs: PaceBackgroundAgentTask, rhs: PaceBackgroundAgentTask) -> Bool {
        lhs.id == rhs.id
    }
}

/// Manages background agent tasks. Each task runs as a detached Task
/// that produces read-only research, source-grounded answers, or drafts.
/// Scheduled origin is retained so unattended consent can be rechecked.
@MainActor
final class PaceBackgroundAgentRunner: ObservableObject {
    static let shared = PaceBackgroundAgentRunner(storageURL: defaultStorageURL)

    @Published private(set) var tasks: [PaceBackgroundAgentTask] = []

    /// Callback to execute a planner turn. Set by CompanionManager.
    var executePlannerTurn: ((String) async throws -> String)?
    var executeScheduledPlannerTurn: ((String) async throws -> String)?

    /// Callback to speak a result. Set by CompanionManager.
    var speakResult: ((String) async -> Void)?

    /// Maximum concurrent background tasks. Set to 4 to match the
    /// subagent coordinator — M-series chips can handle 4 parallel
    /// planner turns without contention when using Apple FM.
    private let maxConcurrent = 4

    private var runningTasks: [String: Task<Void, Never>] = [:]
    private var executionIds: [String: UUID] = [:]
    private let storageURL: URL?
    @Published private(set) var persistenceError: String?

    init(storageURL: URL? = nil) {
        // Unit tests use an explicit temporary file or a memory-only instance.
        self.storageURL = storageURL
        restoreTasks()
    }

    private static var defaultStorageURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pace/background-tasks.json")
    }

    private func restoreTasks() {
        guard let storageURL, FileManager.default.fileExists(atPath: storageURL.path) else { return }
        do {
            tasks = try JSONDecoder().decode([PaceBackgroundAgentTask].self, from: Data(contentsOf: storageURL))
            for index in tasks.indices where tasks[index].state == .running || tasks[index].state == .queued {
                // A crashed planner may already have performed an external action.
                // Never silently replay its prompt after launching again.
                tasks[index].state = .interrupted
                tasks[index].currentStepDescription = "Interrupted by restart. Review before retrying."
            }
            persistTasks()
        } catch {
            persistenceError = "Could not restore background tasks: \(error.localizedDescription)"
        }
    }

    private func persistTasks() {
        guard let storageURL else { return }
        do {
            // Preserve an unreadable queue rather than overwriting recoverable data.
            guard persistenceError == nil else { return }
            try FileManager.default.createDirectory(
                at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(tasks).write(to: storageURL, options: .atomic)
        } catch {
            persistenceError = "Background tasks could not be saved: \(error.localizedDescription)"
        }
    }

    /// Retry starts the original prompt from the beginning; it is not a checkpoint resume.
    @discardableResult
    func retry(taskId: String) -> Bool {
        guard persistenceError == nil else { return false }
        guard let index = tasks.firstIndex(where: { $0.id == taskId }) else { return false }
        switch tasks[index].state {
        case .interrupted, .failed, .cancelled:
            let previousTask = tasks[index]
            tasks[index].state = .queued
            tasks[index].startedAt = nil
            tasks[index].completedAt = nil
            tasks[index].resultSummary = nil
            tasks[index].stepCount = 0
            tasks[index].currentStepDescription = nil
            persistTasks()
            guard persistenceError == nil else {
                tasks[index] = previousTask
                return false
            }
            startNextQueuedTask()
            return true
        default:
            return false
        }
    }

    func matchingTask(named name: String) -> PaceBackgroundAgentTask? {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else { return nil }
        if let exactId = tasks.first(where: { $0.id.caseInsensitiveCompare(normalizedName) == .orderedSame }) {
            return exactId
        }
        let exactNames = tasks.filter { $0.displayName.caseInsensitiveCompare(normalizedName) == .orderedSame }
        if !exactNames.isEmpty { return exactNames.count == 1 ? exactNames.first : nil }
        let matches = tasks.filter { $0.displayName.localizedCaseInsensitiveContains(normalizedName) }
        return matches.count == 1 ? matches.first : nil
    }

    func taskDescription(_ task: PaceBackgroundAgentTask) -> String {
        let status: String
        switch task.state {
        case .queued: status = "queued"
        case .running: status = task.currentStepDescription ?? "running"
        case .interrupted: status = "interrupted by restart; retry restarts from the beginning"
        case .completed: status = task.resultSummary ?? "completed"
        case .cancelled: status = "cancelled"
        case .failed(let message): status = "failed: \(message)"
        }
        return "\(task.displayName) (\(task.id)): \(status)"
    }

    // MARK: - Task lifecycle

    /// Enqueue a background task. Starts immediately if under the
    /// concurrency limit. Higher-priority tasks jump the queue.
    func enqueue(
        prompt: String,
        displayName: String,
        priority: PaceBackgroundAgentPriority = .normal,
        isScheduled: Bool = false
    ) -> String {
        let id = "bg-\(UUID().uuidString.prefix(8))"
        let task = PaceBackgroundAgentTask(
            id: id,
            displayName: displayName,
            prompt: prompt,
            priority: priority,
            state: .queued,
            startedAt: nil,
            completedAt: nil,
            resultSummary: nil,
            stepCount: 0,
            currentStepDescription: nil,
            isScheduled: isScheduled
        )
        tasks.append(task)
        persistTasks()

        if runningTasks.count < maxConcurrent {
            startNextQueuedTask()
        }

        return id
    }

    /// Cancel a running or queued task.
    func cancel(taskId: String) {
        guard let task = tasks.first(where: { $0.id == taskId }) else { return }
        guard task.state == .running || task.state == .queued || task.state == .interrupted else { return }
        runningTasks[taskId]?.cancel()
        runningTasks.removeValue(forKey: taskId)
        executionIds.removeValue(forKey: taskId)
        updateTask(taskId) { task in
            task.state = .cancelled
            task.completedAt = Date()
        }
        // Start next queued task if a slot freed up.
        startNextQueuedTask()
    }

    /// Remove completed/cancelled/failed tasks from the list.
    func clearCompleted() {
        tasks.removeAll { task in
            switch task.state {
            case .completed, .cancelled, .failed:
                return true
            default:
                return false
            }
        }
        persistTasks()
    }

    /// Update progress for a running task. Called by the executing
    /// code to report step-level progress for UI display.
    func updateProgress(taskId: String, stepDescription: String, stepCount: Int? = nil) {
        updateTask(taskId) { task in
            task.currentStepDescription = stepDescription
            if let stepCount {
                task.stepCount = stepCount
            }
        }
    }

    // MARK: - Execution

    /// Start the highest-priority queued task, if any. Same-priority
    /// tasks dequeue in insertion (FIFO) order — a single linear scan
    /// that only replaces on strictly-greater priority guarantees this,
    /// where `sorted` with an equal-elements comparator would not
    /// (Swift's sort is not documented as stable).
    private func startNextQueuedTask() {
        guard runningTasks.count < maxConcurrent, persistenceError == nil else { return }
        var nextTask: PaceBackgroundAgentTask?
        for queuedTask in tasks where queuedTask.state == .queued {
            if let currentBest = nextTask {
                if queuedTask.priority > currentBest.priority {
                    nextTask = queuedTask
                }
            } else {
                nextTask = queuedTask
            }
        }
        guard let nextTask else { return }
        startTask(nextTask.id)
    }

    private func startTask(_ taskId: String) {
        guard let taskIndex = tasks.firstIndex(where: { $0.id == taskId }) else { return }
        tasks[taskIndex].state = .running
        tasks[taskIndex].startedAt = Date()
        tasks[taskIndex].currentStepDescription = "Starting..."
        persistTasks()
        guard persistenceError == nil else {
            tasks[taskIndex].state = .interrupted
            tasks[taskIndex].currentStepDescription = "Could not save this task; execution did not start."
            return
        }
        let executionId = UUID()
        executionIds[taskId] = executionId

        let prompt = tasks[taskIndex].prompt

        runningTasks[taskId] = Task.detached(priority: .background) { [weak self] in
            await self?.executeTask(taskId: taskId, executionId: executionId, prompt: prompt)
        }
    }

    private func executeTask(taskId: String, executionId: UUID, prompt: String) async {
        defer {
            if executionIds[taskId] == executionId {
                runningTasks.removeValue(forKey: taskId)
                executionIds.removeValue(forKey: taskId)
                startNextQueuedTask()
            }
        }
        do {
            try Task.checkCancellation()
            guard executionIds[taskId] == executionId else { return }
            let isScheduled = tasks.first(where: { $0.id == taskId })?.isScheduled == true
            guard let executePlannerTurn = isScheduled ? executeScheduledPlannerTurn : executePlannerTurn else {
                await MainActor.run {
                    self.updateTask(taskId) { task in
                        task.state = .failed("No planner callback set")
                        task.completedAt = Date()
                    }
                }
                return
            }

            await MainActor.run {
                self.updateTask(taskId) { task in
                    task.currentStepDescription = "Thinking..."
                    task.stepCount = 1
                }
            }

            let result = try await executePlannerTurn(prompt)

            // Check for cancellation before speaking.
            try Task.checkCancellation()
            guard executionIds[taskId] == executionId else { return }

            await MainActor.run {
                self.updateTask(taskId) { task in
                    task.state = .completed
                    task.completedAt = Date()
                    task.resultSummary = result
                    task.currentStepDescription = "Done"
                }
            }

            // Speak the result through the restraint gate.
            if let speakResult, !result.isEmpty {
                await speakResult(
                    "\(tasks.first(where: { $0.id == taskId })?.displayName ?? "Background task") completed.\n\n\(result)"
                )
            }
        } catch is CancellationError {
            guard executionIds[taskId] == executionId else { return }
            await MainActor.run {
                self.updateTask(taskId) { task in
                    task.state = .cancelled
                    task.completedAt = Date()
                }
            }
        } catch {
            guard executionIds[taskId] == executionId else { return }
            await MainActor.run {
                self.updateTask(taskId) { task in
                    task.state = .failed(error.localizedDescription)
                    task.completedAt = Date()
                }
            }
            if let speakResult {
                await speakResult(
                    "Background task failed: \(error.localizedDescription). Use list background tasks to review it.")
            }
        }

    }

    private func updateTask(_ taskId: String, _ update: (inout PaceBackgroundAgentTask) -> Void) {
        guard let index = tasks.firstIndex(where: { $0.id == taskId }) else { return }
        update(&tasks[index])
        persistTasks()
    }

    /// Whether any background tasks are currently running.
    var hasRunningTasks: Bool {
        tasks.contains(where: { $0.state == .running })
    }

    /// Number of tasks in each state, for UI summary.
    var queueSummary: (running: Int, queued: Int, completed: Int) {
        var running = 0, queued = 0, completed = 0
        for task in tasks {
            switch task.state {
            case .running: running += 1
            case .queued: queued += 1
            case .completed, .cancelled, .failed, .interrupted: completed += 1
            }
        }
        return (running, queued, completed)
    }
}
