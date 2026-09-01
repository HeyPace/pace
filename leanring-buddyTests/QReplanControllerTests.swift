//
//  QReplanControllerTests.swift
//  leanring-buddyTests
//
//  Unit tests for QReplanController (Phase 2C.4, 2C.5 & 2C.6)
//

import Testing
import Foundation
@testable import Pace

@Suite("QReplanControllerTests")
struct QReplanControllerTests {

    private func makeStep(actionName: String, literal: String, target: String) -> QPlanStep {
        QPlanStep(
            index: 0,
            action: QPlannedAction(
                actionName: actionName,
                toolFamily: "test",
                riskLevel: .level1SafeLocalAction,
                literalAction: literal,
                targetResources: [target]
            ),
            description: literal
        )
    }

    // MARK: - Test 1: First Replan Allowed

    @Test("1. First replan attempt is allowed within limit")
    func firstReplanAllowed() {
        let controller = QReplanController(maxReplans: 2)
        controller.reset()

        let plan = QPlan(taskId: "t1", sessionId: "s1", taskPrompt: "Open Calculator", steps: [makeStep(actionName: "ui.open_app", literal: "Launch Calculator", target: "Calculator")])
        let evaluation = QGoalEvaluation(
            goal: "Open Calculator",
            state: .unsatisfied,
            confidence: 0.0,
            evidence: [],
            completedConditions: [],
            missingConditions: ["Process activation not confirmed"],
            explanation: "Not running"
        )

        let decision = controller.evaluateReplan(goal: "Open Calculator", currentPlan: plan, evaluation: evaluation)
        if case .allow(let request) = decision {
            #expect(request.attemptNumber == 1)
            #expect(request.maxAttempts == 2)
            #expect(request.originalGoal == "Open Calculator")
            #expect(request.sanitizedPrompt.contains("Attempt 1/2"))
        } else {
            #expect(Bool(false), "Expected replan to be allowed on first attempt")
        }
    }

    // MARK: - Test 2: Second Replan Allowed

    @Test("2. Second replan attempt is allowed")
    func secondReplanAllowed() {
        let controller = QReplanController(maxReplans: 2)
        controller.reset()

        let plan1 = QPlan(taskId: "t2", sessionId: "s2", taskPrompt: "Open Notes", steps: [makeStep(actionName: "ui.open_app", literal: "Launch Notes", target: "Notes")])
        let eval1 = QGoalEvaluation(goal: "Open Notes", state: .unsatisfied, confidence: 0.0, evidence: [], completedConditions: [], missingConditions: ["Notes not active"], explanation: "Attempt 1 failed")

        controller.recordIteration(plan: plan1, evaluation: eval1)

        let plan2 = QPlan(taskId: "t2", sessionId: "s2", taskPrompt: "Open Notes", steps: [makeStep(actionName: "system.running_apps", literal: "Check running apps", target: "Notes")])
        let eval2 = QGoalEvaluation(goal: "Open Notes", state: .partiallySatisfied, confidence: 0.5, evidence: [], completedConditions: [], missingConditions: ["Notes not found in apps"], explanation: "Attempt 2 failed")

        let decision = controller.evaluateReplan(goal: "Open Notes", currentPlan: plan2, evaluation: eval2)
        if case .allow(let request) = decision {
            #expect(request.attemptNumber == 2)
            #expect(request.maxAttempts == 2)
        } else {
            #expect(Bool(false), "Expected replan to be allowed on second attempt")
        }
    }

    // MARK: - Test 3: Third Replan Denied (Hard Upper Bound)

