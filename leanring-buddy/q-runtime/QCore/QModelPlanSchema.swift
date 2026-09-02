//
//  QModelPlanSchema.swift
//  leanring-buddy
//
//  Q Security Architecture — Structured Local Model Plan Schema & Parser (Phase 2B).
//  Defines the Codable contract for model-generated multi-step plans, enforces schema
//  validation, capability allowlisting, and translates raw model output into authoritative QPlan models.
//

import Foundation

// MARK: - Model Output Schema (Data only, zero authority)

public struct QModelActionSchema: Codable, Sendable, Equatable {
    public let actionName: String
    public let toolFamily: String
    public let riskLevel: String?
    public let description: String
    public let targetResources: [String]?
    public let parameters: [String: String]?

    public init(
        actionName: String,
        toolFamily: String,
        riskLevel: String? = nil,
        description: String,
        targetResources: [String]? = nil,
        parameters: [String: String]? = nil
    ) {
        self.actionName = actionName
        self.toolFamily = toolFamily
        self.riskLevel = riskLevel
        self.description = description
        self.targetResources = targetResources
        self.parameters = parameters
    }
}

public struct QModelPlanSchema: Codable, Sendable, Equatable {
    public let taskPrompt: String?
    public let summary: String?
    public let steps: [QModelActionSchema]

    public init(
        taskPrompt: String? = nil,
        summary: String? = nil,
        steps: [QModelActionSchema]
    ) {
        self.taskPrompt = taskPrompt
        self.summary = summary
        self.steps = steps
    }
}

// MARK: - Parse Errors

public enum QModelPlanParseError: Error, Equatable, Sendable {
    case emptyOutput
    case malformedJSON(String)
    case emptySteps
    case unknownCapability(toolName: String)
    case unauthorizedRiskLevel(toolName: String, risk: String)
    case stepLimitExceeded(count: Int, maxAllowed: Int)
    case missingRequiredField(String)
}

// MARK: - Schema Validator & Parser

public struct QModelPlanParser: Sendable {
    public static let maxAllowedSteps = 10

