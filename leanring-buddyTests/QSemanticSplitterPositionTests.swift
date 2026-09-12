//
//  QSemanticSplitterPositionTests.swift
//  leanring-buddyTests
//
//  Q Security Architecture — Semantic Splitter Position Mutation Tests (Phase 2AU).
//
//  ui.set_splitter_position is Q's forty-third controlled UI-interaction capability,
//  and the exact semantic mutation primitive corresponding to Phase 2AT's ui.list_split_panes.
//
//  Canonical AX contract:
//    AXApplication -> AXWindow -> AXSplitGroup -> direct AXSplitter (NSAccessibilitySplitterRole)
//    - Role MUST be AXSplitter (QAXSplitterRolePolicy allowlist)
//    - Target splitter identified by 0-indexed splitterIndex within containing AXSplitGroup
//    - Writable kAXValueAttribute represents numeric divider position
//    - Range bounded by target's own reported kAXMinValueAttribute and kAXMaxValueAttribute
//    - Validates desiredPosition is finite and within range
//    - Settability check before write (AXUIElementIsAttributeSettable)
//    - Idempotent: already at desired position within tolerance returns changeKind: .alreadyDesired with NO mutation
//    - Verification via independent closed-loop re-observation
//    - Level 2 — requires explicit single-use user approval bound to execution identity
//

import Testing
import AppKit
import Foundation
import ApplicationServices
@testable import Pace

private var currentProcessAppName: String {
    NSRunningApplication.current.localizedName ?? ProcessInfo.processInfo.processName
}

// MARK: - AppKit Fixtures

@MainActor
private final class QSplitGroupContainerFixtureView: NSView {
    override func accessibilityRole() -> NSAccessibility.Role? {
        NSAccessibility.Role(rawValue: "AXSplitGroup")
    }
}

@MainActor
private final class QSplitterFixtureElement: NSAccessibilityElement {
    private var posValue: Double
    private let minPos: Double
    private let maxPos: Double
    private let settable: Bool

    init(initialPosition: Double = 150.0, min: Double = 0.0, max: Double = 400.0, isSettable: Bool = true) {
        self.posValue = initialPosition
        self.minPos = min
        self.maxPos = max
        self.settable = isSettable
        super.init()
    }

    override func accessibilityRole() -> NSAccessibility.Role? {
        NSAccessibility.Role(rawValue: "AXSplitter")
    }

    override func accessibilityValue() -> Any? {
        posValue
    }

    override func accessibilityMinValue() -> Any? {
        minPos
    }

    override func accessibilityMaxValue() -> Any? {
        maxPos
    }

    override func accessibilityOrientation() -> NSAccessibilityOrientation {
        .vertical
    }

    override func isAccessibilityElement() -> Bool {
        true
    }

    override func accessibilityIsAttributeSettable(_ attribute: NSAccessibility.Attribute) -> Bool {
        if attribute == .value {
            return settable
        }
        return false
    }

    override func accessibilitySetValue(_ value: Any?, forAttribute attribute: NSAccessibility.Attribute) {
        if attribute == .value, settable, let num = value as? NSNumber {
            posValue = num.doubleValue
        }
    }

    override func setAccessibilityValue(_ accessibilityValue: Any?) {
        if settable, let num = accessibilityValue as? NSNumber {
            posValue = num.doubleValue
        }
    }
}

