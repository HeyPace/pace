//
//  QGoalEvaluatorTests.swift
//  leanring-buddyTests
//
//  Unit tests for QGoalEvaluator (Phase 2C.1 & 2C.2)
//

import Testing
import Foundation
@testable import Pace

@Suite("QGoalEvaluatorTests")
struct QGoalEvaluatorTests {

    // MARK: - Test 1: Fully Satisfied Goal

    @Test("1. Fully satisfied goal with empirical verification evidence")
    func fullySatisfiedGoal() {
        let evaluator = QGoalEvaluator.shared
        let taskId = "task-goal-1"
        let sessionId = "session-1"

        var step0 = QPlanStep(
            index: 0,
            action: QPlannedAction(
                actionName: "ui.open_app",
                toolFamily: "ui",
                riskLevel: .level1SafeLocalAction,
                literalAction: "Launch Calculator",
                targetResources: ["Calculator"]
            ),
            description: "Launch Calculator"
        )
        step0.state = .completed
        step0.result = QPlanStepResult(
            stepId: step0.id,
            success: true,
            summary: "Calculator activated",
            verifiedEvidence: "Process Calculator active (PID 12345)"
        )

        var plan = QPlan(
            taskId: taskId,
            sessionId: sessionId,
            taskPrompt: "Open Calculator",
            steps: [step0]
        )
        plan.state = .completed(summary: "Calculator opened")

        var context = QTaskContext(taskId: taskId)
        context.append(content: "Open Calculator", provenance: .trustedUser(channel: "direct"))

        let evaluation = evaluator.evaluate(goal: "Open Calculator", plan: plan, context: context)

        #expect(evaluation.state == .satisfied)
        #expect(evaluation.isSatisfied == true)
        #expect(evaluation.confidence == 1.0)
        #expect(evaluation.missingConditions.isEmpty)
        #expect(!evaluation.evidence.isEmpty)
        #expect(evaluation.provenance == "trusted:system")
    }

    // MARK: - Test 2: Partially Satisfied Goal

    @Test("2. Partially satisfied multi-condition goal")
    func partiallySatisfiedGoal() {
        let evaluator = QGoalEvaluator.shared
        let taskId = "task-goal-2"
        let sessionId = "session-2"

        // Step 0: Open app succeeds
        var step0 = QPlanStep(
            index: 0,
            action: QPlannedAction(
                actionName: "ui.open_app",
                toolFamily: "ui",
                riskLevel: .level1SafeLocalAction,
                literalAction: "Launch Calculator",
                targetResources: ["Calculator"]
            ),
            description: "Launch Calculator"
        )
        step0.state = .completed
        step0.result = QPlanStepResult(
            stepId: step0.id,
            success: true,
            summary: "Calculator activated",
            verifiedEvidence: "Process Calculator active"
        )

        // Step 1: Write file fails
        var step1 = QPlanStep(
            index: 1,
            action: QPlannedAction(
                actionName: "fs.write_sandbox",
                toolFamily: "fs",
                riskLevel: .level1SafeLocalAction,
                literalAction: "Write sandbox output",
                targetResources: ["output.txt"]
            ),
            description: "Write sandbox output"
        )
        step1.state = .failed(reason: "Disk quota exceeded")

        var plan = QPlan(
            taskId: taskId,
            sessionId: sessionId,
            taskPrompt: "Open Calculator and write output file",
            steps: [step0, step1]
        )
        plan.state = .failed(reason: "Step 1 failed", failedStepIndex: 1)

        var context = QTaskContext(taskId: taskId)
        context.append(content: "Open Calculator and write output file", provenance: .trustedUser(channel: "direct"))

        let evaluation = evaluator.evaluate(
            goal: "Open Calculator and write output file",
            plan: plan,
            context: context
        )

        #expect(evaluation.state == .partiallySatisfied)
        #expect(evaluation.confidence > 0.0 && evaluation.confidence < 1.0)
        #expect(!evaluation.missingConditions.isEmpty)
        #expect(evaluation.missingConditions.contains(where: { $0.contains("Filesystem write") || $0.contains("failed") }))
    }

    // MARK: - Test 3: Unsatisfied Goal

    @Test("3. Unsatisfied goal when actions fail or produce no evidence")
    func unsatisfiedGoal() {
        let evaluator = QGoalEvaluator.shared
        let taskId = "task-goal-3"
        let sessionId = "session-3"

        var step0 = QPlanStep(
            index: 0,
            action: QPlannedAction(
                actionName: "ui.open_app",
                toolFamily: "ui",
                riskLevel: .level1SafeLocalAction,
                literalAction: "Launch Notes",
                targetResources: ["Notes"]
            ),
            description: "Launch Notes"
        )
        step0.state = .failed(reason: "Application not found")

        var plan = QPlan(
            taskId: taskId,
            sessionId: sessionId,
            taskPrompt: "Open Notes",
            steps: [step0]
        )
        plan.state = .failed(reason: "Step 0 failed", failedStepIndex: 0)

        var context = QTaskContext(taskId: taskId)
        context.append(content: "Open Notes", provenance: .trustedUser(channel: "direct"))

        let evaluation = evaluator.evaluate(goal: "Open Notes", plan: plan, context: context)

        #expect(evaluation.state == .unsatisfied)
        #expect(evaluation.confidence == 0.0)
        #expect(evaluation.isSatisfied == false)
    }