    /// Allowed tool families and their corresponding registered action names.
    ///
    /// Phase 2E adds the first two controlled mutating capabilities above Level 1:
    /// `system.clipboard.write` (Level 2 — reversible local action; overwrites the pasteboard,
    /// trivially undone by copying something else) and `app.quit` (Level 3 — mutating action
    /// with meaningful user impact; terminates a running application). Both flow through the
    /// same QResourceGuard -> QPermissionGate -> approval -> QPlanExecutor -> QExecutionService
    /// pipeline as every other capability; the model never gains direct execution authority.
    public static let registeredCapabilities: [String: (toolFamily: String, defaultRisk: QCapabilityLevel)] = [
        "system.running_apps": ("system", .level0ReadOnly),
        "system.clipboard.read": ("system", .level0ReadOnly),
        "screen.ocr": ("perception", .level0ReadOnly),
        "ui.open_app": ("app", .level1SafeLocalAction),
        "fs.read": ("fs", .level0ReadOnly),
        "fs.write_sandbox": ("fs", .level1SafeLocalAction),
        "test.noop": ("test", .level0ReadOnly),
        "accessibility.read": ("accessibility", .level0ReadOnly),
        "system.clipboard.write": ("system", .level2UserApproval),
        "app.quit": ("app", .level3HighRisk),
        // Phase 2H: semantic AXUIElement click — Level 2 (reversible local action). The target
        // MUST identify an Accessibility element semantically (role + identifier or title/
        // description); raw screen coordinates are never an accepted parameter for this tool. See
        // QBridgeAccessibility.clickElement and docs/PHASE_2H_SEMANTIC_CLICK.md for the full
        // resolution / observation-binding / verification contract.
        "ui.click_element": ("ui", .level2UserApproval),
        // Phase 2I: semantic AX text-entry write — Level 2 (reversible local action). The target
        // MUST identify an Accessibility element semantically (role + identifier or title) AND
        // the role MUST be on QAXTextEntryRolePolicy's allowlist (AXTextField/AXTextArea only —
        // never AXSecureTextField, never an unrecognized role). The target must already be the
        // system's genuinely focused element; this tool never clicks/focuses a field itself.
        // Mutation is AXUIElementSetAttributeValue(kAXValueAttribute) only — never CGEvent,
        // keyboard simulation, or Return/Tab/submit. Its `value` parameter is declared sensitive
        // in QSensitiveArgumentPolicy — masked before durable persistence and never used to
        // build approval/HUD display text. See QBridgeAccessibility.setTextValue and
        // docs/PHASE_2I_TEXT_ENTRY_SECURITY_REMEDIATION.md for the full contract.
        "ui.set_text_value": ("ui", .level2UserApproval),
        // Phase 2J: semantic AX element value read — Level 0 (read-only, zero mutation). The
        // target MUST identify an Accessibility element semantically (role + identifier or
        // title); the role MUST be on QAXElementReadRolePolicy's fail-closed allowlist
        // (AXSecureTextField is never listed, and is checked first for a distinct diagnostic).
        // Deliberately registered under toolFamily "perception" — NOT "ui" — even though it
        // targets AX rather than pixels: this is what activates QPlanExecutor's existing
        // `isScreenDerivedStep` predicate (`toolFamily == "perception"`), the same
        // sanitize-before-persist / raw-for-reasoning boundary screen.ocr already relies on, with
        // zero changes to QPlanExecutor itself. The read value is INTENTIONALLY exposed to the
        // model (unlike ui.set_text_value's masked `value` input) — that is this capability's
        // entire purpose — so it must never be registered under "ui", which carries no such
        // redaction boundary. See QBridgeAccessibility.readElementValue and
        // docs/PHASE_2J_SEMANTIC_ELEMENT_READ.md.
        "ui.read_element_value": ("perception", .level0ReadOnly),
        // Phase 2K: semantic AX element STATE change — Level 2 (reversible local action). Sets a
        // checkbox/radio-button-shaped element to an explicit desired state ("on"/"off"),
        // restricted to QAXElementStateRolePolicy's fail-closed allowlist (AXCheckBox,
        // AXRadioButton only). Unlike ui.click_element's stateless press, this tool verifies the
        // resulting VALUE (kAXValueAttribute), not just identity — ui.click_element's own
        // QAXElementSnapshot has no value field and would very likely report a false verification
        // failure for a value-bearing control like a checkbox. Idempotent: a target already in
        // the desired state is never pressed. AXRadioButton deselection (desiredState "off" on an
        // already-"on" radio button) is refused — AX press cannot reliably deselect a single
        // radio button, only select a different one in its group — rather than attempting a press
        // that cannot guarantee the requested outcome. Mutation is AXUIElementPerformAction
        // (kAXPressAction) only — the same dispatch primitive ui.click_element already uses —
        // never AXUIElementSetAttributeValue, since many native controls only run their real
        // state-change handling in response to a genuine press, not a raw value write. See
        // QBridgeAccessibility.setElementState and docs/PHASE_2K_SEMANTIC_ELEMENT_STATE.md.
        "ui.set_element_state": ("ui", .level2UserApproval),
        // Phase 2L: semantic menu-bar item selection — Level 2 (reversible local action, same
        // unbounded-consequence-class reasoning as ui.click_element: a menu item's actual effect
        // is arbitrary and app-defined, so per-action human approval — not content filtering — is
        // the safety mechanism). Scoped to EXACTLY one level: a single top-level AXMenuBarItem
        // (matched by `menuBarTitle`) and one direct AXMenuItem within its opened AXMenu (matched
        // by `itemTitle`) — never a nested submenu, never a context/right-click menu, never the
        // Apple menu (a distinct system-wide AX element this tool never queries), never the
        // application's own root menu (explicitly excluded — see
        // QBridgeAccessibility.selectMenuItem's app-root-menu check). No `role` parameter exists:
        // the AXMenuBar → AXMenuBarItem → AXMenu → AXMenuItem hierarchy is fixed by macOS AX
        // convention, not model-supplied. Opening the menu and selecting the item happen
        // atomically within one approved execution (two AXUIElementPerformAction presses, the
        // same dispatch primitive ui.click_element already uses) specifically because two
        // separately-approved ui.click_element presses could not reliably do this: the approval
        // HUD appearing between them is itself a focus-stealing event, and native menus dismiss
        // on focus loss. See QBridgeAccessibility.selectMenuItem and
        // docs/PHASE_2L_SEMANTIC_MENU_SELECTION.md for the full contract, including the bounded
        // menu-open poll and the evidence-based verification model.
        "ui.select_menu_item": ("ui", .level2UserApproval),
        // Phase 2M: semantic AX slider/stepper value change — Level 2 (reversible local action).
        // Sets an AXSlider/AXStepper's numeric value to an explicit `desiredValue`, restricted to
        // QAXSliderRolePolicy's fail-closed allowlist. Mutation is
        // AXUIElementSetAttributeValue(kAXValueAttribute) directly — the same primitive
        // ui.set_text_value already uses, correct here because a slider/stepper's AXValue IS its
        // authoritative state (unlike a checkbox, which needs a real press to run its own
        // handler). `desiredValue` is validated against the target's OWN reported
        // kAXMinValueAttribute/kAXMaxValueAttribute range and refused BEFORE any mutation if
        // outside it — a hard security boundary never widened by the numeric comparison
        // tolerance used elsewhere (idempotency/verification only). Unlike
        // ui.set_text_value, no masking apparatus was needed: desiredValue is a plain, non-
        // sensitive number, not free text, so this tool carries no QSensitiveArgumentPolicy entry
        // and is registered under toolFamily "ui". See QBridgeAccessibility.setSliderValue and
        // docs/PHASE_2M_SEMANTIC_SLIDER_VALUE.md for the full contract, including the exact
        // tolerance rule and the range/value-drift protection.
        "ui.set_slider_value": ("ui", .level2UserApproval),
        // Phase 2N: semantic application activation — Level 1 (safe local action, NOT gated by
        // user approval). Activates one already-running application, matched by an EXACT
        // `localizedName` (never substring/prefix/suffix/fuzzy/case-insensitive), via
        // `NSRunningApplication.activate()` only — never AXUIElement/CGEvent/AppleScript/shell.
        // Deliberately application-level, not window-level: no window title/ID targeting exists.
        // Unlike every Level 2+ UI capability above, this NEVER produces a `QApprovalRequest` —
        // `QPermissionGate.evaluate` already routes Level 0/1 straight to `.allow` by policy, so
        // this is enforced by registering the correct level here, not by a special-cased bypass.
        // Idempotent: an already-frontmost target is a verified no-op, no activation call made.
        // See QExecutionService.executeActivateApplication and
        // docs/PHASE_2N_APPLICATION_ACTIVATION.md for the full contract.
        "ui.activate_application": ("app", .level1SafeLocalAction),
        // Phase 2O: semantic AX element focus — Level 2 (reversible local action, approval
        // required). Requests keyboard focus for a single semantically-identified element via
        // AXUIElementSetAttributeValue(kAXFocusedAttribute) only — never a press, never a value
        // write, never CGEvent/keyboard/mouse simulation. Unlike ui.activate_application's
        // application-level Level 1 classification, focus-setting is element-level AX
        // interaction — the same risk class as every other per-element AX write in this codebase
        // (click/text-entry/state-change/slider/menu-select), so it follows their Level 2
        // precedent rather than ui.activate_application's exception. Restricted to
        // QAXFocusableRolePolicy's narrow fail-closed allowlist (AXButton, AXCheckBox,
        // AXRadioButton, AXTextField, AXTextArea, AXSlider, AXStepper) — the union of every role
        // already proven interactive by an existing write-side policy, plus AXButton.
        // AXSecureTextField, AXStaticText, AXImage, and AXGroup are never allowed. Idempotent:
        // already-focused is a verified no-op, no AX write made. Closes the gap explicitly named
        // (and deliberately deferred) in ui.set_text_value's own contract: that tool "never
        // clicks/focuses a field itself" and requires the target to already be focused. See
        // QBridgeAccessibility.focusElement and docs/PHASE_2O_SEMANTIC_ELEMENT_FOCUS.md.
        "ui.focus_element": ("ui", .level2UserApproval),
        // Phase 2P: semantic popup item selection — Level 2 (reversible local action, approval
        // required). Resolves a single AXPopUpButton (QAXPopupRolePolicy's ONLY allowed role —
        // AXComboBox is deliberately never allowed) and, unless it already shows the desired
        // item, opens it and selects one direct AXMenuItem within its opened AXMenu atomically
        // within one approved execution — the same two-press-atomic-with-bounded-poll mechanism
        // ui.select_menu_item (Phase 2L) already proved works in this codebase, reused verbatim.
        // Unlike a momentary menu-bar command, an AXPopUpButton's kAXValueAttribute is a
        // persistent, already-readable current selection (QAXElementReadRolePolicy has listed
        // AXPopUpButton since Phase 2J) — so both idempotency and closed-loop verification
        // compare the popup's own current value directly against the requested item title, a
        // stronger signal than ui.select_menu_item's indirect "item disappeared" evidence. See
        // QBridgeAccessibility.selectPopupItem and docs/PHASE_2P_SEMANTIC_POPUP_SELECTION.md.
        "ui.select_popup_item": ("ui", .level2UserApproval),
        // Phase 2Q: semantic disclosure triangle toggle — Level 2 (reversible local action,
        // approval required). Requests an explicit desired expand/collapse state ("expanded" or
        // "collapsed" — never a blind toggle whose result is unknown) for exactly one
        // semantically-identified AXDisclosureTriangle, restricted to QAXDisclosureRolePolicy's
        // single-role fail-closed allowlist. Mutation is AXUIElementPerformAction(kAXPressAction)
        // only — the same primitive ui.set_element_state/ui.click_element already use, correct
        // here for the identical reason: a disclosure triangle only runs its real expand/collapse
        // handling in response to a genuine press, not a raw kAXValueAttribute write.
        // Structurally the same interaction shape ui.set_element_state (Phase 2K) already
        // established for checkbox/radio's binary state, applied to a role already
        // read-allowlisted since Phase 2J. Idempotent: already-at-the-desired-state is a
        // verified no-op, no press performed. See QBridgeAccessibility.toggleDisclosure and
        // docs/PHASE_2Q_SEMANTIC_DISCLOSURE_TOGGLE.md for the full contract.
        "ui.toggle_disclosure": ("ui", .level2UserApproval)
    ]