    @Test("3. Third replan attempt is denied (Hard limit of 2 reached)")
    func thirdReplanDenied() {
        let controller = QReplanController(maxReplans: 2)
        controller.reset()

        let plan1 = QPlan(taskId: "t3", sessionId: "s3", taskPrompt: "Open Terminal", steps: [makeStep(actionName: "ui.open_app", literal: "Launch Terminal", target: "Terminal")])
        let eval1 = QGoalEvaluation(goal: "Open Terminal", state: .unsatisfied, confidence: 0.0, evidence: [], completedConditions: [], missingConditions: ["Fail 1"], explanation: "Fail 1")
        controller.recordIteration(plan: plan1, evaluation: eval1)

        let plan2 = QPlan(taskId: "t3", sessionId: "s3", taskPrompt: "Open Terminal", steps: [makeStep(actionName: "system.running_apps", literal: "Check Terminal", target: "Terminal")])
        let eval2 = QGoalEvaluation(goal: "Open Terminal", state: .unsatisfied, confidence: 0.0, evidence: [], completedConditions: [], missingConditions: ["Fail 2"], explanation: "Fail 2")
        controller.recordIteration(plan: plan2, evaluation: eval2)

        let plan3 = QPlan(taskId: "t3", sessionId: "s3", taskPrompt: "Open Terminal", steps: [makeStep(actionName: "accessibility.read", literal: "Read UI", target: "Terminal")])
        let eval3 = QGoalEvaluation(goal: "Open Terminal", state: .unsatisfied, confidence: 0.0, evidence: [], completedConditions: [], missingConditions: ["Fail 3"], explanation: "Fail 3")

        let decision = controller.evaluateReplan(goal: "Open Terminal", currentPlan: plan3, evaluation: eval3)
        if case .denied(let reason) = decision {
            #expect(reason.contains("maximum replan limit"))
        } else {
            #expect(Bool(false), "Expected replan to be denied on 3rd attempt")
        }
    }

    // MARK: - Test 4: Repeated Identical Plan Detected (Loop Detection)

    @Test("4. Loop detection rejects repeated identical plan")
    func loopDetectionIdenticalPlan() {
        let controller = QReplanController(maxReplans: 2)
        controller.reset()

        let plan1 = QPlan(taskId: "t4", sessionId: "s4", taskPrompt: "Write file", steps: [makeStep(actionName: "fs.write_sandbox", literal: "Write test.txt", target: "test.txt")])
        let eval1 = QGoalEvaluation(goal: "Write file", state: .unsatisfied, confidence: 0.0, evidence: [], completedConditions: [], missingConditions: ["Write failed"], explanation: "Failed")

        controller.recordIteration(plan: plan1, evaluation: eval1)

        // Attempting exact same plan again
        let plan2 = QPlan(taskId: "t4", sessionId: "s4", taskPrompt: "Write file", steps: [makeStep(actionName: "fs.write_sandbox", literal: "Write test.txt", target: "test.txt")])
        let eval2 = QGoalEvaluation(goal: "Write file", state: .unsatisfied, confidence: 0.0, evidence: [], completedConditions: [], missingConditions: ["Write failed"], explanation: "Failed again")

        let decision = controller.evaluateReplan(goal: "Write file", currentPlan: plan2, evaluation: eval2)
        if case .denied(let reason) = decision {
            #expect(reason.contains("Loop detected") || reason.contains("identical"))
        } else {
            #expect(Bool(false), "Expected identical plan to be rejected by loop detector")
        }
    }

    // MARK: - Test 5: Repeated Failed Action Detected

    @Test("5. Loop detection halts repeated action failures")
    func repeatedFailedActionDetected() {
        let controller = QReplanController(maxReplans: 3)
        controller.reset()

        var failedStep1 = makeStep(actionName: "fs.write_sandbox", literal: "Write data", target: "protected_dir/data.txt")
        failedStep1.state = .failed(reason: "Permission denied")
        let plan1 = QPlan(taskId: "t5", sessionId: "s5", taskPrompt: "Write data", steps: [failedStep1, makeStep(actionName: "test.noop", literal: "Noop 1", target: "")])
        let eval1 = QGoalEvaluation(goal: "Write data", state: .unsatisfied, confidence: 0.0, evidence: [], completedConditions: [], missingConditions: ["Failed"], explanation: "Err")
        controller.recordIteration(plan: plan1, evaluation: eval1)

        var failedStep2 = makeStep(actionName: "fs.write_sandbox", literal: "Write data again", target: "protected_dir/data.txt")
        failedStep2.state = .failed(reason: "Permission denied")
        let plan2 = QPlan(taskId: "t5", sessionId: "s5", taskPrompt: "Write data", steps: [failedStep2, makeStep(actionName: "system.clipboard.read", literal: "Clip", target: "")])
        let eval2 = QGoalEvaluation(goal: "Write data", state: .unsatisfied, confidence: 0.0, evidence: [], completedConditions: [], missingConditions: ["Failed"], explanation: "Err")
        controller.recordIteration(plan: plan2, evaluation: eval2)

        var failedStep3 = makeStep(actionName: "fs.write_sandbox", literal: "Write data third try", target: "protected_dir/data.txt")
        failedStep3.state = .failed(reason: "Permission denied")
        let plan3 = QPlan(taskId: "t5", sessionId: "s5", taskPrompt: "Write data", steps: [failedStep3])
        let eval3 = QGoalEvaluation(goal: "Write data", state: .unsatisfied, confidence: 0.0, evidence: [], completedConditions: [], missingConditions: ["Failed"], explanation: "Err")

        let decision = controller.evaluateReplan(goal: "Write data", currentPlan: plan3, evaluation: eval3)
        if case .denied(let reason) = decision {
            #expect(reason.contains("Repeated failure") || reason.contains("Halting"))
        } else {
            #expect(Bool(false), "Expected repeated action failures to be halted")
        }
    }