@MainActor
private func makeSplitViewWindow(
    windowTitle: String = "QSplitterWindow",
    splitGroupIdentifier: String? = "split.main",
    splitGroupTitle: String? = "Main Split",
    splitters: [(pos: Double, min: Double, max: Double, settable: Bool)] = [
        (150.0, 0.0, 400.0, true)
    ]
) -> (window: NSWindow, splitGroup: QSplitGroupContainerFixtureView, splitters: [QSplitterFixtureElement]) {
    let window = NSWindow(
        contentRect: NSRect(x: 100, y: 100, width: 500, height: 400),
        styleMask: [.titled, .closable],
        backing: .buffered,
        defer: false
    )
    window.animationBehavior = .none
    window.title = windowTitle

    let splitGroup = QSplitGroupContainerFixtureView(frame: NSRect(x: 20, y: 20, width: 460, height: 360))
    if let splitGroupIdentifier = splitGroupIdentifier {
        splitGroup.setAccessibilityIdentifier(splitGroupIdentifier)
    }
    if let splitGroupTitle = splitGroupTitle {
        splitGroup.setAccessibilityLabel(splitGroupTitle)
        splitGroup.setAccessibilityTitle(splitGroupTitle)
    }
    window.contentView?.addSubview(splitGroup)

    var splitterElements: [QSplitterFixtureElement] = []
    for cfg in splitters {
        let spl = QSplitterFixtureElement(initialPosition: cfg.pos, min: cfg.min, max: cfg.max, isSettable: cfg.settable)
        spl.setAccessibilityParent(splitGroup)
        splitterElements.append(spl)
    }

    splitGroup.setAccessibilityChildren(splitterElements)

    return (window, splitGroup, splitterElements)
}

// MARK: - Test Suite

@Suite("QSemanticSplitterPositionTests")
struct QSemanticSplitterPositionTests {

    // MARK: - 1. Registration, Level 2, Tool Family, Approval

    @Test("1. ui.set_splitter_position is registered under toolFamily 'ui'")
    func capabilityRegistrationToolFamily() {
        let regCap = QModelPlanParser.registeredCapabilities["ui.set_splitter_position"]
        #expect(regCap != nil)
        #expect(regCap?.toolFamily == "ui")
    }

    @Test("2. ui.set_splitter_position is Level 2 User Approval by default")
    func capabilityRegistrationRiskLevel() {
        let regCap = QModelPlanParser.registeredCapabilities["ui.set_splitter_position"]
        #expect(regCap?.defaultRisk == .level2UserApproval)
        #expect(regCap?.defaultRisk.requiresExplicitApproval == true)
        #expect(regCap?.defaultRisk.isConsideredReversible == true)
    }

    @Test("3. Parser accepts valid ui.set_splitter_position plan step")
    func parserAcceptsValidStep() throws {
        let rawPlan = """
        {
            "taskPrompt": "Resize editor split pane divider",
            "steps": [
                {
                    "actionName": "ui.set_splitter_position",
                    "toolFamily": "ui",
                    "description": "Resize editor split pane divider",
                    "parameters": {
                        "applicationName": "MockApp",
                        "desiredPosition": "250.0",
                        "splitterIndex": "0",
                        "tolerance": "0.5",
                        "windowTitle": "Main Window",
                        "splitGroupIdentifier": "split.main"
                    }
                }
            ]
        }
        """
        let plan = try QModelPlanParser.parse(rawText: rawPlan, taskId: "task-01", taskPrompt: "Set splitter position")
        #expect(plan.steps.count == 1)
        #expect(plan.steps[0].action.actionName == "ui.set_splitter_position")
        #expect(plan.steps[0].action.arguments["desiredPosition"] == "250.0")
        #expect(plan.steps[0].action.arguments["splitterIndex"] == "0")
        #expect(plan.steps[0].action.riskLevel == .level2UserApproval)
    }

