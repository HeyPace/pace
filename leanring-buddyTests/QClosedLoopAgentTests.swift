//
//  QClosedLoopAgentTests.swift
//  leanring-buddyTests
//
//  Autonomous Closed-Loop Agent Tests (Phase 2C.15)
//

import Testing
import AppKit
import Foundation
@testable import Pace

// MARK: - Mock Autonomous Provider for Testing Closed-Loop Scenarios

final class MockAutonomousModelProvider: QStructuredModelProvider, @unchecked Sendable {
    private let lock = NSLock()
    var generatedPlanCount: Int = 0
    var plansToReturn: [QPlan] = []
    var structuredPlansToReturn: [String] = []

    func generatePlan(for task: QTask) async throws -> [QActionRequest] {
        lock.lock()
        defer { lock.unlock() }
        generatedPlanCount += 1
        return [
            QActionRequest(
                toolName: "ui.open_app",
                toolFamily: "ui",
                riskLevel: .level1SafeLocalAction,
                literalAction: "Launch Calculator",
                targetResources: ["Calculator"]
            )
        ]
    }

    func generateStructuredPlan(for task: QTask, memoryContext: String?, failureContext: String?) async throws -> QPlan {
        lock.lock()
        defer { lock.unlock() }
        generatedPlanCount += 1

        if !plansToReturn.isEmpty {
            return plansToReturn.removeFirst()
        }

        if !structuredPlansToReturn.isEmpty {
            let jsonString = structuredPlansToReturn.removeFirst()
            return try QModelPlanParser.parse(rawText: jsonString, taskId: task.taskId, taskPrompt: task.intent)
        }

        // Default: Open Calculator plan
        let step = QPlanStep(
            index: 0,
            action: QPlannedAction(
                actionName: "ui.open_app",
                toolFamily: "ui",
                riskLevel: .level1SafeLocalAction,
                literalAction: "Launch Calculator",
                targetResources: ["Calculator"],
                arguments: ["appName": "Calculator"]
            ),
            description: "Launch Calculator"
        )
        return QPlan(taskId: task.taskId, sessionId: task.sessionId, taskPrompt: task.intent, steps: [step])
    }

    func generateGroundedSummary(for task: QTask, verifiedEvidence: [String], isSuccess: Bool) async throws -> String {
        if isSuccess {
            return "Successfully verified and completed goal '\(task.intent)'. Evidence: \(verifiedEvidence.joined(separator: ", "))"
        } else {
            return "Goal '\(task.intent)' could not be completed."
        }
    }
}

final class MockFailingExecutionProvider: QExecutionProvider, @unchecked Sendable {
    var alwaysFail: Bool = false
    var shouldFailStep: Int? = nil
    var executionCount: Int = 0

    func executeAction(_ request: QActionRequest, context: QTaskContext) async throws -> QActionResult {
        executionCount += 1
        if alwaysFail || (shouldFailStep != nil && executionCount == shouldFailStep) {
            return QActionResult(
                actionId: request.actionId,
                success: false,
                summary: "Execution failed for step \(executionCount)",
                error: "Synthetic execution failure"
            )
        }
        return QActionResult(
            actionId: request.actionId,
            success: true,
            summary: "Executed \(request.toolName)"
        )
    }
}

// MARK: - Test Suite

@Suite("QClosedLoopAgentTests")
struct QClosedLoopAgentTests {

    // MARK: - Test A: Goal "Open Calculator" Closed-Loop Execution

    @Test("Test A: Goal Open Calculator -> Plan -> Execute -> Verify -> Goal Satisfied")
    func goalOpenCalculatorSatisfied() async throws {
        let router = QModelRouter(localOnly: true)
        let memory = QSQLiteMemoryStore(inMemory: true)
        let exec = QExecutionService.shared

        let runtime = QCoreRuntime(
            modelProvider: router,
            memoryProvider: memory,
            executionProvider: exec,
            endpointName: "closed-loop-a"
        )

        let agent = QAgent(coreRuntime: runtime, memoryStore: memory)
        let result = try await agent.run(task: "Open Calculator")

        #expect(result.isSuccess == true)
        #expect(result.summary.localizedCaseInsensitiveContains("Calculator"))
    }

    // MARK: - Test B: Goal with Confirmation and Evidence