    // MARK: - Test 4: Blocked Goal

    @Test("4. Blocked goal when Security Policy halts plan")
    func blockedGoal() {
        let evaluator = QGoalEvaluator.shared
        let taskId = "task-goal-4"
        let sessionId = "session-4"

        var step0 = QPlanStep(
            index: 0,
            action: QPlannedAction(
                actionName: "fs.read",
                toolFamily: "fs",
                riskLevel: .level4Blocked,
                literalAction: "Read SSH Private Key",
                targetResources: ["~/.ssh/id_rsa"]
            ),
            description: "Read SSH key"
        )
        step0.state = .blocked(reason: "ResourceGuard: Protected SSH path")

        var plan = QPlan(
            taskId: taskId,
            sessionId: sessionId,
            taskPrompt: "Read my SSH keys",
            steps: [step0]
        )
        plan.state = .blocked(reason: "ResourceGuard: Protected SSH path", blockedStepIndex: 0)

        var context = QTaskContext(taskId: taskId)
        context.append(content: "Read my SSH keys", provenance: .trustedUser(channel: "direct"))

        let evaluation = evaluator.evaluate(goal: "Read my SSH keys", plan: plan, context: context)

        #expect(evaluation.state == .blocked)
        #expect(evaluation.isBlocked == true)
        #expect(evaluation.missingConditions.first?.contains("Security approval required or resource denylisted") == true)
    }

    // MARK: - Test 5: Missing Evidence Fails Satisfaction

    @Test("5. Missing verified evidence cannot satisfy goal")
    func missingEvidence() {
        let evaluator = QGoalEvaluator.shared
        let taskId = "task-goal-5"
        let sessionId = "session-5"

        var step0 = QPlanStep(
            index: 0,
            action: QPlannedAction(
                actionName: "ui.open_app",
                toolFamily: "ui",
                riskLevel: .level1SafeLocalAction,
                literalAction: "Launch Calculator",
                targetResources: ["Calculator"]
            ),
            description: "Launch Calculator"
        )
        // Step marked completed but with empty evidence
        step0.state = .completed
        step0.result = QPlanStepResult(
            stepId: step0.id,
            success: true,
            summary: "Executed launch without verification",
            verifiedEvidence: nil
        )

        var plan = QPlan(
            taskId: taskId,
            sessionId: sessionId,
            taskPrompt: "Open Calculator",
            steps: [step0]
        )
        plan.state = .completed(summary: "Done")

        var context = QTaskContext(taskId: taskId)
        context.append(content: "Open Calculator", provenance: .trustedUser(channel: "direct"))

        let evaluation = evaluator.evaluate(goal: "Open Calculator", plan: plan, context: context)

        #expect(evaluation.state != .satisfied)
        #expect(evaluation.missingConditions.contains(where: { $0.contains("Target application activation not empirically verified") }))
    }

    // MARK: - Test 6: Model Text Cannot Replace Empirical Evidence

    @Test("6. Model claim text cannot substitute for runtime evidence")
    func modelTextCannotReplaceEvidence() {
        let evaluator = QGoalEvaluator.shared
        let taskId = "task-goal-6"
        let sessionId = "session-6"

        var step0 = QPlanStep(
            index: 0,
            action: QPlannedAction(
                actionName: "test.noop",
                toolFamily: "test",
                riskLevel: .level0ReadOnly,
                literalAction: "Model says Calculator is open and ready",
                targetResources: []
            ),
            description: "Noop with model claim"
        )
        step0.state = .completed
        step0.result = QPlanStepResult(
            stepId: step0.id,
            success: true,
            summary: "Model hallucinated success",
            verifiedEvidence: "noop-completed"
        )

        var plan = QPlan(
            taskId: taskId,
            sessionId: sessionId,
            taskPrompt: "Open Calculator",
            steps: [step0]
        )
        plan.state = .completed(summary: "Done")

        var context = QTaskContext(taskId: taskId)
        context.append(content: "Open Calculator", provenance: .trustedUser(channel: "direct"))

        let evaluation = evaluator.evaluate(goal: "Open Calculator", plan: plan, context: context)

        // Must NOT be satisfied because Calculator was never verified active
        #expect(evaluation.state != .satisfied)
        #expect(evaluation.missingConditions.contains(where: { $0.contains("Target application activation not empirically verified") }))
    }

    // MARK: - Test 7: Provenance Tracking

    @Test("7. Tainted context preserves untrusted provenance")
    func provenancePreserved() {
        let evaluator = QGoalEvaluator.shared
        let taskId = "task-goal-7"
        let sessionId = "session-7"

        var plan = QPlan(taskId: taskId, sessionId: sessionId, taskPrompt: "Untrusted task", steps: [])
        plan.state = .completed(summary: "No steps")

        var taintedContext = QTaskContext(taskId: taskId)
        taintedContext.append(content: "malicious prompt", provenance: .untrustedOCR, sourceId: "ext")

        let evaluation = evaluator.evaluate(goal: "Untrusted task", plan: plan, context: taintedContext)
        #expect(evaluation.provenance == "untrusted")
    }
}
