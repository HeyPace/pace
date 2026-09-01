//
//  QAgentBudgetTests.swift
//  leanring-buddyTests
//
//  Q Security Architecture — Task Budget & Resource Bounds Tests (Phase 2D).
//  Validates max step limits, max replan limits, timeout constraints, and fail-closed exhaustion.
//

import Testing
import Foundation
@testable import Pace

@Suite("QAgentBudgetTests")
struct QAgentBudgetTests {

    @Test("1. Exceeding max execution steps halts execution")
    func stepLimitExhaustion() {
        var budget = QAgentBudget(maxExecutionSteps: 3)
        #expect(budget.evaluateBudget() == .withinBudget)

        budget.recordStepExecution(success: true)
        budget.recordStepExecution(success: true)
        #expect(budget.evaluateBudget() == .withinBudget)

        budget.recordStepExecution(success: true)
        let decision = budget.evaluateBudget()
        if case .exhausted(let reason, _) = decision {
            #expect(reason == .stepLimitExceeded)
        } else {
            #expect(Bool(false), "Expected stepLimitExceeded")
        }
    }

    @Test("2. Exceeding max replan limit halts execution")
    func replanLimitExhaustion() {
        var budget = QAgentBudget(maxReplans: 2)
        budget.recordReplan()
        budget.recordReplan()
        #expect(budget.evaluateBudget() == .withinBudget)

        budget.recordReplan()
        let decision = budget.evaluateBudget()
        if case .exhausted(let reason, _) = decision {
            #expect(reason == .replanLimitExceeded)
        } else {
            #expect(Bool(false), "Expected replanLimitExceeded")
        }
    }

    @Test("3. Consecutive failures threshold triggers fail-closed halt")
    func consecutiveFailuresExhaustion() {
        var budget = QAgentBudget(maxConsecutiveFailures: 2)
        budget.recordStepExecution(success: false)
        #expect(budget.evaluateBudget() == .withinBudget)

        budget.recordStepExecution(success: false)
        let decision = budget.evaluateBudget()
        if case .exhausted(let reason, _) = decision {
            #expect(reason == .consecutiveFailuresExceeded)
        } else {
            #expect(Bool(false), "Expected consecutiveFailuresExceeded")
        }
    }

    @Test("4. Successful step resets consecutive failure counter")
    func successfulStepResetsFailureCounter() {
        var budget = QAgentBudget(maxConsecutiveFailures: 2)
        budget.recordStepExecution(success: false)
        #expect(budget.consecutiveFailuresCount == 1)

        budget.recordStepExecution(success: true)
        #expect(budget.consecutiveFailuresCount == 0)
        #expect(budget.evaluateBudget() == .withinBudget)
    }

    @Test("5. Duration timeout triggers budget exhaustion")
    func durationTimeoutExhaustion() {
        let pastDate = Date().addingTimeInterval(-400) // 400 seconds ago
        let budget = QAgentBudget(maxDurationSeconds: 300, startedAt: pastDate)

        let decision = budget.evaluateBudget()
        if case .exhausted(let reason, _) = decision {
            #expect(reason == .durationExceeded)
        } else {
            #expect(Bool(false), "Expected durationExceeded")
        }
    }
}