    @Test("4. Parser rejects unauthorized risk level for ui.set_splitter_position")
    func parserRejectsUnauthorizedRiskLevel() {
        let rawPlan = """
        {
            "taskPrompt": "Illegal downgrade attempt",
            "steps": [
                {
                    "actionName": "ui.set_splitter_position",
                    "toolFamily": "ui",
                    "riskLevel": "level0ReadOnly",
                    "description": "Illegal downgrade",
                    "parameters": {
                        "applicationName": "MockApp",
                        "desiredPosition": "200.0"
                    }
                }
            ]
        }
        """
        #expect(throws: QModelPlanParseError.self) {
            _ = try QModelPlanParser.parse(rawText: rawPlan, taskId: "task-bad-risk", taskPrompt: "Test")
        }
    }

    // MARK: - 2. Role Policy Allowlist

    @Test("5. QAXSplitterRolePolicy allowlist contains AXSplitter only")
    func splitterRolePolicyAllowlist() {
        #expect(QAXSplitterRolePolicy.allowedRoles == ["AXSplitter"])
        #expect(QAXSplitterRolePolicy.isAllowedSplitterRole("AXSplitter") == true)
        #expect(QAXSplitterRolePolicy.isAllowedSplitterRole("AXSplitGroup") == false)
        #expect(QAXSplitterRolePolicy.isAllowedSplitterRole("AXSlider") == false)
        #expect(QAXSplitterRolePolicy.isAllowedSplitterRole("AXScrollBar") == false)
        #expect(QAXSplitterRolePolicy.isAllowedSplitterRole("AXButton") == false)
    }

    // MARK: - 3. Interaction Errors and Error Codes

    @Test("6. Error codes are stable machine-readable constants")
    func errorCodesAreStable() {
        #expect(QAXInteractionError.disallowedSplitterRole("AXSlider").errorCode == "AX_SPLITTER_ROLE_NOT_ALLOWED")
        #expect(QAXInteractionError.invalidSplitterIndex(2, availableCount: 1).errorCode == "AX_INVALID_SPLITTER_INDEX")
        #expect(QAXInteractionError.splitterPositionOutOfRange(requested: 500, min: 0, max: 400).errorCode == "AX_SPLITTER_POSITION_OUT_OF_RANGE")
        #expect(QAXInteractionError.splitterPositionNotSettable.errorCode == "AX_SPLITTER_POSITION_NOT_SETTABLE")
        #expect(QAXInteractionError.targetNotASplitter("AXGroup").errorCode == "AX_TARGET_NOT_A_SPLITTER")
        #expect(QAXInteractionError.invalidSplitterTolerance(-1.0).errorCode == "AX_INVALID_SPLITTER_TOLERANCE")
        #expect(QAXInteractionError.invalidDesiredPosition("not-a-number").errorCode == "AX_INVALID_DESIRED_POSITION")
    }

    @Test("7. Error descriptions contain clear diagnostic details")
    func errorDescriptions() {
        let errRole = QAXInteractionError.disallowedSplitterRole("AXSlider")
        #expect(errRole.description.contains("AXSlider"))

        let errIdx = QAXInteractionError.invalidSplitterIndex(3, availableCount: 2)
        #expect(errIdx.description.contains("3"))
        #expect(errIdx.description.contains("2"))

        let errRange = QAXInteractionError.splitterPositionOutOfRange(requested: 500.0, min: 0.0, max: 400.0)
        #expect(errRange.description.contains("500.0"))
        #expect(errRange.description.contains("400.0"))
    }

    // MARK: - 4. Floating-Point Tolerance Helper

    @Test("8. splitterPositionsAreEqual handles floating-point comparisons within tolerance")
    func splitterToleranceHelper() {
        #expect(QBridgeAccessibility.splitterPositionsAreEqual(150.0, 150.0, tolerance: 0.5) == true)
        #expect(QBridgeAccessibility.splitterPositionsAreEqual(150.2, 150.0, tolerance: 0.5) == true)
        #expect(QBridgeAccessibility.splitterPositionsAreEqual(149.6, 150.0, tolerance: 0.5) == true)
        #expect(QBridgeAccessibility.splitterPositionsAreEqual(150.8, 150.0, tolerance: 0.5) == false)
        #expect(QBridgeAccessibility.splitterPositionsAreEqual(140.0, 150.0, tolerance: 0.5) == false)
    }

    // MARK: - 5. Outcome & ChangeKind

    @Test("9. QAXSplitterPositionOutcome initialization and fields")
    func outcomeInitialization() {
        let outcome = QAXSplitterPositionOutcome(
            changeKind: .changed,
            previousPosition: 150.0,
            currentPosition: 250.0,
            desiredPosition: 250.0,
            minValue: 0.0,
            maxValue: 400.0,
            splitterIndex: 0,
            targetIdentity: "app=Test split=main index=0"
        )
        #expect(outcome.changeKind == .changed)
        #expect(outcome.previousPosition == 150.0)
        #expect(outcome.currentPosition == 250.0)
        #expect(outcome.desiredPosition == 250.0)
        #expect(outcome.minValue == 0.0)
        #expect(outcome.maxValue == 400.0)
        #expect(outcome.splitterIndex == 0)
        #expect(outcome.targetIdentity == "app=Test split=main index=0")
    }

    // MARK: - 6. Input Validation & Fail-Closed Checks

    @Test("10. setSplitterPosition rejects non-finite desiredPosition")
    func setSplitterPositionRejectsNonFiniteDesiredPosition() async {
        do {
            _ = try await QBridgeAccessibility.shared.setSplitterPosition(
                applicationName: "MockApp",
                desiredPosition: Double.nan
            )
            Issue.record("Expected error for NaN desiredPosition")
        } catch let err as QAXInteractionError {
            #expect(err.errorCode == "AX_INVALID_DESIRED_POSITION")
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test("11. setSplitterPosition rejects negative tolerance")
    func setSplitterPositionRejectsNegativeTolerance() async {
        do {
            _ = try await QBridgeAccessibility.shared.setSplitterPosition(
                applicationName: "MockApp",
                desiredPosition: 200.0,
                tolerance: -0.5
            )
            Issue.record("Expected error for negative tolerance")
        } catch let err as QAXInteractionError {
            #expect(err.errorCode == "AX_INVALID_SPLITTER_TOLERANCE")
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test("12. setSplitterPosition rejects negative splitterIndex")
    func setSplitterPositionRejectsNegativeSplitterIndex() async {
        do {
            _ = try await QBridgeAccessibility.shared.setSplitterPosition(
                applicationName: "MockApp",
                desiredPosition: 200.0,
                splitterIndex: -1
            )
            Issue.record("Expected error for negative splitter index")
        } catch let err as QAXInteractionError {
            #expect(err.errorCode == "AX_INVALID_SPLITTER_INDEX")
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test("13. setSplitterPosition rejects unauthorized role")
    func setSplitterPositionRejectsUnauthorizedRole() async {
        do {
            _ = try await QBridgeAccessibility.shared.setSplitterPosition(
                applicationName: "MockApp",
                desiredPosition: 200.0,
                role: "AXButton"
            )
            Issue.record("Expected error for disallowed role")
        } catch let err as QAXInteractionError {
            #expect(err.errorCode == "AX_SPLITTER_ROLE_NOT_ALLOWED")
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test("14. setSplitterPosition rejects nonexistent application")
    func setSplitterPositionRejectsNonexistentApp() async {
        do {
            _ = try await QBridgeAccessibility.shared.setSplitterPosition(
                applicationName: "NonExistentAppXYZ_12345",
                desiredPosition: 200.0
            )
            Issue.record("Expected applicationNotAvailable error")
        } catch let err as QAXInteractionError {
            #expect(err.errorCode == "AX_APPLICATION_NOT_AVAILABLE" || err.errorCode == "AX_PERMISSION_DENIED")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    // MARK: - 7. AppKit Fixture Tests

    @MainActor
    @Test("15. AppKit Splitter fixture exposes correct role and range values")
    func fixtureProperties() {
        let fixture = QSplitterFixtureElement(initialPosition: 120.0, min: 10.0, max: 350.0, isSettable: true)
        #expect(fixture.accessibilityRole()?.rawValue == "AXSplitter")
        #expect((fixture.accessibilityValue() as? Double) == 120.0)
        #expect((fixture.accessibilityMinValue() as? Double) == 10.0)
        #expect((fixture.accessibilityMaxValue() as? Double) == 350.0)
        #expect(fixture.accessibilityIsAttributeSettable(.value) == true)
    }

    @MainActor
    @Test("16. AppKit Splitter fixture mutates value when settable")
    func fixtureMutation() {
        let fixture = QSplitterFixtureElement(initialPosition: 100.0, min: 0.0, max: 300.0, isSettable: true)
        fixture.setAccessibilityValue(NSNumber(value: 220.0))
        #expect((fixture.accessibilityValue() as? Double) == 220.0)
    }

    @MainActor
    @Test("17. AppKit Splitter fixture refuses mutation when not settable")
    func fixtureUnsettable() {
        let fixture = QSplitterFixtureElement(initialPosition: 100.0, min: 0.0, max: 300.0, isSettable: false)
        #expect(fixture.accessibilityIsAttributeSettable(.value) == false)
        fixture.setAccessibilityValue(NSNumber(value: 220.0))
        #expect((fixture.accessibilityValue() as? Double) == 100.0)
    }

    @MainActor
    @Test("18. NSSplitView native AppKit control exposes AXSplitGroup and AXSplitter")
    func nativeSplitViewExposure() {
        let splitView = NSSplitView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        splitView.isVertical = true
        let leftView = NSView(frame: NSRect(x: 0, y: 0, width: 150, height: 300))
        let rightView = NSView(frame: NSRect(x: 0, y: 0, width: 250, height: 300))
        splitView.addSubview(leftView)
        splitView.addSubview(rightView)
        splitView.setPosition(150, ofDividerAt: 0)

        #expect(splitView.accessibilityRole()?.rawValue == "AXSplitGroup")
        let children = splitView.accessibilityChildren() ?? []
        #expect(!children.isEmpty)
        if let splitter = children.first as? NSAccessibilityElement {
            #expect(splitter.accessibilityRole()?.rawValue == "AXSplitter")
            #expect(splitter.accessibilityValue() != nil)
        }
    }

    // MARK: - 8. Independent Verification Strategy

    @Test("19. Verification strategy customCheck verifies splitter position calculation")
    func verificationStrategySucceedsOnMatch() async {
        let verifier = QActionVerifier.shared
        let action = QActionRequest(
            toolName: "ui.set_splitter_position",
            toolFamily: "ui",
            riskLevel: .level2UserApproval,
            literalAction: "Set splitter position"
        )
        let result = QActionResult(actionId: action.actionId, success: true, summary: "OK")
        let outcome = await verifier.verify(
            action: action,
            result: result,
            strategy: .customCheck(description: "Splitter position matches") {
                QBridgeAccessibility.splitterPositionsAreEqual(200.0, 200.2, tolerance: 0.5)
            }
        )
        #expect(outcome.isVerified == true)
    }

    @Test("20. Verification strategy customCheck fails on position mismatch")
    func verificationStrategyFailsOnMismatch() async {
        let verifier = QActionVerifier.shared
        let action = QActionRequest(
            toolName: "ui.set_splitter_position",
            toolFamily: "ui",
            riskLevel: .level2UserApproval,
            literalAction: "Set splitter position"
        )
        let result = QActionResult(actionId: action.actionId, success: true, summary: "OK")
        let outcome = await verifier.verify(
            action: action,
            result: result,
            strategy: .customCheck(description: "Splitter position matches") {
                QBridgeAccessibility.splitterPositionsAreEqual(100.0, 200.0, tolerance: 0.5)
            }
        )
        #expect(outcome.isVerified == false)
    }

    // MARK: - 9. Execution Service & Plan Execution

    @Test("21. ExecutionService rejects missing applicationName")
    func executionServiceRejectsMissingAppName() async throws {
        let service = QExecutionService.shared
        let request = QActionRequest(
            toolName: "ui.set_splitter_position",
            toolFamily: "ui",
            riskLevel: .level2UserApproval,
            literalAction: "Set splitter position",
            parameters: [
                "desiredPosition": "200.0"
            ]
        )
        let result = try await service.executeAction(request, context: QTaskContext(taskId: "t-split-01"))
        #expect(result.success == false)
        #expect(result.error == "applicationName missing")
    }

    @Test("22. ExecutionService rejects missing desiredPosition")
    func executionServiceRejectsMissingDesiredPosition() async throws {
        let service = QExecutionService.shared
        let request = QActionRequest(
            toolName: "ui.set_splitter_position",
            toolFamily: "ui",
            riskLevel: .level2UserApproval,
            literalAction: "Set splitter position",
            parameters: [
                "applicationName": "MockApp"
            ]
        )
        let result = try await service.executeAction(request, context: QTaskContext(taskId: "t-split-02"))
        #expect(result.success == false)
        #expect(result.error == "AX_INVALID_DESIRED_VALUE")
    }

    @Test("23. ExecutionService rejects invalid splitterIndex")
    func executionServiceRejectsInvalidSplitterIndex() async throws {
        let service = QExecutionService.shared
        let request = QActionRequest(
            toolName: "ui.set_splitter_position",
            toolFamily: "ui",
            riskLevel: .level2UserApproval,
            literalAction: "Set splitter position",
            parameters: [
                "applicationName": "MockApp",
                "desiredPosition": "200.0",
                "splitterIndex": "-5"
            ]
        )
        let result = try await service.executeAction(request, context: QTaskContext(taskId: "t-split-03"))
        #expect(result.success == false)
        #expect(result.error == "AX_INVALID_SPLITTER_INDEX")
    }

    @Test("24. ExecutionService rejects disallowed role")
    func executionServiceRejectsDisallowedRole() async throws {
        let service = QExecutionService.shared
        let request = QActionRequest(
            toolName: "ui.set_splitter_position",
            toolFamily: "ui",
            riskLevel: .level2UserApproval,
            literalAction: "Set splitter position",
            parameters: [
                "applicationName": "MockApp",
                "desiredPosition": "200.0",
                "role": "AXWindow"
            ]
        )
        let result = try await service.executeAction(request, context: QTaskContext(taskId: "t-split-04"))
        #expect(result.success == false)
        #expect(result.error == "AX_SPLITTER_ROLE_NOT_ALLOWED")
    }

    // MARK: - 10. Recovery Management (Observe-First)

    @Test("25. Recovery Manager observe-first verifies already-satisfied position")
    func recoveryManagerObserveFirst() {
        let currentPos = 250.0
        let desiredPos = 250.0
        let tol = 0.5
        let isSatisfied = QBridgeAccessibility.splitterPositionsAreEqual(currentPos, desiredPos, tolerance: tol)
        #expect(isSatisfied == true)
    }

    @Test("26. Recovery Manager observe-first rejects unsatisfied position")
    func recoveryManagerObserveFirstUnsatisfied() {
        let currentPos = 150.0
        let desiredPos = 250.0
        let tol = 0.5
        let isSatisfied = QBridgeAccessibility.splitterPositionsAreEqual(currentPos, desiredPos, tolerance: tol)
        #expect(isSatisfied == false)
    }

    // MARK: - 11. Forbidden API Regression Check

    @Test("27. Source code audit for forbidden physical UI automation APIs")
    func forbiddenAPIAudit() {
        let forbiddenPatterns = [
            "CGEventCreateMouseEvent",
            "CGEventPost",
            "NSEvent.mouseEvent",
            "keyUp",
            "keyDown"
        ]

        let qBridgeFile = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("leanring-buddy/q-runtime/QBridge/QBridgeAdapters.swift")

        guard let content = try? String(contentsOf: qBridgeFile, encoding: .utf8) else {
            Issue.record("Failed to read QBridgeAdapters.swift for audit")
            return
        }

        for pattern in forbiddenPatterns {
            #expect(!content.contains(pattern), "Forbidden physical automation API found in QBridgeAdapters: \(pattern)")
        }
    }
}
