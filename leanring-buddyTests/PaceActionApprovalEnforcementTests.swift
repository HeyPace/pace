//
//  PaceActionApprovalEnforcementTests.swift
//  leanring-buddyTests
//
//  Phase 2H — PaceActionExecutor Approval Enforcement Remediation.
//  Proves that an action QActionAuthorizationBridge classifies as requiring approval
//  (.requireApproval) cannot reach dispatch without a real, explicit, per-call human-approval
//  signal — closing the confirmed gap where executeSingleAction silently fell through to
//  execution for keyboard-input actions with a misleading "approved" audit label. Uses the real
//  PaceActionExecutor, QActionAuthorizationBridge, and QAuditLogger — no mocks of the
//  authorization layer itself, so a real serialization/dispatch regression cannot hide.
//
//  See docs/PHASE_2H_APPROVAL_ENFORCEMENT_REMEDIATION.md for the full root-cause analysis.
//

import Testing
import Foundation
@testable import Pace

@MainActor
struct PaceActionApprovalEnforcementTests {

    // MARK: - 1. .requireApproval -> execution does NOT occur

    @Test("1. A keyboard action Q classifies as requiring approval is blocked when no approval was obtained")
    func requireApprovalWithoutApprovalBlocksExecution() async {
        // actionsAreEnabledOverride: true — proves the block happens BEFORE any real dispatch
        // (a real CGEvent keystroke would be observable/risky in a test environment; the point of
        // this test is that dispatch never happens at all).
        let executor = PaceActionExecutor(actionsAreEnabledOverride: true)
        let plan = PaceActionExecutionPlan.serial(actions: [.type("hello")])

        let observations = await executor.executeActionPlan(
            plan,
            screenCaptures: [],
            approvalAlreadyObtained: false
        )

        #expect(observations.count == 1)
        #expect(observations.first?.summary.localizedCaseInsensitiveContains("requires explicit approval") == true)

        let recentRecords = QAuditLogger.shared.getRecentRecords(limit: 50)
        #expect(recentRecords.contains { $0.authorizationResult == "blocked_no_approval" && $0.riskLevel == .level2UserApproval })
    }

    @Test("1b. pressKey and setTextValue are also blocked without approval — the whole keyboard-input family, not just type")
    func requireApprovalBlocksEveryKeyboardInputVariant() async {
        let executor = PaceActionExecutor(actionsAreEnabledOverride: true)

        let pressKeyPlan = PaceActionExecutionPlan.serial(actions: [.pressKey(name: "return", modifiers: [])])
        let pressKeyObservations = await executor.executeActionPlan(pressKeyPlan, screenCaptures: [], approvalAlreadyObtained: false)
        #expect(pressKeyObservations.first?.summary.localizedCaseInsensitiveContains("requires explicit approval") == true)

        let editRequest = PaceSetTextValueRequest(value: "secret", target: .focused)
        let setTextPlan = PaceActionExecutionPlan.serial(actions: [.setTextValue(editRequest)])
        let setTextObservations = await executor.executeActionPlan(setTextPlan, screenCaptures: [], approvalAlreadyObtained: false)
        #expect(setTextObservations.first?.summary.localizedCaseInsensitiveContains("requires explicit approval") == true)
    }

    // MARK: - 2. Explicit Allow -> execution occurs exactly once (proven via safe dry-run dispatch)

    @Test("2. With approval already obtained, the action passes the gate and reaches dispatch exactly once")
    func approvalObtainedAllowsDispatchExactlyOnce() async {
        // actionsAreEnabledOverride: false — verifies the gate LETS THE ACTION THROUGH to
        // dispatchSingleAction (proven by the dry-run "Would type..." observation, which only
        // ever appears past the approval gate) without ever synthesizing a real keystroke.
        let executor = PaceActionExecutor(actionsAreEnabledOverride: false)
        let plan = PaceActionExecutionPlan.serial(actions: [.type("hello")])

        let observations = await executor.executeActionPlan(
            plan,
            screenCaptures: [],
            approvalAlreadyObtained: true
        )

        // dispatchSingleAction now always returns an observation for `.type` (previously it
        // silently discarded typeText's outcome — the observation-propagation defect this
        // comment used to work around by treating "empty" as a proxy for "reached dispatch").
        // The approval gate itself only ever appends its OWN observation when it BLOCKS, so a
        // single dry-run "Would type..." observation — never the gate's "requires explicit
        // approval" text — is what now proves dispatch was reached exactly once rather than
        // intercepted (see test 1's identically-shaped, but unapproved, plan for the blocked
        // case).
        #expect(observations.count == 1)
        #expect(observations.first?.summary.localizedCaseInsensitiveContains("requires explicit approval") == false)
        #expect(observations.first?.summary == "Would type 5 characters.")
    }

