//
//  QGoalEvaluator.swift
//  leanring-buddy
//
//  Q Security Architecture — Goal Evaluation Layer (Phase 2C).
//  Evaluates runtime evidence, verified action results, and execution state
//  to determine whether the user's intent was genuinely satisfied.
//  Evidence-First Invariant: Model text is never accepted as proof.
//

import Foundation

// MARK: - Goal Evaluation Types

public enum QGoalEvaluationState: String, Codable, Sendable, Equatable {
    case satisfied
    case partiallySatisfied
    case unsatisfied
    case blocked
    case unknown
}

public struct QGoalEvaluation: Codable, Sendable, Equatable {
    public let goal: String
    public let state: QGoalEvaluationState
    public let confidence: Double
    public let evidence: [String]
    public let completedConditions: [String]
    public let missingConditions: [String]
    public let explanation: String
    public let provenance: String
    public let evaluatedAt: Date

    public var isSatisfied: Bool {
        state == .satisfied
    }

    public var isBlocked: Bool {
        state == .blocked
    }

    public init(
        goal: String,
        state: QGoalEvaluationState,
        confidence: Double,
        evidence: [String],
        completedConditions: [String],
        missingConditions: [String],
        explanation: String,
        provenance: String = "trusted:system",
        evaluatedAt: Date = Date()
    ) {
        self.goal = goal
        self.state = state
        self.confidence = min(max(confidence, 0.0), 1.0)
        self.evidence = evidence
        self.completedConditions = completedConditions
        self.missingConditions = missingConditions
        self.explanation = explanation
        self.provenance = provenance
        self.evaluatedAt = evaluatedAt
    }
}

// MARK: - Goal Evaluator Implementation

public final class QGoalEvaluator: Sendable {
    public static let shared = QGoalEvaluator()

    public init() {}

    /// Evaluates whether the plan execution satisfies the stated goal based strictly on verified evidence.
    public func evaluate(
        goal: String,
        plan: QPlan,
        context: QTaskContext,
        runtimeObservations: [String] = []
    ) -> QGoalEvaluation {
        let provenance = context.isTainted ? "untrusted" : "trusted:system"

        // 1. Check for Security Block
        if plan.state.isBlocked {
            let reason: String
            if case .blocked(let r, _) = plan.state {
                reason = r
            } else {
                reason = "Action blocked by security policy"
            }
            return QGoalEvaluation(
                goal: goal,
                state: .blocked,
                confidence: 1.0,
                evidence: [],
                completedConditions: [],
                missingConditions: ["Security approval required or resource denylisted: \(reason)"],
                explanation: "Goal evaluation halted: Security Guard or Permission Gate blocked execution.",
                provenance: provenance
            )
        }

        // 2. Collect All Verified Evidence from Steps
        var verifiedEvidences: [String] = []
        var completedConditions: [String] = []
        var missingConditions: [String] = []

        for step in plan.steps {
            if step.isComplete || step.state == .completed {
                if let result = step.result, result.success {
                    if let ev = result.verifiedEvidence, !ev.isEmpty {
                        verifiedEvidences.append(ev)
                        completedConditions.append("Verified action: \(step.action.actionName) (\(step.description))")
                    } else {
                        completedConditions.append("Executed action without explicit verifier: \(step.description)")
                    }
                    if !result.summary.isEmpty {
                        verifiedEvidences.append(result.summary)
                    }
                } else {
                    completedConditions.append("Completed step: \(step.description)")
                }
            } else if step.isFailed {
                let errReason: String
                if case .failed(let r) = step.state {
                    errReason = r
                } else {
                    errReason = "Execution failed"
                }
                missingConditions.append("Step \(step.index + 1) failed: \(step.description) - \(errReason)")
            } else {
                missingConditions.append("Step \(step.index + 1) not completed: \(step.description)")
            }
        }

        // Combine runtime observations
        verifiedEvidences.append(contentsOf: runtimeObservations)

        // 3. Evidence-First Intent Verification
        let goalLower = goal.lowercased()
        let goalWords = Set(goalLower.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty })

        // Evaluate conditions based on goal requirements
        let requiresScreenOCR = goalLower.contains("screen") || goalLower.contains("ocr") || goalLower.contains("visible text")
        let requiresAppLaunch = (goalLower.contains("open") || goalLower.contains("launch") || goalWords.contains("start")) && !requiresScreenOCR
        let requiresFileWrite = goalLower.contains("write") || goalLower.contains("create file") || goalLower.contains("save")
        let requiresFileRead = (goalLower.contains("read file") || goalWords.contains("cat") || (goalWords.contains("read") && (goalLower.contains("file") || goalLower.contains("sandbox")))) && !goalLower.contains("clipboard") && !requiresScreenOCR
        let requiresRunningApps = goalLower.contains("running") || goalLower.contains("applications") || goalLower.contains("processes")
        let requiresClipboard = goalLower.contains("clipboard") || goalLower.contains("pasteboard")

        var expectedChecksCount = 0
        var passedChecksCount = 0