    /// Parses raw model text into a validated QPlan data model.
    public static func parse(
        rawText: String,
        taskId: String,
        taskPrompt: String,
        sessionId: String = "default"
    ) throws -> QPlan {
        let cleanedJSON = extractJSON(from: rawText)
        guard !cleanedJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw QModelPlanParseError.emptyOutput
        }

        guard let data = cleanedJSON.data(using: .utf8) else {
            throw QModelPlanParseError.malformedJSON("Failed to encode cleaned string to UTF-8")
        }

        let schema: QModelPlanSchema
        do {
            schema = try JSONDecoder().decode(QModelPlanSchema.self, from: data)
        } catch {
            throw QModelPlanParseError.malformedJSON("JSON decoding error: \(error.localizedDescription)")
        }

        guard !schema.steps.isEmpty else {
            throw QModelPlanParseError.emptySteps
        }

        guard schema.steps.count <= maxAllowedSteps else {
            throw QModelPlanParseError.stepLimitExceeded(count: schema.steps.count, maxAllowed: maxAllowedSteps)
        }

        var validatedSteps: [QPlanStep] = []

        for (index, actionSchema) in schema.steps.enumerated() {
            guard !actionSchema.actionName.isEmpty else {
                throw QModelPlanParseError.missingRequiredField("step[\(index)].actionName")
            }

            guard let regCap = registeredCapabilities[actionSchema.actionName] else {
                throw QModelPlanParseError.unknownCapability(toolName: actionSchema.actionName)
            }

            // Risk classification is strictly authoritative from the registered capability
            // allowlist — model-declared risk text is untrusted data and is NEVER used to set
            // or downgrade the enforced risk level. A declared value is optional (the common
            // case: trust the registry outright), but if the model DOES declare one, it must
            // exactly match this tool's registered risk level; any mismatch — an unrecognized
            // string, an attempt to claim Level 4, or simply the wrong level for this tool
            // (e.g. claiming Level 0 for a Level 3 tool to try to dodge the approval gate) —
            // is rejected outright rather than silently coerced to the registered value.
            if let declaredRisk = actionSchema.riskLevel {
                guard let parsedDeclaredRisk = QCapabilityLevel.parse(declaredRisk) else {
                    throw QModelPlanParseError.unauthorizedRiskLevel(toolName: actionSchema.actionName, risk: declaredRisk)
                }
                guard parsedDeclaredRisk == regCap.defaultRisk else {
                    throw QModelPlanParseError.unauthorizedRiskLevel(toolName: actionSchema.actionName, risk: declaredRisk)
                }
            }
            let riskLevel = regCap.defaultRisk

            let plannedAction = QPlannedAction(
                actionName: actionSchema.actionName,
                toolFamily: regCap.toolFamily,
                riskLevel: riskLevel,
                literalAction: actionSchema.description,
                targetResources: actionSchema.targetResources ?? [],
                arguments: actionSchema.parameters ?? [:]
            )

            let step = QPlanStep(
                index: index,
                action: plannedAction,
                description: actionSchema.description.isEmpty ? "\(actionSchema.actionName)" : actionSchema.description
            )
            validatedSteps.append(step)
        }

        return QPlan(
            taskId: taskId,
            sessionId: sessionId,
            taskPrompt: taskPrompt,
            steps: validatedSteps
        )
    }

    /// Strips markdown code block wrappers (e.g. ```json ... ```) and extracts raw JSON object
    public static func extractJSON(from text: String) -> String {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.contains("```json") {
            if let startRange = trimmed.range(of: "```json") {
                let afterStart = trimmed[startRange.upperBound...]
                if let endRange = afterStart.range(of: "```") {
                    return String(afterStart[..<endRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        } else if trimmed.contains("```") {
            if let startRange = trimmed.range(of: "```") {
                let afterStart = trimmed[startRange.upperBound...]
                if let endRange = afterStart.range(of: "```") {
                    return String(afterStart[..<endRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }

        // Extract between first { and last }
        if let firstBrace = trimmed.firstIndex(of: "{"),
           let lastBrace = trimmed.lastIndex(of: "}"),
           firstBrace <= lastBrace {
            return String(trimmed[firstBrace...lastBrace])
        }

        return trimmed
    }
}