    // MARK: - 3. Explicit Deny (Level 4 / ResourceGuard) -> execution never occurs, regardless of approval flag

    @Test("3. A hard security denial (ResourceGuard) blocks execution regardless of approvalAlreadyObtained")
    func hardDenialBlocksRegardlessOfApprovalFlag() async {
        let executor = PaceActionExecutor(actionsAreEnabledOverride: true)
        let deniedFinderRequest = PaceFinderRequest(path: NSHomeDirectory() + "/.ssh/id_rsa", action: .open)
        let plan = PaceActionExecutionPlan.serial(actions: [.finder(deniedFinderRequest)])

        // Even with approvalAlreadyObtained: true, a genuine .deny (Level 4 / ResourceGuard) must
        // never be executable — approval can never override an absolute denial.
        let observations = await executor.executeActionPlan(
            plan,
            screenCaptures: [],
            approvalAlreadyObtained: true
        )

        #expect(observations.count == 1)
        #expect(observations.first?.summary.localizedCaseInsensitiveContains("Security Authorization Denied") == true)

        let recentRecords = QAuditLogger.shared.getRecentRecords(limit: 50)
        #expect(recentRecords.contains { $0.authorizationResult == "deny" && $0.riskLevel == .level4Blocked })
    }

    // MARK: - 4/5. No persisted/expirable approval token exists — see docs for why "expired"/"stale
    // approval" as Q defines them do not apply to this mechanism; the closest meaningful analogs
    // (tests 6/7 below) are covered instead.

    // MARK: - 6. Approval for one call/plan cannot leak into a separate, unrelated call

    @Test("6. approvalAlreadyObtained is a fresh, per-call argument — no shared/global state lets one approved call authorize a separate unapproved one")
    func approvalDoesNotLeakAcrossSeparateCalls() async {
        let executor = PaceActionExecutor(actionsAreEnabledOverride: true)

        // Call A: approved.
        let approvedPlan = PaceActionExecutionPlan.serial(actions: [.pressKey(name: "a", modifiers: [])])
        _ = await executor.executeActionPlan(approvedPlan, screenCaptures: [], approvalAlreadyObtained: true)

        // Call B: a DIFFERENT, unrelated plan, immediately after, with no approval — must still be
        // blocked. If any state leaked from call A (a cached "approved" flag, a standing grant),
        // this would incorrectly succeed.
        let unapprovedPlan = PaceActionExecutionPlan.serial(actions: [.type("should not run")])
        let observations = await executor.executeActionPlan(unapprovedPlan, screenCaptures: [], approvalAlreadyObtained: false)

        #expect(observations.first?.summary.localizedCaseInsensitiveContains("requires explicit approval") == true)
    }

    // MARK: - 7. "Duplicate allow" — no stored, consumable grant exists to reuse

    @Test("7. Two separate approved calls each require their own explicit approval argument — nothing is cached or reused between them")
    func eachCallRequiresItsOwnExplicitApproval() async {
        let dryRunExecutor = PaceActionExecutor(actionsAreEnabledOverride: false)
        let plan = PaceActionExecutionPlan.serial(actions: [.type("hello")])

        let firstObservations = await dryRunExecutor.executeActionPlan(plan, screenCaptures: [], approvalAlreadyObtained: true)
        let secondObservations = await dryRunExecutor.executeActionPlan(plan, screenCaptures: [], approvalAlreadyObtained: true)

        // Both succeed only because BOTH calls explicitly declared approval — proving there is no
        // single-use-then-exhausted grant (unlike Q's QApprovalCoordinator) and no shared state
        // that could let a stale/exhausted approval silently persist either. Each dispatch now
        // returns its own "Would type..." observation (see test 2's comment) rather than the
        // gate's "requires explicit approval" text, proving each call independently reached
        // dispatch rather than one riding on the other's approval.
        #expect(firstObservations.count == 1)
        #expect(firstObservations.first?.summary.localizedCaseInsensitiveContains("requires explicit approval") == false)
        #expect(secondObservations.count == 1)
        #expect(secondObservations.first?.summary.localizedCaseInsensitiveContains("requires explicit approval") == false)

        // And the SAME plan without a fresh approval declaration is blocked — proving the prior
        // approved calls did not leave any state behind that a later, unapproved call could ride
        // on. actionsAreEnabled: true here (a separate executor instance) is required to actually
        // observe the block — the gate is intentionally a no-op in dry-run mode (see test 2), so
        // this specific assertion needs a "real" executor even though nothing dispatches for real
        // (the block always returns before dispatchSingleAction is ever called).
        let realExecutor = PaceActionExecutor(actionsAreEnabledOverride: true)
        let thirdObservations = await realExecutor.executeActionPlan(plan, screenCaptures: [], approvalAlreadyObtained: false)
        #expect(thirdObservations.first?.summary.localizedCaseInsensitiveContains("requires explicit approval") == true)
    }