    // MARK: - Test 6: Terminal State Cannot Replan

    @Test("6. Satisfied goal cannot trigger replan")
    func satisfiedGoalCannotReplan() {
        let controller = QReplanController(maxReplans: 2)
        controller.reset()

        let plan = QPlan(taskId: "t6", sessionId: "s6", taskPrompt: "Open Notes", steps: [makeStep(actionName: "ui.open_app", literal: "Open Notes", target: "Notes")])
        let evaluation = QGoalEvaluation(
            goal: "Open Notes",
            state: .satisfied,
            confidence: 1.0,
            evidence: ["Notes active"],
            completedConditions: ["Notes active"],
            missingConditions: [],
            explanation: "All satisfied"
        )

        let decision = controller.evaluateReplan(goal: "Open Notes", currentPlan: plan, evaluation: evaluation)
        if case .denied(let reason) = decision {
            #expect(reason.contains("already fully satisfied"))
        } else {
            #expect(Bool(false), "Expected satisfied goal to deny replan")
        }
    }

    // MARK: - Test 7: Blocked Security State Cannot Replan

    @Test("7. Security blocked state strictly prohibits replanning")
    func securityBlockedCannotReplan() {
        let controller = QReplanController(maxReplans: 2)
        controller.reset()

        var blockedStep = makeStep(actionName: "fs.read", literal: "Read SSH keys", target: "~/.ssh/id_rsa")
        blockedStep.state = .blocked(reason: "Protected SSH path")

        var plan = QPlan(taskId: "t7", sessionId: "s7", taskPrompt: "Read keys", steps: [blockedStep])
        plan.state = .blocked(reason: "ResourceGuard Denied", blockedStepIndex: 0)

        let evaluation = QGoalEvaluation(
            goal: "Read keys",
            state: .blocked,
            confidence: 1.0,
            evidence: [],
            completedConditions: [],
            missingConditions: ["Security approval required"],
            explanation: "Security boundary blocked execution"
        )

        let decision = controller.evaluateReplan(goal: "Read keys", currentPlan: plan, evaluation: evaluation)
        if case .denied(let reason) = decision {
            #expect(reason.contains("security"))
        } else {
            #expect(Bool(false), "Expected security block to strictly prohibit replanning")
        }
    }

    // MARK: - Test 8: Counter Resets for New Task

    @Test("8. Replan counter resets on new task")
    func counterResetsOnNewTask() {
        let controller = QReplanController(maxReplans: 2)
        controller.reset()

        let plan = QPlan(taskId: "t8", sessionId: "s8", taskPrompt: "Old task", steps: [makeStep(actionName: "ui.open_app", literal: "Launch", target: "App")])
        let eval = QGoalEvaluation(goal: "Old task", state: .unsatisfied, confidence: 0.0, evidence: [], completedConditions: [], missingConditions: ["err"], explanation: "err")
        controller.recordIteration(plan: plan, evaluation: eval)
        controller.recordIteration(plan: plan, evaluation: eval)

        #expect(controller.getHistory().count == 2)

        controller.reset()
        #expect(controller.getHistory().isEmpty)
    }
}
