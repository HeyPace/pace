//
//  QPlanTests.swift
//  leanring-buddyTests
//
//  Q Security Architecture — Multi-Step Plan Foundation Test Suite (Phase 2A.1).
//  Validates plan data models, state machine transitions, and validation rules.
//

import Testing
import Foundation
@testable import Pace

@Suite("QPlanTests")
struct QPlanTests {

    // MARK: - Test 1: Create a Valid 3-Step Plan

    @Test("Test 1: Create a valid 3-step immutable plan with deterministic step indices")
    func testCreateValid3StepPlan() {
        let step0 = QPlanStep(
            index: 0,
            action: QPlannedAction(
                actionName: "system.running_apps",
                toolFamily: "system",
                riskLevel: .level0ReadOnly,
                literalAction: "Query running apps"
            ),
            description: "Query system processes"
        )

        let step1 = QPlanStep(
            index: 1,
            action: QPlannedAction(
                actionName: "system.clipboard.read",
                toolFamily: "system",
                riskLevel: .level0ReadOnly,
                literalAction: "Read system clipboard"
            ),
            description: "Read clipboard text"
        )

        let step2 = QPlanStep(
            index: 2,
            action: QPlannedAction(
                actionName: "ui.open_app",
                toolFamily: "app",
                riskLevel: .level1SafeLocalAction,
                literalAction: "Open Calculator",
                targetResources: ["Calculator"],
                arguments: ["appName": "Calculator"]
            ),
            description: "Launch Calculator"
        )

        let plan = QPlan(
            taskPrompt: "Check system, read clipboard, and open Calculator",
            steps: [step0, step1, step2]
        )

        #expect(plan.steps.count == 3)
        #expect(plan.steps[0].index == 0)
        #expect(plan.steps[1].index == 1)
        #expect(plan.steps[2].index == 2)
        #expect(plan.state == .pending)
        #expect(plan.isComplete == false)
    }

    // MARK: - Test 8: Invalid State Transitions Are Rejected

    @Test("Test 8: Invalid plan state transitions fail closed and are rejected")
    func testInvalidPlanStateTransitions() {
        // completed -> executing is INVALID
        #expect(QPlanStateValidator.canTransition(from: .completed(summary: "Done"), to: .executing(stepIndex: 0)) == false)

        // blocked -> executing is INVALID
        #expect(QPlanStateValidator.canTransition(from: .blocked(reason: "Denied", blockedStepIndex: 1), to: .executing(stepIndex: 1)) == false)

        // cancelled -> executing is INVALID
        #expect(QPlanStateValidator.canTransition(from: .cancelled(reason: "User cancelled"), to: .executing(stepIndex: 0)) == false)

        // failed -> completed is INVALID
        #expect(QPlanStateValidator.canTransition(from: .failed(reason: "Error", failedStepIndex: 0), to: .completed(summary: "Done")) == false)

        // pending -> running is VALID
        #expect(QPlanStateValidator.canTransition(from: .pending, to: .running) == true)

        // running -> executing is VALID
        #expect(QPlanStateValidator.canTransition(from: .running, to: .executing(stepIndex: 0)) == true)
    }

    @Test("Test 8b: Invalid step state transitions fail closed and are rejected")
    func testInvalidStepStateTransitions() {
        // completed -> executing is INVALID
        #expect(QPlanStateValidator.canTransitionStep(from: .completed, to: .executing) == false)

        // blocked -> executing is INVALID
        #expect(QPlanStateValidator.canTransitionStep(from: .blocked(reason: "Denied"), to: .executing) == false)

        // skipped -> executing is INVALID
        #expect(QPlanStateValidator.canTransitionStep(from: .skipped(reason: "Skipped"), to: .executing) == false)

        // pending -> executing is VALID
        #expect(QPlanStateValidator.canTransitionStep(from: .pending, to: .executing) == true)

        // executing -> verifying is VALID
        #expect(QPlanStateValidator.canTransitionStep(from: .executing, to: .verifying) == true)

        // verifying -> completed is VALID
        #expect(QPlanStateValidator.canTransitionStep(from: .verifying, to: .completed) == true)
    }

    // MARK: - Codable Round-Trip Test

    @Test("Test Codable serialization and deserialization of QPlan")
    func testCodableSerialization() throws {
        let step = QPlanStep(
            index: 0,
            action: QPlannedAction(
                actionName: "system.running_apps",
                toolFamily: "system",
                riskLevel: .level0ReadOnly,
                literalAction: "Query running apps"
            ),
            description: "Step 0"
        )

        let originalPlan = QPlan(taskPrompt: "Test serialization", steps: [step])

        let data = try JSONEncoder().encode(originalPlan)
        let decodedPlan = try JSONDecoder().decode(QPlan.self, from: data)

        #expect(decodedPlan.id == originalPlan.id)
        #expect(decodedPlan.taskPrompt == originalPlan.taskPrompt)
        #expect(decodedPlan.steps.count == 1)
        #expect(decodedPlan.steps[0].action.actionName == "system.running_apps")
    }
}