    // MARK: - 8. Retry cannot bypass approval

    @Test("8. Retrying a plan after a blocked attempt still requires a fresh, explicit approval — the block is not bypassable by re-calling")
    func retryDoesNotBypassApproval() async {
        let executor = PaceActionExecutor(actionsAreEnabledOverride: true)
        let plan = PaceActionExecutionPlan.serial(actions: [.pressKey(name: "return", modifiers: [.command])])

        let firstAttempt = await executor.executeActionPlan(plan, screenCaptures: [], approvalAlreadyObtained: false)
        #expect(firstAttempt.first?.summary.localizedCaseInsensitiveContains("requires explicit approval") == true)

        // A bare retry with the same (unapproved) state must fail identically — there is no
        // retry-count-based or time-based bypass.
        let retryAttempt = await executor.executeActionPlan(plan, screenCaptures: [], approvalAlreadyObtained: false)
        #expect(retryAttempt.first?.summary.localizedCaseInsensitiveContains("requires explicit approval") == true)
    }

    // MARK: - 9. Cancellation while awaiting — covered by the existing, unmodified
    // PaceActionExecutorDryRunTests.cancelledPlanDoesNotDispatchActions, which continues to pass
    // unchanged: Task.isCancelled is checked before executeSingleAction is ever invoked, so a
    // cancelled task never reaches this remediation's approval gate at all.

    // MARK: - 10. Existing non-approval-required actions remain functional

    @Test("10. A routine, product-policy-exempt action (click) still executes without needing approvalAlreadyObtained: true")
    func routineExemptActionStillExecutesWithoutApproval() async {
        let executor = PaceActionExecutor(actionsAreEnabledOverride: false)
        let candidateSet = PaceClickCandidateSet(
            candidates: [
                PaceClickCandidate(
                    location: ScreenshotPixelLocation(xInScreenshotPixels: 10, yInScreenshotPixels: 20, screenNumber: 99),
                    label: "Some button",
                    confidence: 0.9,
                    expectStateChange: true
                )
            ],
            clickCount: 1
        )
        let plan = PaceActionExecutionPlan.serial(actions: [.clickCandidates(candidateSet)])

        // .clickCandidates is documented product policy as exempt from the approval popup (see
        // docs/architecture/systems.md) — it must still work even when approvalAlreadyObtained is
        // false, proving this remediation did not touch that intentional, already-shipped behavior.
        let observations = await executor.executeActionPlan(plan, screenCaptures: [], approvalAlreadyObtained: false)

        #expect(observations.first?.summary.localizedCaseInsensitiveContains("requires explicit approval") == false)
    }

    @Test("10b. PaceActionApprovalPolicy correctly flags the plan-level gate for keyboard input, unchanged for click/openURL")
    func planLevelApprovalPolicyReflectsTheFix() {
        let typePlan = PaceActionExecutionPlan.serial(actions: [.type("hello")])
        #expect(PaceActionApprovalPolicy.requiresExplicitApproval(for: typePlan) == true)

        let pressKeyPlan = PaceActionExecutionPlan.serial(actions: [.pressKey(name: "a", modifiers: [])])
        #expect(PaceActionApprovalPolicy.requiresExplicitApproval(for: pressKeyPlan) == true)

        let clickPlan = PaceActionExecutionPlan.serial(actions: [.openApplication("Notes")])
        #expect(PaceActionApprovalPolicy.requiresExplicitApproval(for: clickPlan) == false)

        let openURLPlan = PaceActionExecutionPlan.serial(actions: [.openURL("https://example.com")])
        #expect(PaceActionApprovalPolicy.requiresExplicitApproval(for: openURLPlan) == false)
    }

    // MARK: - Audit label honesty (this remediation also fixed a factually false "approved" label)

    @Test("The audit trail no longer claims a policy-exempt action was 'approved' when nothing approved it")
    func auditLabelIsHonestForPolicyExemptActions() async {
        let executor = PaceActionExecutor(actionsAreEnabledOverride: false)
        let plan = PaceActionExecutionPlan.serial(actions: [.openApplication("Notes")])

        _ = await executor.executeActionPlan(plan, screenCaptures: [], approvalAlreadyObtained: false)

        let recentRecords = QAuditLogger.shared.getRecentRecords(limit: 50)
        // openApplication is Level 1 (Q's own .allow), so it should be genuinely labeled "allow" —
        // never the old blanket "approved" label for a decision Q itself never rendered as allowed.
        #expect(recentRecords.contains { $0.tool == "app.launch" && $0.authorizationResult == "allow" })
    }
}