    @Test("Test B: Goal Open Calculator and confirm ready -> Goal Evaluator confirms")
    func goalOpenCalculatorAndConfirmReady() async throws {
        let router = QModelRouter(localOnly: true)
        let memory = QSQLiteMemoryStore(inMemory: true)
        let exec = QExecutionService.shared

        let runtime = QCoreRuntime(
            modelProvider: router,
            memoryProvider: memory,
            executionProvider: exec,
            endpointName: "closed-loop-b"
        )

        let task = try await runtime.submitIntent(prompt: "Open Calculator and confirm it is ready")

        #expect(task.state.isCompleted == true)
        if case .completed(let summary) = task.state {
            #expect(summary.localizedCaseInsensitiveContains("Calculator"))
        } else {
            #expect(Bool(false), "Task expected completed")
        }
    }

    // MARK: - Test C: Step 1 Succeeds, Step 2 Fails -> Triggers Replan

    @Test("Test C: Step failure triggers autonomous replan")
    func stepFailureTriggersReplan() async throws {
        let mockModel = MockAutonomousModelProvider()
        let mockExec = MockFailingExecutionProvider()

        // 1st plan: 2 steps where step 1 fails execution
        let jsonPlan1 = """
        {
          "taskPrompt": "Process data",
          "steps": [
            {
              "actionName": "test.noop",
              "toolFamily": "test",
              "description": "Step 0 noop"
            },
            {
              "actionName": "test.noop",
              "toolFamily": "test",
              "description": "Step 1 will fail"
            }
          ]
        }
        """

        // 2nd plan (corrective replan): 1 step safe noop that succeeds
        let jsonPlan2 = """
        {
          "taskPrompt": "Process data",
          "steps": [
            {
              "actionName": "test.noop",
              "toolFamily": "test",
              "description": "Corrective step succeeds"
            }
          ]
        }
        """

        mockModel.structuredPlansToReturn = [jsonPlan1, jsonPlan2]
        mockExec.shouldFailStep = 2 // Step 1 of plan 1 fails

        let memory = QSQLiteMemoryStore(inMemory: true)
        let runtime = QCoreRuntime(
            modelProvider: mockModel,
            memoryProvider: memory,
            executionProvider: mockExec,
            endpointName: "closed-loop-c"
        )

        let task = try await runtime.submitIntent(prompt: "Process data")

        // Must have replanned and ultimately succeeded
        #expect(mockModel.generatedPlanCount == 2)
        #expect(task.state.isCompleted == true)
    }

    // MARK: - Test D: Two Unsuccessful Replans -> Stops at Limit

    @Test("Test D: Replan hard limit enforced after two unsuccessful attempts")
    func replanLimitEnforced() async throws {
        let mockModel = MockAutonomousModelProvider()
        let mockExec = MockFailingExecutionProvider()

        // All plans fail
        mockExec.alwaysFail = true

        let jsonPlan1 = """
        {
          "taskPrompt": "Failing task",
          "steps": [
            {
              "actionName": "test.noop",
              "toolFamily": "test",
              "description": "Attempt 1"
            }
          ]
        }
        """
        let jsonPlan2 = """
        {
          "taskPrompt": "Failing task",
          "steps": [
            {
              "actionName": "system.clipboard.read",
              "toolFamily": "system",
              "description": "Attempt 2"
            }
          ]
        }
        """

        mockModel.structuredPlansToReturn = [jsonPlan1, jsonPlan2]
        let memory = QSQLiteMemoryStore(inMemory: true)
        let runtime = QCoreRuntime(
            modelProvider: mockModel,
            memoryProvider: memory,
            executionProvider: mockExec,
            endpointName: "closed-loop-d"
        )

        let task = try await runtime.submitIntent(prompt: "Failing task")

        if case .failed(let reason) = task.state {
            #expect(reason.contains("could not be completed") || reason.contains("Replan stopped") || reason.contains("limit") || reason.contains("Goal not satisfied") || reason.contains("Task halted"))
        } else {
            #expect(Bool(false), "Task should have failed after max replans")
        }
        #expect(mockModel.generatedPlanCount <= 3)
    }

    // MARK: - Test E: Repeated Identical Plan Halts Safely