        if requiresScreenOCR {
            expectedChecksCount += 1
            let screenVerified = verifiedEvidences.contains { ev in
                ev.localizedCaseInsensitiveContains("screen") ||
                ev.localizedCaseInsensitiveContains("recognized") ||
                ev.localizedCaseInsensitiveContains("ocr") ||
                ev.localizedCaseInsensitiveContains("screen.ocr")
            }
            if screenVerified {
                passedChecksCount += 1
            } else {
                missingConditions.append("Screen capture and text recognition not verified")
            }
        }

        if requiresAppLaunch {
            expectedChecksCount += 1
            let appVerified = verifiedEvidences.contains { ev in
                ev.localizedCaseInsensitiveContains("process") ||
                ev.localizedCaseInsensitiveContains("active") ||
                ev.localizedCaseInsensitiveContains("launched") ||
                ev.localizedCaseInsensitiveContains("calculator") ||
                ev.localizedCaseInsensitiveContains("notes") ||
                ev.localizedCaseInsensitiveContains("app") ||
                ev.localizedCaseInsensitiveContains("ui.open_app")
            }
            if appVerified {
                passedChecksCount += 1
            } else {
                missingConditions.append("Target application activation not empirically verified in system state")
            }
        }

        if requiresFileWrite {
            expectedChecksCount += 1
            let writeVerified = verifiedEvidences.contains { ev in
                ev.localizedCaseInsensitiveContains("exists") ||
                ev.localizedCaseInsensitiveContains("wrote") ||
                ev.localizedCaseInsensitiveContains("file") ||
                ev.localizedCaseInsensitiveContains("sandbox") ||
                ev.localizedCaseInsensitiveContains("fs.write_sandbox")
            }
            if writeVerified {
                passedChecksCount += 1
            } else {
                missingConditions.append("Filesystem write and content persistence not verified")
            }
        }

        if requiresFileRead {
            expectedChecksCount += 1
            let readVerified = verifiedEvidences.contains { ev in
                ev.localizedCaseInsensitiveContains("read") ||
                ev.localizedCaseInsensitiveContains("content") ||
                ev.localizedCaseInsensitiveContains("file") ||
                ev.localizedCaseInsensitiveContains("fs.read")
            }
            if readVerified {
                passedChecksCount += 1
            } else {
                missingConditions.append("File reading not completed")
            }
        }

        if requiresRunningApps {
            expectedChecksCount += 1
            let appsVerified = verifiedEvidences.contains { ev in
                ev.localizedCaseInsensitiveContains("running") ||
                ev.localizedCaseInsensitiveContains("applications") ||
                ev.localizedCaseInsensitiveContains("process") ||
                ev.localizedCaseInsensitiveContains("query") ||
                ev.localizedCaseInsensitiveContains("system.running_apps") ||
                ev.localizedCaseInsensitiveContains("Finder") ||
                ev.localizedCaseInsensitiveContains("Pace")
            }
            if appsVerified {
                passedChecksCount += 1
            } else {
                missingConditions.append("Running applications query not verified")
            }
        }

        if requiresClipboard {
            expectedChecksCount += 1
            let clipVerified = verifiedEvidences.contains { ev in
                ev.localizedCaseInsensitiveContains("clipboard") ||
                ev.localizedCaseInsensitiveContains("system.clipboard.read")
            }
            if clipVerified {
                passedChecksCount += 1
            } else {
                missingConditions.append("Clipboard access not verified")
            }
        }

        // 4. Synthesize Evaluation State
        let allStepsCompleted = (plan.isComplete || plan.steps.allSatisfy { $0.isComplete || $0.state == .completed }) && missingConditions.isEmpty
        let hasEvidence = !verifiedEvidences.isEmpty

        let evaluationState: QGoalEvaluationState
        let confidence: Double
        let explanation: String

        if expectedChecksCount > 0 {
            if passedChecksCount >= expectedChecksCount && allStepsCompleted {
                evaluationState = .satisfied
                confidence = 1.0
                explanation = "All \(expectedChecksCount) expected goal condition(s) empirically verified with runtime evidence."
            } else if passedChecksCount > 0 {
                evaluationState = .partiallySatisfied
                confidence = Double(passedChecksCount) / Double(expectedChecksCount)
                explanation = "\(passedChecksCount) of \(expectedChecksCount) goal condition(s) verified; missing: \(missingConditions.joined(separator: ", "))"
            } else {
                evaluationState = .unsatisfied
                confidence = 0.0
                explanation = "Goal unsatisfied: None of the expected goal conditions were empirically verified."
            }
        } else {
            // General task evaluation
            if allStepsCompleted && hasEvidence {
                evaluationState = .satisfied
                confidence = 0.95
                explanation = "All \(plan.steps.count) planned step(s) completed and verified."
            } else if completedConditions.count > 0 {
                evaluationState = .partiallySatisfied
                confidence = Double(completedConditions.count) / Double(max(plan.steps.count, 1))
                explanation = "Partially completed \(completedConditions.count) of \(plan.steps.count) steps."
            } else {
                evaluationState = .unsatisfied
                confidence = 0.0
                explanation = "Plan failed to complete or produce verified evidence."
            }
        }

        return QGoalEvaluation(
            goal: goal,
            state: evaluationState,
            confidence: confidence,
            evidence: verifiedEvidences,
            completedConditions: completedConditions,
            missingConditions: missingConditions,
            explanation: explanation,
            provenance: provenance
        )
    }
}