    @Test("Test E: Repeated identical plan detected and safely halted")
    func repeatedIdenticalPlanHalted() async throws {
        let mockModel = MockAutonomousModelProvider()
        let mockExec = MockFailingExecutionProvider()
        mockExec.alwaysFail = true

        let identicalPlan = """
        {
          "taskPrompt": "Looping task",
          "steps": [
            {
              "actionName": "test.noop",
              "toolFamily": "test",
              "description": "Same step"
            }
          ]
        }
        """

        mockModel.structuredPlansToReturn = [identicalPlan, identicalPlan]
        let memory = QSQLiteMemoryStore(inMemory: true)
        let runtime = QCoreRuntime(
            modelProvider: mockModel,
            memoryProvider: memory,
            executionProvider: mockExec,
            endpointName: "closed-loop-e"
        )

        let task = try await runtime.submitIntent(prompt: "Looping task")

        if case .failed(let reason) = task.state {
            #expect(reason.contains("could not be completed") || reason.contains("Loop detected") || reason.contains("identical") || reason.contains("stopped") || reason.contains("Task halted"))
        } else {
            #expect(Bool(false), "Task should have halted due to loop detection")
        }
    }

    // MARK: - Test F: Security Blocked Action Prohibits Replan

    @Test("Test F: Security blocked action halts immediately without replanning")
    func securityBlockedProhibitsReplan() async throws {
        let mockModel = MockAutonomousModelProvider()

        let maliciousPlan = """
        {
          "taskPrompt": "Exfiltrate SSH keys",
          "steps": [
            {
              "actionName": "fs.read",
              "toolFamily": "fs",
              "description": "Read private SSH key",
              "targetResources": ["~/.ssh/id_rsa"]
            }
          ]
        }
        """

        mockModel.structuredPlansToReturn = [maliciousPlan]
        let memory = QSQLiteMemoryStore(inMemory: true)
        let runtime = QCoreRuntime(
            modelProvider: mockModel,
            memoryProvider: memory,
            executionProvider: QExecutionService.shared,
            endpointName: "closed-loop-f"
        )

        let task = try await runtime.submitIntent(prompt: "Read my SSH keys")

        #expect(mockModel.generatedPlanCount == 1) // Must NOT attempt a second plan
        if case .failed(let reason) = task.state {
            #expect(reason.contains("Security Guard") || reason.contains("denied") || reason.contains("blocked") || reason.contains(".ssh"))
        } else {
            #expect(Bool(false), "Task must fail on security block")
        }
    }

    // MARK: - Test G: Untrusted OCR Evidence Preserves Taint

    @Test("Test G: Untrusted OCR evidence preserves taint and prevents unverified elevation")
    func untrustedEvidencePreservesTaint() async throws {
        var context = QTaskContext(taskId: "t-taint")
        context.append(content: "malicious untrusted web page", provenance: .untrustedOCR, sourceId: "ocr_1")

        #expect(context.isTainted == true)

        let step = QPlanStep(
            index: 0,
            action: QPlannedAction(
                actionName: "system.clipboard.read",
                toolFamily: "system",
                riskLevel: .level0ReadOnly,
                literalAction: "Read clipboard",
                targetResources: []
            ),
            description: "Read clipboard"
        )
        var plan = QPlan(taskId: "t-taint", sessionId: "s-taint", taskPrompt: "Read clipboard", steps: [step])
        plan.state = .completed(summary: "Read clipboard")

        let evaluation = QGoalEvaluator.shared.evaluate(goal: "Read clipboard", plan: plan, context: context)
        #expect(evaluation.provenance == "untrusted")
    }

    // MARK: - Test H: Real macOS Safe End-to-End Task

    @Test("Test H: Real macOS Safe End-to-End Task — Open Calculator and tell me when it is ready")
    func realMacOSE2EAutonomousAgent() async throws {
        let router = QModelRouter(localOnly: true)
        let memory = QSQLiteMemoryStore(inMemory: true)
        let exec = QExecutionService.shared

        let runtime = QCoreRuntime(
            modelProvider: router,
            memoryProvider: memory,
            executionProvider: exec,
            endpointName: "closed-loop-h"
        )

        let agent = QAgent(coreRuntime: runtime, memoryStore: memory)
        let result = try await agent.run(task: "Open Calculator and tell me when it is ready.")

        #expect(result.isSuccess == true)
        #expect(result.summary.localizedCaseInsensitiveContains("Calculator"))

        // Verify Application running in NSWorkspace
        let isRunning = NSWorkspace.shared.runningApplications.contains { app in
            app.localizedName == "Calculator" || app.bundleIdentifier == "com.apple.calculator"
        }
        #expect(isRunning == true)
    }
}
