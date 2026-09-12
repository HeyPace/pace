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
        "ui.toggle_disclosure": ("ui", .level2UserApproval),
        // Phase 2R: semantic tab selection — Level 2 (reversible local action, approval
        // required). Requests an explicit desired selection state ("true"/"false" —
        // desiredSelected — never a blind toggle) for exactly one semantically-identified tab.
        //
        // IMPORTANT EMPIRICAL FINDING (see docs/PHASE_2R_SEMANTIC_TAB_SELECTION.md's Known
        // limitations for the full account): there is no standalone "AXTab" role anywhere in
        // macOS's Accessibility API — confirmed directly against the AppKit SDK's authoritative
        // NSAccessibilityConstants.h, which lists every NSAccessibilityRole constant Apple has
        // ever defined. A tab item's real, header-confirmed shape is base role AXRadioButton
        // carrying kAXSubroleAttribute == "AXTabButton" (NSAccessibilityTabButtonSubrole).
        // QAXTabRolePolicy therefore allows exactly AXRadioButton, but selectTab additionally,
        // unconditionally requires the AXTabButton subrole before ever treating a resolved
        // element as a tab — a generic AXRadioButton lacking that subrole is refused
        // (targetNotATabButton), never silently accepted. This keeps ui.select_tab from being
        // cross-wired with ui.set_element_state's own, unconditional AXRadioButton coverage: the
        // two capabilities read entirely different attributes for their respective state models
        // (kAXSelectedAttribute here, kAXValueAttribute there).
        //
        // Mutation is AXUIElementPerformAction(kAXPressAction) only — the same primitive
        // ui.toggle_disclosure/ui.set_element_state/ui.click_element already use. Authoritative
        // selection state is read from kAXSelectedAttribute — deliberately never
        // kAXValueAttribute or kAXFocusedAttribute, which represent different semantics
        // entirely. Idempotent: already-at-the-desired-selection-state is a verified no-op, no
        // press performed. A desiredSelected=false request against an already-selected tab is
        // refused (AX provides no reliable single-tab deselection, the same limitation already
        // established for AXRadioButton in Phase 2K). See QBridgeAccessibility.selectTab and
        // docs/PHASE_2R_SEMANTIC_TAB_SELECTION.md for the full contract.
        "ui.select_tab": ("ui", .level2UserApproval),
        // Phase 2S: semantic table row selection — Level 2 (reversible local action, approval
        // required). Requests selection of exactly one semantically-identified table row.
        // Deliberately narrower than every prior explicit-desired-state capability in this
        // codebase: `desiredSelected` MUST be exactly "true" — "false" (deselection) is refused
        // deterministically (`QAXInteractionError.rowDeselectionUnsupported`), never treated as a
        // blind toggle and never silently coerced. Scoped to QAXTableRowRolePolicy's single-role
        // allowlist (`AXRow` only), and `selectTableRow` additionally, unconditionally requires
        // BOTH the `AXTableRow` subrole (`NSAccessibilityTableRowSubrole`, confirmed directly
        // against this SDK's authoritative NSAccessibilityConstants.h — the same header that
        // caught Phase 2R's "AXTab" mistake) AND a resolved parent element whose own role is
        // `AXTable` (`NSAccessibilityTableRole`) — a row lacking either is refused, never treated
        // as a table row. `AXOutlineRow` (`NSAccessibilityOutlineRowSubrole`) is a real, distinct
        // subrole this SDK also defines, but is explicitly OUT OF SCOPE for this phase
        // (`QAXInteractionError.outlineRowUnsupported`) — expanding to outline rows would
        // silently broaden this phase's scope rather than deliberately scoping a future one for
        // it (see docs/PHASE_2S_SEMANTIC_TABLE_ROW_SELECTION.md's Known limitations). Mutation is
        // AXUIElementPerformAction(kAXPressAction) only — the same primitive
        // ui.select_tab/ui.toggle_disclosure/ui.set_element_state/ui.click_element already use.
        // Authoritative selection state is read from kAXSelectedAttribute — the identical
        // attribute already proven correct for ui.select_tab, deliberately never
        // kAXSelectedRowsAttribute (the table-level multi-selection array, never read or written
        // by this single-row capability). Idempotent: already-selected is a verified no-op, no
        // press performed. See QBridgeAccessibility.selectTableRow and
        // docs/PHASE_2S_SEMANTIC_TABLE_ROW_SELECTION.md for the full contract.
        "ui.select_table_row": ("ui", .level2UserApproval),
        // Phase 2T: semantic outline row selection — Level 2 (reversible local action, approval
        // required). Requests selection of exactly one semantically-identified outline row.
        // Deliberately narrower than every prior explicit-desired-state capability in this
        // codebase (mirroring ui.select_table_row exactly): `desiredSelected` MUST be exactly
        // "true" — "false" (deselection) is refused deterministically
        // (`QAXInteractionError.outlineRowDeselectionUnsupported`), never treated as a blind
        // toggle and never silently coerced. Scoped to QAXOutlineRowRolePolicy's single-role
        // allowlist (`AXRow` only — the identical base role table rows use), and
        // `selectOutlineRow` additionally, unconditionally requires BOTH the `AXOutlineRow`
        // subrole (`NSAccessibilityOutlineRowSubrole`, confirmed directly against this SDK's
        // authoritative AXRoleConstants.h) AND a resolved parent element whose own role is
        // `AXOutline` (`NSAccessibilityOutlineRole`) — a row lacking either is refused, never
        // treated as an outline row. `AXTableRow` (the sibling subrole ui.select_table_row owns)
        // is a real, distinct subrole this capability explicitly recognizes and refuses
        // (`QAXInteractionError.tableRowUnsupportedForOutline`) — never silently folded into
        // outline-row handling, exactly mirroring ui.select_table_row's own reciprocal refusal of
        // AXOutlineRow (see docs/PHASE_2S_SEMANTIC_TABLE_ROW_SELECTION.md's Known limitations,
        // where this phase was explicitly deferred). Mutation is
        // AXUIElementPerformAction(kAXPressAction) only — the same primitive
        // ui.select_table_row/ui.select_tab/ui.toggle_disclosure/ui.set_element_state/
        // ui.click_element already use; kAXSelectedAttribute is never written directly. No
        // auto-expand-then-select: a collapsed outline row's descendant is simply not resolvable
        // (not specially detected or expanded), the same "fail closed rather than reach further"
        // discipline every prior capability already establishes. Idempotent: already-selected is
        // a verified no-op, no press performed. See QBridgeAccessibility.selectOutlineRow and
        // docs/PHASE_2T_SEMANTIC_OUTLINE_ROW_SELECTION.md for the full contract.
        "ui.select_outline_row": ("ui", .level2UserApproval),
        // Phase 2U: semantic window minimized-state mutation — Level 2 (reversible local action,
        // approval required). The first WINDOW-level capability in this codebase — every prior
        // capability targets a control inside a window, never the window itself. Scoped to
        // QAXWindowRolePolicy's single-role allowlist (`AXWindow` only). Confirmed directly
        // against this SDK's authoritative AXAttributeConstants.h: `kAXMinimizedAttribute` is
        // documented as "Whether a window is currently minimized to the dock... Writable? Yes." —
        // a directly-settable boolean, the same "attribute IS the authoritative state" reasoning
        // ui.set_slider_value already established for kAXValueAttribute, applied here to
        // kAXMinimizedAttribute instead. Mutation is
        // AXUIElementSetAttributeValue(kAXMinimizedAttribute) only — never
        // AXUIElementPerformAction, never the read-only kAXMinimizeButtonAttribute convenience
        // reference, never kAXRaiseAction (a real, defined action whose Apple header ships with
        // an entirely empty @discussion block — no documented behavior exists for it, so it is
        // never used anywhere in this capability). Unlike every prior row/tab-selection
        // capability, `desiredMinimized` is genuinely bidirectional: BOTH "true" and "false" are
        // fully supported, symmetric, idempotent target states — there is no one-way selection-
        // only restriction here. This capability never activates, focuses, or raises the target
        // application/window as a side effect. Idempotent in either direction: already-at-the-
        // desired-state is a verified no-op, no attribute write performed. See
        // QBridgeAccessibility.setWindowMinimizedState and
        // docs/PHASE_2U_SEMANTIC_WINDOW_MINIMIZED_STATE.md for the full contract.
        "ui.set_window_minimized": ("ui", .level2UserApproval),
        // Phase 2V: semantic application hidden-state mutation — Level 2 (reversible local
        // action, approval required). Sets exactly one already-running application's hidden/
        // visible state to an explicit `desiredHidden` ("true"/"false" — never a blind toggle),
        // resolved by an EXACT `localizedName` match, via `NSRunningApplication.hide()`/
        // `.unhide()` only — never `AXUIElement`, CGEvent, keyboard/mouse simulation,
        // coordinates, AppleScript, or shell automation, and never gated on
        // `AXIsProcessTrusted()`, mirroring `ui.activate_application`'s (Phase 2N) own
        // native-API-over-raw-AX precedent for app-level operations. Deliberately registered
        // under toolFamily "app" — the same family `ui.activate_application`/`app.quit` already
        // use — consistent with every other application-lifecycle operation in this codebase.
        // Unlike `ui.activate_application`'s Level 1 classification, this capability remains
        // Level 2: hiding affects EVERY window of the target application simultaneously, a
        // broader blast radius than a single-window mutation, so it is never downgraded merely
        // because the operation looks visually harmless. Resolution rejects a missing/empty
        // name, fails closed on zero matches, and fails closed on more than one exact match
        // rather than guessing which running instance was intended — identical discipline to
        // `ui.activate_application`'s own resolution. The resolved target's stable
        // `processIdentifier` — never `localizedName`, which a same-named replacement process
        // could otherwise satisfy — is threaded through to the later, independent closed-loop
        // `.applicationHiddenStateMatchesDesired` verification step. Idempotent in BOTH
        // directions: if the resolved target's `isHidden` already equals `desiredHidden`, no
        // `hide()`/`unhide()` call is made at all, and no approval is consumed for a mutation
        // that was never needed. See QExecutionService.executeSetApplicationHidden and
        // docs/PHASE_2V_SEMANTIC_APPLICATION_HIDDEN_STATE.md for the full contract.
        "ui.set_application_hidden": ("app", .level2UserApproval),
        // Phase 2W: semantic scroll position — Level 2 (reversible local action, approval
        // required). Sets the ABSOLUTE numeric position of exactly one semantically-identified
        // scroll bar — never scroll-by-delta, never scroll-to-visible, never scroll-to-text,
        // never scroll-wheel/mouse/keyboard/coordinate simulation. Confirmed directly against
        // this SDK's authoritative AXAttributeConstants.h: `kAXValueAttribute`'s own discussion
        // block explicitly names scroll bars — "a kAXScrollBar's kAXValueAttribute is writable
        // because it allows an efficient way for the user to get to a specific position" — and
        // `kAXMinValueAttribute`/`kAXMaxValueAttribute`'s own discussion blocks explicitly name
        // "sliders and scroll bars" together as their intended use case, the same range-bound
        // pattern `ui.set_slider_value` already established and this capability reuses verbatim
        // (including its exact `sliderValuesAreEqual` tolerance rule) rather than duplicating a
        // subtly different one. The target scroll bar is never searched for directly — raw
        // `AXScrollBar` elements are commonly unlabeled — resolution anchors on the containing
        // `AXScrollArea` (`QAXScrollAreaRolePolicy`'s only allowed role), resolved via the exact
        // same exact-match resolver every prior capability uses, plus an explicit, never-inferred
        // `orientation` parameter ("horizontal"/"vertical"), then follows the documented
        // read-only convenience-reference attribute (`kAXHorizontalScrollBarAttribute`/
        // `kAXVerticalScrollBarAttribute` — resolution only, NEVER mutated) to the actual scroll
        // bar, whose own `kAXRoleAttribute` is independently re-validated as exactly
        // `AXScrollBar` before ever being treated as genuine. Mutation is
        // AXUIElementSetAttributeValue(kAXValueAttribute) only — never
        // kAXIncrementAction/kAXDecrementAction/kAXPressAction. Idempotent: already-at-the-
        // desired-position (within tolerance) is a verified no-op, no attribute write performed.
        // See QBridgeAccessibility.setScrollPosition and
        // docs/PHASE_2W_SEMANTIC_SCROLL_POSITION.md for the full contract.
        "ui.set_scroll_position": ("ui", .level2UserApproval),
        // Phase 2X: semantic window main designation — Level 2 (reversible local action,
        // approval required). Designates exactly one semantically-identified window as its
        // application's main document window — SELECT-ONLY (`desiredMain` MUST be exactly
        // "true"; "false" is refused deterministically, by direct analogy to ui.select_tab's own
        // finding that AX provides no reliable way to deselect/un-main a single item without
        // designating a replacement). Confirmed directly against this SDK's authoritative
        // AXAttributeConstants.h: `kAXMainAttribute` is documented "Whether a window is the main
        // document window of an application... Main does not necessarily imply that the window
        // has key focus... Writable? Yes." — a directly-settable boolean, the same
        // "attribute IS the authoritative state" reasoning ui.set_window_minimized already
        // established for kAXMinimizedAttribute. Reuses QAXWindowRolePolicy (Phase 2U)
        // unmodified — the identical single-role allowlist (AXWindow only). Mutation is
        // AXUIElementSetAttributeValue(kAXMainAttribute) only — never kAXRaiseAction, never
        // kAXFocusedAttribute, never NSRunningApplication.activate(), never any window-ordering
        // call of any kind; this capability makes NO claim about activation, focus, raise, or any
        // visual/ordering effect — it reads and writes kAXMainAttribute alone. Never enumerates
        // or mutates any window other than the exact resolved target — exclusivity among windows
        // is owned entirely by the OS/application, never enforced agent-side. Idempotent:
        // already-main is a verified no-op, no attribute write performed. See
        // QBridgeAccessibility.setWindowMain and
        // docs/PHASE_2X_SEMANTIC_WINDOW_MAIN_DESIGNATION.md for the full contract.
        "ui.set_window_main": ("ui", .level2UserApproval),
        // Phase 2Y: semantic window close — LEVEL 3 (HIGH RISK). Closes exactly ONE
        // semantically-identified AXWindow by pressing its kAXCloseButtonAttribute-referenced
        // close button (AXUIElementPerformAction(kAXPressAction)) — a genuinely ONE-WAY action,
        // unlike every other window-level capability in this codebase (minimize/hide/main are all
        // trivially reversible boolean-attribute writes). Classified Level 3 — the same tier as
        // app.quit, whose blast radius this strictly narrows (one window, never the whole
        // application) but whose irreversibility risk (potential data loss if the target
        // application does not autosave) is comparably real; deliberately NOT downgraded to
        // Level 2. This capability NEVER interacts with any save/discard sheet the press may
        // cause to appear — it performs the single press and stops; any resulting dialog is left
        // entirely to the human user. Verification is absence-based (a first for this codebase):
        // success requires BOTH that the owning application is independently confirmed still
        // running AND that the exact original window identity no longer resolves — application
        // termination is never credited as a successful window close. Idempotent: if the exact
        // target is already unresolvable at resolution time (with the application confirmed
        // running), that is treated as an already-satisfied no-op; an ambiguous, inaccessible, or
        // permission-denied resolution is NEVER folded into "absent." Reuses QAXWindowRolePolicy
        // (Phase 2U) unmodified for the window search criterion; the close-button convenience
        // reference's own role is independently re-validated as exactly AXButton before ever
        // being pressed, by direct analogy to ui.set_scroll_position's targetNotAScrollBar check.
        // Never enumerates or closes any window other than the exact resolved target; never calls
        // NSRunningApplication.terminate() or any application-quit path. See
        // QBridgeAccessibility.closeWindow and docs/PHASE_2Y_SEMANTIC_WINDOW_CLOSE.md for the
        // full contract.
        "ui.close_window": ("ui", .level3HighRisk),
        // Phase 2Z: semantic window enumeration — LEVEL 0 (READ-ONLY). Enumerates the windows
        // belonging to exactly ONE named, running application via kAXWindowsAttribute — a direct
        // child read only, never a recursive descent into any returned window's own descendants.
        // No mutation, no approval, no recovery: matches the classification and architectural
        // footprint of every other Level 0 capability in this table (system.running_apps,
        // ui.read_element_value, accessibility.read) exactly — none of which have a dedicated
        // QPlanExecutor verification-strategy branch or QTaskRecoveryManager recovery branch,
        // since a read that does not throw IS its own result. Application identity is resolved by
        // EXACT localizedName/bundleIdentifier match; more than one running process matching the
        // same name is ambiguous and fails closed (reuses the generic
        // QAXInteractionError.ambiguousTarget case). Only elements whose own kAXRoleAttribute
        // reports exactly AXWindow are included; every other metadata field
        // (title/identifier/minimized/main) is independently optional — a missing one is never an
        // error and never excludes the window. The raw returned collection's size is checked
        // against a defensive maximum (QBridgeAccessibility.maxWindowEnumerationCount) before any
        // per-element read, even though a real application's window count is always naturally
        // small. Array ordering is NEVER treated as meaningful — no frontmost/z-order/main-window
        // inference is ever drawn from position. This is a POINT-IN-TIME SNAPSHOT ONLY: the
        // result is never itself an actionable target reference, and is deliberately never
        // threaded into durable persistence (QDurablePlanStepSnapshot has no outputData field at
        // all — confirmed by direct source inspection — so the structured per-window list this
        // capability returns structurally cannot reach disk; QActionResult.summary is
        // deliberately kept to an aggregate count only, never embedding individual window titles,
        // so the one string field that DOES cross into durable resultSummary/verifiedEvidence/
        // audit-log persistence stays free of per-window content on this capability's own side of
        // that boundary too). Every subsequent mutation capability (ui.set_window_minimized,
        // ui.set_window_main, ui.close_window, etc.) must independently perform its own fresh,
        // exact target resolution — this capability's output is never consulted as, or cached as,
        // execution authorization for anything. See QBridgeAccessibility.listWindows and
        // docs/PHASE_2Z_SEMANTIC_WINDOW_ENUMERATION.md for the full contract.
        "ui.list_windows": ("ui", .level0ReadOnly),
        // Phase 2AA: semantic menu enumeration — LEVEL 0 (READ-ONLY). Enumerates top-level menus
        // and direct menu items belonging to exactly ONE named, running application via
        // kAXMenuBarAttribute — direct items only, never a recursive descent into submenus or arbitrary
        // descendants. No mutation, no approval, no recovery: matches the classification and
        // footprint of ui.list_windows (Phase 2Z). Application identity is resolved by EXACT
        // localizedName/bundleIdentifier match; more than one running process matching the same name
        // is ambiguous and fails closed. Validates expected AX roles (AXMenuBar, AXMenuBarItem/AXMenu,
        // AXMenuItem). Bounded by local defensive ceilings (maxTopLevelMenuCount,
        // maxDirectMenuItemsPerMenuCount, maxTotalMenuItemsCount). Array ordering is NEVER treated as
        // meaningful or as authorization. This is a POINT-IN-TIME SNAPSHOT ONLY: result is informational
        // and never enters durable persistence snapshots; every subsequent mutation capability
        // (ui.select_menu_item) must independently perform its own fresh, exact target resolution.
        "ui.list_menu_items": ("ui", .level0ReadOnly),
        // Phase 2AD: semantic pop-up menu item enumeration — LEVEL 0 (READ-ONLY). Enumerates direct
        // menu items belonging to exactly ONE named AXPopUpButton in an application via direct AXMenu
        // children. No mutation, no press, no open, no approval, no recovery. Application identity is
        // resolved by exact matching via QBridgeAccessibility.resolveExactRunningApplication. Target
        // must match AXPopUpButton role policy. Bounded by local defensive ceiling
        // (maxDirectPopupItemsCount = 128). This is a POINT-IN-TIME SNAPSHOT ONLY: result is informational
        // and never enters durable persistence snapshots; every subsequent mutation capability
        // (ui.select_popup_item) must independently perform its own fresh, exact target resolution.
        "ui.list_popup_items": ("ui", .level0ReadOnly),
        // Phase 2AE: semantic table row enumeration — LEVEL 0 (READ-ONLY). Enumerates direct
        // table rows belonging to exactly ONE named AXTable in an application via direct AXRow/AXTableRow
        // children. No mutation, no press, no approval, no recovery. Application identity is
        // resolved by exact matching via QBridgeAccessibility.resolveExactRunningApplication. Target
        // must match AXTable role policy. Bounded by local defensive ceiling
        // (maxDirectTableRowsCount = 128). This is a POINT-IN-TIME SNAPSHOT ONLY: result is informational
        // and never enters durable persistence snapshots; every subsequent mutation capability
        // (ui.select_table_row) must independently perform its own fresh, exact target resolution.
        "ui.list_table_rows": ("ui", .level0ReadOnly),
        // Phase 2AF: semantic outline item enumeration — LEVEL 0 (READ-ONLY). Enumerates direct
        // outline rows belonging to exactly ONE named AXOutline in an application via direct AXRow/AXOutlineRow
        // children. No mutation, no press, no open, no approval, no recovery. Application identity is
        // resolved by exact matching via QBridgeAccessibility.resolveExactRunningApplication. Target
        // must match AXOutline role policy. Bounded by local defensive ceiling
        // (maxDirectOutlineItemsCount = 128, maxOutlineDepth = 12). This is a POINT-IN-TIME SNAPSHOT ONLY:
        // result is informational and never enters durable persistence snapshots; every subsequent mutation
        // capability (ui.select_outline_row) must independently perform its own fresh, exact target resolution.
        "ui.list_outline_items": ("ui", .level0ReadOnly),
        // Phase 2AH: semantic tab item enumeration — LEVEL 0 (READ-ONLY). Enumerates direct
        // tab items belonging to exactly ONE named AXTabGroup in an application via direct AXRadioButton/AXTabButton
        // children. No mutation, no press, no focus, no approval, no recovery. Application identity is
        // resolved by exact matching via QBridgeAccessibility.resolveExactRunningApplication. Target
        // must match AXTabGroup role policy. Bounded by local defensive ceiling
        // (maxDirectTabItemsCount = 64). This is a POINT-IN-TIME SNAPSHOT ONLY:
        // result is informational and never enters durable persistence snapshots; every subsequent mutation
        // capability (ui.select_tab) must independently perform its own fresh, exact target resolution.
        "ui.list_tab_items": ("ui", .level0ReadOnly),
        // Phase 2AI: semantic radio group item enumeration — LEVEL 0 (READ-ONLY). Enumerates direct
        // radio button options belonging to exactly ONE named AXRadioGroup in an application via direct AXRadioButton
        // children (excluding AXTabButton subroles). No mutation, no press, no focus, no approval, no recovery.
        // Application identity is resolved by exact matching via QBridgeAccessibility.resolveExactRunningApplication.
        // Target must match AXRadioGroup role policy. Bounded by local defensive ceiling
        // (maxDirectRadioItemsCount = 64). This is a POINT-IN-TIME SNAPSHOT ONLY:
        // result is informational and never enters durable persistence snapshots; every subsequent mutation
        // capability (ui.set_element_state) must independently perform its own fresh, exact target resolution.
        "ui.list_radio_group_items": ("ui", .level0ReadOnly),
        // Phase 2AK: semantic toolbar item enumeration — LEVEL 0 (READ-ONLY). Enumerates direct
        // interactive controls belonging to exactly ONE named AXToolbar in an application window via direct
        // children. No mutation, no press, no focus, no approval, no recovery.
        // Application identity is resolved by exact matching via QBridgeAccessibility.resolveExactRunningApplication.
        // Target must match AXToolbar role policy. Bounded by local defensive ceiling
        // (maxDirectToolbarItemsCount = 64). This is a POINT-IN-TIME SNAPSHOT ONLY:
        // result is informational and never enters durable persistence snapshots; every subsequent mutation
        // capability (ui.click_element, ui.select_popup_item) must independently perform its own fresh, exact target resolution.
        "ui.list_toolbar_items": ("ui", .level0ReadOnly),
        // Phase 2AM: semantic segmented control item enumeration — LEVEL 0 (READ-ONLY). Enumerates direct
        // segment options belonging to exactly ONE named AXSegmentedControl in an application window via direct
        // children. No mutation, no press, no focus, no approval, no recovery.
        // Application identity is resolved by exact matching via QBridgeAccessibility.resolveExactRunningApplication.
        // Target must match AXSegmentedControl canonical role policy (AXRadioGroup is strictly excluded). Bounded by local defensive ceiling
        // (maxDirectSegmentsCount = 32). This is a POINT-IN-TIME SNAPSHOT ONLY:
        // result is informational and never enters durable persistence snapshots; every subsequent mutation
        // capability must independently perform its own fresh, exact target resolution.
        "ui.list_segmented_control_items": ("ui", .level0ReadOnly),
        // Phase 2AN: semantic sheet dialog enumeration — LEVEL 0 (READ-ONLY). Enumerates direct
        // AXSheet elements attached to exactly ONE named AXWindow in an application via kAXSheetsAttribute
        // and direct children. No mutation, no press, no focus, no approval, no recovery.
        // Application identity is resolved by exact matching via QBridgeAccessibility.resolveExactRunningApplication.
        // Target must match AXSheet canonical role policy (AXDialog is strictly excluded). Bounded by local defensive ceiling
        // (maxDirectSheetsCount = 16). This is a POINT-IN-TIME SNAPSHOT ONLY:
        // result is informational and never enters durable persistence snapshots; every subsequent mutation
        // capability must independently perform its own fresh, exact target resolution.
        "ui.list_sheet_dialogs": ("ui", .level0ReadOnly),
        // Phase 2AO: semantic sheet action enumeration — LEVEL 0 (READ-ONLY). Enumerates direct
        // action controls (AXButton, AXCheckBox, AXRadioButton, AXPopUpButton) belonging to exactly
        // ONE named AXSheet in an application window. No mutation, no press, no focus, no approval, no recovery.
        // Application identity is resolved by exact matching via QBridgeAccessibility.resolveExactRunningApplication.
        // Direct child controls only (descendant trees inside groups/menus are strictly excluded). Bounded by local defensive ceiling
        // (maxDirectSheetActionsCount = 16). This is a POINT-IN-TIME SNAPSHOT ONLY:
        // result is informational and never enters durable persistence snapshots; every subsequent mutation
        // capability must independently perform its own fresh, exact target resolution.
        "ui.list_sheet_actions": ("ui", .level0ReadOnly),
        // Phase 2AQ: semantic segmented control item selection — LEVEL 2 (REVERSIBLE, APPROVAL REQUIRED).
        // Selects exactly one direct segment item belonging to an exact AXSegmentedControl in a named application window.
        // Direct segment roles: AXRadioButton or AXButton (AXTabButton is strictly excluded). Deselection is unsupported.
        // Idempotent (already desired selection is a no-op). Protected by stale-target & drift checks,
        // and verified via closed-loop observation. Requires explicit single-use approval.
        "ui.select_segmented_control_item": ("ui", .level2UserApproval),
        // Phase 2AS: semantic window full-screen state mutation — Level 2 (reversible local action,
        // approval required). Sets exactly one semantically-identified AXWindow's full-screen state
        // to an explicit desiredFullScreen ("true"/"false" — never a blind toggle), resolved via
        // QBridgeAccessibility.resolveExactRunningApplication and exact window matching. Scoped to
        // QAXWindowRolePolicy's single-role allowlist (AXWindow only). Confirmed against macOS AX
        // API: kAXFullScreenAttribute ("AXFullScreen") is an authoritative boolean attribute on
        // AXWindow elements. Mutation is AXUIElementSetAttributeValue(kAXFullScreenAttribute)
        // only — never NSWindow.toggleFullScreen(), never green traffic-light coordinate clicks,
        // never Cmd+Ctrl+F shortcuts, never CGEvent/mouse/keyboard simulation. Validates that the
        // attribute is settable/writable before mutation. Symmetrically supports both directions
        // (true -> false and false -> true). Idempotent: already-at-the-desired-state is a
        // verified no-op, no AX write performed. Protected by stale-target & drift checks, and
        // verified via closed-loop observation. Requires explicit single-use approval.
        "ui.set_window_full_screen": ("ui", .level2UserApproval),
        // Phase 2AT: semantic split view pane enumeration — LEVEL 0 (READ-ONLY). Enumerates direct
        // panes belonging to exactly ONE named AXSplitGroup in an application window via direct
        // children, excluding AXSplitter divider elements between panes. No mutation, no press,
        // no focus, no approval, no recovery.
        // Application identity is resolved by exact matching via QBridgeAccessibility.resolveExactRunningApplication.
        // Target must match AXSplitGroup canonical role policy. Bounded by local defensive ceiling
        // (maxDirectSplitPanesCount = 16). This is a POINT-IN-TIME SNAPSHOT ONLY:
        // result is informational and never enters durable persistence snapshots; every subsequent mutation
        // capability must independently perform its own fresh, exact target resolution.
        "ui.list_split_panes": ("ui", .level0ReadOnly),
        // Phase 2AU: semantic split view divider position mutation — LEVEL 2 (REVERSIBLE, APPROVAL REQUIRED).
        // Sets the numeric divider position of exactly ONE semantically-identified AXSplitter within an AXSplitGroup
        // in a named application window via AXUIElementSetAttributeValue(kAXValueAttribute) only — never mouse dragging,
        // coordinate simulation, CGEvent, or physical input. Target splitter is resolved via application name, optional
        // window scoping, optional split group scoping, and 0-indexed splitterIndex (default 0). Validates that the
        // desiredPosition is a finite Double within the splitter's own reported kAXMinValueAttribute / kAXMaxValueAttribute range.
        // Validates that the attribute is settable before mutation. Idempotent: if current position already matches desiredPosition
        // within tolerance (abs(current - desired) <= tolerance), returns success immediately as a verified no-op.
        // Protected by stale-target & drift checks, and verified via independent closed-loop observation of fresh kAXValueAttribute.
        // Requires explicit single-use approval bound to QExecutionIdentity.
        "ui.set_splitter_position": ("ui", .level2UserApproval),
        // Phase 2AV: semantic multi-column browser enumeration — LEVEL 0 (READ-ONLY). Enumerates direct
        // columns belonging to exactly ONE named AXBrowser in an application window via direct
        // children (kAXColumnsAttribute or AXColumn children). No mutation, no press, no focus, no approval, no recovery.
        // Application identity is resolved by exact matching via QBridgeAccessibility.resolveExactRunningApplication.
        // Target must match AXBrowser canonical role policy. Bounded by local defensive ceiling
        // (maxDirectBrowserColumnsCount = 32). This is a POINT-IN-TIME SNAPSHOT ONLY:
        // result is informational and never enters durable persistence snapshots; every subsequent mutation
        // capability must independently perform its own fresh, exact target resolution.
        "ui.list_browser_columns": ("ui", .level0ReadOnly),
        // Phase 2AW: semantic popover container enumeration — LEVEL 0 (READ-ONLY). Enumerates direct
        // AXPopover elements belonging to an application window or application root in a named application.
        // No mutation, no press, no focus, no approval, no recovery.
        // Application identity is resolved by exact matching via QBridgeAccessibility.resolveExactRunningApplication.
        // Target must match AXPopover canonical role policy. Bounded by local defensive ceiling
        // (maxDirectPopoversCount = 16). This is a POINT-IN-TIME SNAPSHOT ONLY:
        // result is informational and never enters durable persistence snapshots; every subsequent mutation
        // capability must independently perform its own fresh, exact target resolution.
        "ui.list_popovers": ("ui", .level0ReadOnly),
        // Phase 2AX: semantic color well enumeration — LEVEL 0 (READ-ONLY). Enumerates direct
        // AXColorWell elements belonging to an application window or view hierarchy in a named application.
        // No mutation, no press, no focus, no approval, no recovery.
        // Application identity is resolved by exact matching via QBridgeAccessibility.resolveExactRunningApplication.
        // Target must match AXColorWell canonical role policy. Bounded by local defensive ceiling
        // (maxDirectColorWellsCount = 32). This is a POINT-IN-TIME SNAPSHOT ONLY:
        // result is informational and never enters durable persistence snapshots; every subsequent mutation
        // capability must independently perform its own fresh, exact target resolution.
        "ui.list_color_wells": ("ui", .level0ReadOnly),
        // Phase 2AY: semantic progress indicator enumeration — LEVEL 0 (READ-ONLY). Enumerates direct
        // AXProgressIndicator and AXBusyIndicator elements belonging to an application window or view hierarchy.
        // No mutation, no press, no focus, no approval, no recovery.
        // Application identity is resolved by exact matching via QBridgeAccessibility.resolveExactRunningApplication.
        // Target must match AXProgressIndicator/AXBusyIndicator canonical role policy. Bounded by local defensive ceiling
        // (maxDirectProgressIndicatorsCount = 32). This is a POINT-IN-TIME SNAPSHOT ONLY:
        // result is informational and never enters durable persistence snapshots; every subsequent mutation
        // capability must independently perform its own fresh, exact target resolution.
        "ui.list_progress_indicators": ("ui", .level0ReadOnly),
        // Phase 2AZ: semantic level indicator enumeration — LEVEL 0 (READ-ONLY). Enumerates direct
        // AXLevelIndicator and AXRelevanceIndicator elements belonging to an application window or view hierarchy.
        // No mutation, no press, no focus, no approval, no recovery.
        // Application identity is resolved by exact matching via QBridgeAccessibility.resolveExactRunningApplication.
        // Target must match AXLevelIndicator/AXRelevanceIndicator canonical role policy. Bounded by local defensive ceiling
        // (maxDirectLevelIndicatorsCount = 32). This is a POINT-IN-TIME SNAPSHOT ONLY:
        // result is informational and never enters durable persistence snapshots; every subsequent mutation
        // capability must independently perform its own fresh, exact target resolution.
        "ui.list_level_indicators": ("ui", .level0ReadOnly),
        // Phase 2BA: semantic stepper / incrementor enumeration — LEVEL 0 (READ-ONLY). Enumerates direct
        // AXIncrementor elements belonging to an application window or view hierarchy.
        // No mutation, no press, no focus, no approval, no recovery.
        // Application identity is resolved by exact matching via QBridgeAccessibility.resolveExactRunningApplication.
        // Target must match AXIncrementor canonical role policy. Bounded by local defensive ceiling
        // (maxDirectIncrementorsCount = 32). This is a POINT-IN-TIME SNAPSHOT ONLY:
        // result is informational and never enters durable persistence snapshots; every subsequent mutation
        // capability must independently perform its own fresh, exact target resolution.
        "ui.list_incrementors": ("ui", .level0ReadOnly),
        // Phase 2BB: semantic combo box enumeration — LEVEL 0 (READ-ONLY). Enumerates direct
        // AXComboBox elements belonging to an application window or view hierarchy.
        // No mutation, no selection change, no text entry, no approval, no recovery.
        // Application identity is resolved by exact matching via QBridgeAccessibility.resolveExactRunningApplication.
        // Target must match AXComboBox canonical role policy. Bounded by local defensive ceiling
        // (maxDirectComboBoxesCount = 32). This is a POINT-IN-TIME SNAPSHOT ONLY:
        // result is informational and never enters durable persistence snapshots; every subsequent mutation
        // capability must independently perform its own fresh, exact target resolution.
        "ui.list_combo_boxes": ("ui", .level0ReadOnly),
        // Phase 2BC: semantic ruler enumeration — LEVEL 0 (READ-ONLY). Enumerates direct
        // AXRuler elements belonging to an application window or view hierarchy.
        // No mutation, no marker repositioning, no approval, no recovery.
        // Application identity is resolved by exact matching via QBridgeAccessibility.resolveExactRunningApplication.
        // Target must match AXRuler canonical role policy. Bounded by local defensive ceiling
        // (maxDirectRulersCount = 32). This is a POINT-IN-TIME SNAPSHOT ONLY:
        // result is informational and never enters durable persistence snapshots; every subsequent mutation
        // capability must independently perform its own fresh, exact target resolution.
        "ui.list_rulers": ("ui", .level0ReadOnly),
        // Phase 2BD: semantic combo box item enumeration — LEVEL 0 (READ-ONLY). Enumerates child items
        // belonging to exactly ONE named AXComboBox in an application.
        // No mutation, no selection change, no text entry, no approval, no recovery.
        // Application identity is resolved by exact matching via QBridgeAccessibility.resolveExactRunningApplication.
        // Target must match AXComboBox canonical role policy. Bounded by local defensive ceiling
        // (maxDirectComboBoxItemsCount = 128). This is a POINT-IN-TIME SNAPSHOT ONLY:
        // result is informational and never enters durable persistence snapshots; every subsequent mutation
        // capability must independently perform its own fresh, exact target resolution.
        "ui.list_combo_box_items": ("ui", .level0ReadOnly),
        // Phase 2BE: semantic combo box item selection — LEVEL 2 (USER APPROVAL REQUIRED).
        // Selects an item within exactly ONE named AXComboBox in an application window via semantic AX mutation.
        // Mutates value via native AX attribute (kAXValueAttribute). Requires explicit user approval.
        // Application identity is resolved by exact matching via QBridgeAccessibility.resolveExactRunningApplication.
        // Target must match AXComboBox canonical role policy. Idempotent: returns safe no-op if already selected.
        // Verified by independent post-mutation re-read.
        "ui.select_combo_box_item": ("ui", .level2UserApproval),
        // Phase 2BF: semantic stepper / incrementor step mutation — LEVEL 2 (USER APPROVAL REQUIRED).
        // Increments or decrements exactly ONE named AXIncrementor in an application window via native
        // AXUIElementPerformAction(kAXIncrementAction) / AXUIElementPerformAction(kAXDecrementAction) —
        // the purpose-built AX actions for this role (confirmed against AXActionConstants.h). Never
        // AXUIElementSetAttributeValue(kAXValueAttribute) directly — see QBridgeAccessibility.stepIncrementor.
        // Application identity is resolved by exact matching via QBridgeAccessibility.resolveExactRunningApplication.
        // Target must match AXIncrementor canonical role policy (QAXIncrementorRolePolicy, reused unmodified
        // from Phase 2BA). direction ("increment"/"decrement") is required and explicit — never a blind toggle.
        // steps is bounded to [1, 20] per call. Idempotent: already-at-bound (per kAXMinValueAttribute/
        // kAXMaxValueAttribute) in the requested direction is a verified no-op, no AX action performed.
        // Verified by independent post-mutation re-read of kAXValueAttribute.
        "ui.step_incrementor": ("ui", .level2UserApproval),
        // Phase 2BG: semantic focused-element read — LEVEL 0 (READ-ONLY). Reads the systemwide
        // currently-focused Accessibility element via kAXFocusedUIElementAttribute on
        // AXUIElementCreateSystemWide() — zero tree traversal, exactly one element ever touched,
        // and the first capability requiring NO prior knowledge of a target's identifier/title/
        // role: every other capability in this codebase requires the model to already know that
        // before it can act or read. Application identity is resolved by exact matching via
        // QBridgeAccessibility.resolveExactRunningApplication; the focused element's owning
        // process (AXUIElementGetPid) is independently cross-checked against the resolved
        // application and fails closed on any mismatch — the systemwide focused element itself is
        // never treated as an arbitrary, unscoped target. Optional windowTitle further scopes/
        // verifies against the focused element's own kAXWindowAttribute. Reuses
        // QAXElementReadRolePolicy (Phase 2J) unmodified: identity/structural metadata (role,
        // subrole, identifier, title, description, enabled, selected) is always returned when a
        // focused element resolves; only the optional value field is policy-gated exactly like
        // ui.read_element_value (AXSecureTextField and any disallowed role yield value: nil, never
        // a failed read). Deliberately registered under toolFamily "perception" — NOT "ui" — for
        // the identical reason ui.read_element_value is: the optional exposed value carries the
        // same raw-content-for-reasoning character screen.ocr already established, which is what
        // activates QPlanExecutor's existing isScreenDerivedStep sanitize-before-persist boundary
        // with zero changes to QPlanExecutor's dispatch logic. No mutation, no approval, no
        // recovery: a read that does not throw IS its own result. This is a POINT-IN-TIME SNAPSHOT
        // ONLY — never itself an actionable target reference for any subsequent mutation
        // capability, which must independently perform its own fresh, exact target resolution. See
        // QBridgeAccessibility.readFocusedElement and
        // docs/PHASE_2BG_SEMANTIC_FOCUSED_ELEMENT_READ.md for the full contract.
        "ui.read_focused_element": ("perception", .level0ReadOnly),
        // Phase 2BH: semantic application state read — LEVEL 0 (READ-ONLY). Reads a named running
        // application's own authoritative AX state — kAXHiddenAttribute, kAXFrontmostAttribute,
        // kAXMainWindowAttribute, kAXFocusedWindowAttribute — on the exact same
        // AXUIElementCreateApplication(pid) element ui.list_windows/ui.list_menu_items already
        // resolve. The first capability giving the model any READ visibility into an application's
        // own state: ui.open_app/ui.activate_application/ui.set_application_hidden/app.quit are all
        // write-only or existence-only (system.running_apps reports names only). Deliberately reads
        // the NATIVE AX attributes rather than NSRunningApplication.isHidden/
        // NSWorkspace.frontmostApplication (the heuristic ui.set_application_hidden/
        // ui.activate_application themselves use for their OWN mutation) — this capability's whole
        // purpose is the authoritative Accessibility-layer state, not a re-derivation of what the
        // AppKit-level APIs already report. Application identity is resolved by exact matching via
        // QBridgeAccessibility.resolveExactRunningApplication (unmodified) — zero/ambiguous matches
        // fail closed. kAXHiddenAttribute/kAXFrontmostAttribute are required, authoritative booleans:
        // if either is unreadable from the resolved application element, the whole read fails closed
        // (AX_APPLICATION_STATE_READ_FAILED) — never defaulted to false. kAXMainWindowAttribute/
        // kAXFocusedWindowAttribute are optional single-element references, read for title/identifier
        // ONLY (never descended into further) — a headless/background-only application with no
        // window at all yields a valid, honestly-reported nil for both, mirroring ui.list_windows'
        // "no windows is a legitimate empty state" precedent. Registered under toolFamily "app" —
        // the same application-scoped family as ui.open_app/ui.activate_application/
        // ui.set_application_hidden/app.quit — never "ui" (element-scoped) or "perception" (no
        // free-form content is ever exposed; booleans and window titles are the same safe
        // structural-metadata class ui.list_windows already exposes without redaction). No mutation,
        // no approval, no recovery: a read that does not throw IS its own result. Bounded to a
        // maximum of 3 elements ever touched (the application root plus at most 2 directly-
        // referenced windows), zero recursive traversal, zero children enumerated, zero actions,
        // zero polling. See QBridgeAccessibility.readApplicationState and
        // docs/PHASE_2BH_SEMANTIC_APPLICATION_STATE_READ.md for the full contract.
        "ui.read_application_state": ("app", .level0ReadOnly),
        // Phase 2BI: semantic table column enumeration — LEVEL 0 (READ-ONLY). Enumerates direct
        // column-header elements belonging to exactly ONE named AXTable in an application via
        // kAXColumnHeaderUIElementsAttribute — a direct child read only, never a recursive descent
        // into any column's own contents. Cell data is strictly out of scope, exactly like
        // ui.list_table_rows' own row-identity-only contract; this capability complements it by
        // finally surfacing what each column MEANS, closing an asymmetry independently flagged
        // across three consecutive discovery phases (2BG, 2BH, 2BI) as the strongest still-
        // unimplemented gap. No mutation, no press, no approval, no recovery. Reuses
        // QAXTableRolePolicy (Phase 2AE) unmodified — the identical single-role allowlist
        // (AXTable only) ui.list_table_rows already establishes; no new role policy was
        // introduced. Application identity is resolved by exact matching via
        // QBridgeAccessibility.resolveExactRunningApplication. Bounded by a local defensive
        // ceiling (maxDirectTableColumnsCount = 32) — a maximum of 33 AX elements are ever
        // touched in a single call (the table plus at most 32 columns), traversal depth never
        // exceeds 1, zero actions, zero polling. This is a POINT-IN-TIME SNAPSHOT ONLY: result is
        // informational and never enters durable persistence snapshots beyond an aggregate count;
        // every subsequent capability must independently perform its own fresh, exact target
        // resolution. See QBridgeAccessibility.listTableColumns and
        // docs/PHASE_2BI_SEMANTIC_TABLE_COLUMN_ENUMERATION.md for the full contract.
        "ui.list_table_columns": ("ui", .level0ReadOnly),
        // Phase 2BJ: semantic element range read — LEVEL 0 (READ-ONLY). Reads a semantically-
        // identified element's authoritative numeric range: kAXMinValueAttribute/
        // kAXMaxValueAttribute (both required — the read fails closed rather than fabricating a
        // value if either is unreadable), kAXValueAttribute (current value, required), and the
        // optional kAXValueIncrementAttribute (never required, never defaulted). These are the
        // exact same attributes ui.set_slider_value/ui.step_incrementor/ui.set_splitter_position
        // already read INTERNALLY for their own idempotency/range-validation before ever
        // proposing a mutation — but never previously exposed to the model as their own queryable
        // fact, directly improving the practical safety of those three already-shipped Level 2
        // mutations by letting the model learn valid bounds before proposing a value for human
        // approval. Target roles restricted to a fresh QAXRangeReadRolePolicy allowlist
        // (AXSlider, AXIncrementor, AXSplitter) — every role independently verified against the
        // live macOS SDK's AXRoleConstants.h at implementation time; QAXSliderRolePolicy's own
        // historical "AXStepper" string is deliberately NOT carried forward, since no such role
        // constant exists anywhere in the SDK (an NSStepper's real AX role is AXIncrementor,
        // already covered). Application identity is resolved by exact matching via
        // QBridgeAccessibility.resolveExactRunningApplication; target identity resolved via the
        // existing collectMatches/snapshotIfMatches primitives, identical to ui.read_element_value.
        // Never clamps, never repairs, never substitutes a default for an invalid or inconsistent
        // range (minValue > maxValue, or current value outside [minValue, maxValue]) — fails
        // closed instead. Registered under toolFamily "ui" — not "perception" — since every
        // returned field is a bounded Double, never free-form content requiring the sanitize-
        // before-persist boundary. No mutation, no approval, no recovery: a read that does not
        // throw IS its own result. Bounded to exactly 1 element touched, 0 traversal depth beyond
        // target resolution, 0 children enumerated, 0 actions, 0 polling. See
        // QBridgeAccessibility.readElementRange and
        // docs/PHASE_2BJ_SEMANTIC_ELEMENT_RANGE_READ.md for the full contract.
        "ui.read_element_range": ("ui", .level0ReadOnly),
        // Phase 2BK: semantic element action enumeration — LEVEL 0 (READ-ONLY). Reads a
        // semantically-identified element's supported Accessibility action names via
        // AXUIElementCopyActionNames — a distinct C API from the AXAttributeConstants.h surface
        // every prior capability reads, never previously used anywhere in this codebase. Every
        // existing mutation capability hard-codes a specific action (kAXPressAction/
        // kAXIncrementAction/kAXDecrementAction) chosen per-role by the implementation; this is
        // the first capability that asks an element what it ACTUALLY supports, including
        // app-defined custom actions (NSAccessibilityCustomAction) no fixed role-based policy
        // could anticipate. Reuses QAXElementReadRolePolicy (Phase 2J) unmodified — no broader,
        // arbitrary-role allowlist is introduced. Application identity is resolved by exact
        // matching via QBridgeAccessibility.resolveExactRunningApplication; target identity
        // resolved via the existing collectMatches/snapshotIfMatches primitives, identical to
        // ui.read_element_value. SECURITY-CRITICAL INVARIANT: the returned action names are DATA,
        // not AUTHORIZATION — this capability NEVER calls AXUIElementPerformAction, NEVER grants
        // permissions, NEVER creates approvals or standing grants; discovering that an action
        // name exists never itself authorizes any future action, which must independently pass
        // its own full capability/risk/approval/execution-identity pipeline regardless of this
        // capability ever having been called. Registered under toolFamily "ui" — not
        // "perception" — since action names are structural UI-affordance labels (the same class
        // as identifier/title metadata every list_* capability already exposes without
        // redaction), never typed free-form content requiring the sanitize-before-persist
        // boundary. Bounded to exactly 1 element touched, 0 traversal depth, 0 children
        // enumerated, 0 actions PERFORMED (this is discovery-only), 0 polling, and at most 16
        // returned action-name strings (each individually length-bounded) — exceeding either
        // bound fails closed rather than silently truncating. No mutation, no approval, no
        // recovery: a read that does not throw IS its own result. See
        // QBridgeAccessibility.listElementActions and
        // docs/PHASE_2BK_SEMANTIC_ELEMENT_ACTION_ENUMERATION.md for the full contract.
        "ui.list_element_actions": ("ui", .level0ReadOnly),
        // Phase 2BL: semantic element attribute name enumeration — LEVEL 0 (READ-ONLY). Reads a
        // semantically-identified element's supported Accessibility ATTRIBUTE names via
        // AXUIElementCopyAttributeNames — the direct sibling of ui.list_element_actions (Phase
        // 2BK), which reads ACTION names via the parallel AXUIElementCopyActionNames. Where that
        // capability answers "what can this element DO", this one answers "what can I ASK this
        // element". Every existing read capability (ui.read_element_value, ui.read_element_range,
        // etc.) assumes a fixed, hard-coded attribute per role; this is the first capability that
        // asks an element to self-report its actual supported attribute vocabulary. Reuses
        // QAXElementReadRolePolicy (Phase 2J) unmodified — no broader, arbitrary-role allowlist is
        // introduced. Application identity is resolved by exact matching via
        // QBridgeAccessibility.resolveExactRunningApplication; target identity resolved via the
        // existing collectMatches/snapshotIfMatches primitives, identical to
        // ui.list_element_actions. SECURITY-CRITICAL INVARIANT: discovered attribute NAMES are
        // DATA, not AUTHORIZATION — this capability NEVER reads any attribute's actual VALUE
        // merely because its name was discovered, NEVER calls AXUIElementSetAttributeValue or
        // AXUIElementPerformAction; discovering that an attribute name like "AXValue" exists
        // never itself authorizes a future read of that attribute's value, which must
        // independently go through an existing, approved semantic read capability (e.g.
        // ui.read_element_value) and that capability's own full role/privacy/security policy.
        // Registered under toolFamily "ui" — not "perception" — since attribute names are a
        // near-fixed, short structural vocabulary, never free-form typed content requiring the
        // sanitize-before-persist boundary. Bounded to exactly 1 element touched, 0 traversal
        // depth, 0 children enumerated, 0 actions performed, 0 polling, and at most 32 returned
        // attribute-name strings (each individually length-bounded) — exceeding either bound
        // fails closed rather than silently truncating. No mutation, no approval, no recovery: a
        // read that does not throw IS its own result. See
        // QBridgeAccessibility.listElementAttributes and
        // docs/PHASE_2BL_SEMANTIC_ELEMENT_ATTRIBUTE_ENUMERATION.md for the full contract.
        "ui.list_element_attributes": ("ui", .level0ReadOnly),
        // Phase 2BM: semantic window default/cancel button read — LEVEL 0 (READ-ONLY). Reads a
        // semantically-identified AXWindow's kAXDefaultButtonAttribute/kAXCancelButtonAttribute
        // references — a direct AXUIElementRef to the button that activates on Enter/Escape,
        // where one exists. Both are independently optional; all four combinations (neither,
        // default only, cancel only, both) are valid, expected results — genuine absence
        // (kAXErrorNoValue/kAXErrorAttributeUnsupported) is never an error. A genuine read
        // failure, a malformed reference, or a reference whose own role is not exactly AXButton
        // is NEVER silently folded into "absent" — any of these three problems for either button
        // fails the WHOLE read closed instead. No capability has ever surfaced which button
        // activates on Enter/Escape; ui.list_windows exposes title/identifier/minimized/main per
        // window but never this. Reuses QAXWindowRolePolicy (Phase 2U) unmodified — the identical
        // single-role allowlist (AXWindow only) every other window capability already
        // establishes. Application identity is resolved by exact matching via
        // QBridgeAccessibility.resolveExactRunningApplication; window identity resolved via the
        // existing collectMatches/snapshotIfMatches primitives, identical to
        // ui.set_window_main/ui.close_window. This capability NEVER calls
        // AXUIElementPerformAction or AXUIElementSetAttributeValue — it is strictly
        // observational; it never presses either button, never mutates window state, never
        // changes focus, never activates the application. Registered under toolFamily "ui" —
        // button title/identifier are short structural labels, never free-form typed content
        // requiring the sanitize-before-persist boundary. Bounded to a maximum of 3 AX elements
        // ever touched (the window plus its default and cancel buttons), 0 traversal depth
        // beyond the two direct reference follows, 0 children enumerated, 0 actions performed, 0
        // polling, 1 returned record (window-scoped, never a collection). No mutation, no
        // approval, no recovery: a read that does not throw IS its own result. See
        // QBridgeAccessibility.readWindowDefaultButton and
        // docs/PHASE_2BM_SEMANTIC_WINDOW_DEFAULT_BUTTON.md for the full contract.
        "ui.read_window_default_button": ("ui", .level0ReadOnly),
        // Phase 2BN: semantic element title-reference read — LEVEL 0 (READ-ONLY). Reads a
        // semantically-identified element's kAXTitleUIElementAttribute — a direct AXUIElementRef
        // to whichever element serves as ITS title/label (e.g. a preceding AXStaticText label for
        // an otherwise-untitled text field). No existing capability reads any cross-element
        // semantic relationship — every existing read capability reads an element's own
        // attributes (ui.read_element_value, ui.list_element_attributes) or lists its own
        // children/rows/items (the twenty-odd ui.list_* capabilities); this is a structurally new
        // category of information. The reference is independently optional; genuine absence
        // (kAXErrorNoValue/kAXErrorAttributeUnsupported) is never an error. A genuine read
        // failure, a malformed reference, or a reference whose own role is not on the allowed
        // read-role list is NEVER silently folded into "absent" — any of these three problems
        // fails the read closed instead. Reuses QAXElementReadRolePolicy (Phase 2J) unmodified for
        // BOTH the source element's role AND the referenced title element's own role — no new,
        // broader, or artificial allowlist is introduced for either; a referenced
        // AXSecureTextField is therefore never surfaced as a "safe" reference. Application
        // identity is resolved by exact matching via
        // QBridgeAccessibility.resolveExactRunningApplication; target identity resolved via the
        // existing collectMatches/snapshotIfMatches primitives, identical to
        // ui.read_element_value/ui.list_element_actions. SECURITY-CRITICAL INVARIANT: discovering
        // that a title-reference relationship exists is DATA, not AUTHORIZATION — this capability
        // NEVER calls AXUIElementPerformAction or AXUIElementSetAttributeValue, NEVER grants
        // permissions, NEVER creates approvals or standing grants; the referenced element's raw
        // AXUIElement is never returned or cached, only its bounded, safe role/title/identifier
        // strings — any subsequent action against either element must independently pass its own
        // full resolution/role-policy/QPermissionGate pipeline, completely unaffected by this
        // capability ever having been called. Registered under toolFamily "ui" — title/identifier
        // are short structural labels, never free-form typed content requiring the
        // sanitize-before-persist boundary. Bounded to a maximum of 2 AX elements ever touched
        // (the target plus its title reference), 0 traversal depth beyond the single direct
        // reference follow, 0 children enumerated, 0 actions performed, 0 polling, 1 returned
        // record (never a collection), each string bounded to 256 characters — exceeding it fails
        // closed rather than silently truncating. No mutation, no approval, no recovery: a read
        // that does not throw IS its own result. See
        // QBridgeAccessibility.readElementTitleReference and
        // docs/PHASE_2BN_SEMANTIC_ELEMENT_TITLE_REFERENCE.md for the full contract.
        "ui.read_element_title_reference": ("ui", .level0ReadOnly),
        // Phase 2BO: semantic window modal state read — LEVEL 0 (READ-ONLY). Reads a
        // semantically-identified AXWindow's kAXModalAttribute. Distinct from every prior
        // window-scoped read: kAXModalAttribute is documented "Required for all window elements"
        // — unlike the optional button/title references ui.read_window_default_button/
        // ui.read_element_title_reference resolve, there is no genuine, expected absence case for
        // this attribute, so this capability's missing-vs-failure discipline is inverted relative
        // to those two: EVERY non-success AXError (including kAXErrorNoValue/
        // kAXErrorAttributeUnsupported) is treated as a genuine read failure, never silently
        // downgraded to a guessed false. ui.list_windows exposes title/identifier/minimized/main
        // per window but never modal state. Reuses QAXWindowRolePolicy (Phase 2U) unmodified — the
        // identical single-role allowlist (AXWindow only) every other window capability already
        // establishes. Application identity is resolved by exact matching via
        // QBridgeAccessibility.resolveExactRunningApplication; window identity resolved via the
        // existing collectMatches/snapshotIfMatches primitives, identical to
        // ui.read_window_default_button. This capability NEVER calls AXUIElementPerformAction or
        // AXUIElementSetAttributeValue, and NEVER begins or ends a modal session itself — it is
        // strictly observational; it only ever reads the AX attribute a real, independently
        // running modal session would already have set. Registered under toolFamily "ui" — the
        // returned isModal boolean is structural UI state, never free-form typed content requiring
        // the sanitize-before-persist boundary. Bounded to exactly 1 AX element ever touched (the
        // window itself — no reference-follow hop), 0 traversal depth, 0 children enumerated, 0
        // actions performed, 0 polling, 1 returned record. No mutation, no approval, no recovery: a
        // read that does not throw IS its own result. See
        // QBridgeAccessibility.readWindowModalState and
        // docs/PHASE_2BO_SEMANTIC_WINDOW_MODAL_STATE.md for the full contract.
        "ui.read_window_modal_state": ("ui", .level0ReadOnly),
        // Phase 2BP: semantic element parameterized attribute name enumeration — LEVEL 0
        // (READ-ONLY). Reads a semantically-identified element's supported PARAMETERIZED
        // Accessibility attribute names via AXUIElementCopyParameterizedAttributeNames — the third
        // and final sibling in the "what can I ask this element" enumeration family alongside
        // ui.list_element_actions (Phase 2BK, AXUIElementCopyActionNames) and
        // ui.list_element_attributes (Phase 2BL, AXUIElementCopyAttributeNames), completing that
        // architectural trio. Where those two answer "what can this element DO" and "what can I
        // ask this element directly", this one answers "what queries requiring a PARAMETER (e.g.
        // AXCellForColumnAndRow on a table, AXLineForIndex on a text element) does this element
        // support". Reuses QAXElementReadRolePolicy (Phase 2J) unmodified — no broader,
        // arbitrary-role allowlist is introduced. Application identity is resolved by exact
        // matching via QBridgeAccessibility.resolveExactRunningApplication; target identity
        // resolved via the existing collectMatches/snapshotIfMatches primitives, identical to
        // ui.list_element_attributes. SECURITY-CRITICAL INVARIANT: discovered parameterized
        // attribute NAMES are DATA, not AUTHORIZATION — this capability NEVER calls
        // AXUIElementCopyParameterizedAttributeValue (no parameterized attribute is ever actually
        // invoked with any parameter), NEVER calls AXUIElementSetAttributeValue or
        // AXUIElementPerformAction; discovering that a name like "AXLineForIndex" exists never
        // itself authorizes a future invocation of it, which must independently go through its own
        // dedicated future capability and that capability's own full role/privacy/security policy.
        // kAXErrorAttributeUnsupported/kAXErrorParameterizedAttributeUnsupported/
        // kAXErrorNotImplemented are treated as a valid, expected EMPTY result — many elements
        // genuinely support zero parameterized attributes, and this is never an error; any other
        // AXError fails closed. Registered under toolFamily "ui" — not "perception" — since
        // parameterized attribute names are a near-fixed, short structural vocabulary defined by
        // Apple's own AX API, never free-form typed content requiring the sanitize-before-persist
        // boundary. Bounded to exactly 1 element touched, 0 traversal depth, 0 children
        // enumerated, 0 actions performed, 0 polling, and at most 32 returned parameterized
        // attribute-name strings (reusing maxElementAttributesCount — a sibling enumeration
        // surface, not a distinct category warranting its own bound), each individually
        // length-bounded (reusing maxAttributeNameLength) — exceeding either bound fails closed
        // rather than silently truncating. No mutation, no approval, no recovery: a read that does
        // not throw IS its own result. See
        // QBridgeAccessibility.listElementParameterizedAttributeNames and
        // docs/PHASE_2BP_SEMANTIC_PARAMETERIZED_ATTRIBUTE_NAMES.md for the full contract.
        "ui.list_element_parameterized_attribute_names": ("ui", .level0ReadOnly),
        // Phase 2BQ: semantic element required-state read — LEVEL 0 (READ-ONLY). Reads a
        // semantically-identified element's AXRequired attribute — whether the element is required
        // for successful form submission. AXRequired has no C-level constant in this SDK's
        // AXAttributeConstants.h; the SDK evidence is AppKit's own NSAccessibilityRequiredAttribute
        // (NSAccessibilityConstants.h, available since macOS 10.12), whose underlying
        // NS_TYPED_ENUM type does not bridge directly to the CFString AXUIElementCopyAttributeValue
        // expects — the raw wire-format string "AXRequired" is used directly, mirroring this
        // file's own established axFullScreenAttribute/axIdentifierAttributeName precedent for
        // attributes lacking a HIServices C constant. Unlike kAXModalAttribute (documented
        // "Required for all window elements"), AXRequired is meaningful only for form-field-like
        // elements — genuine absence (kAXErrorNoValue/kAXErrorAttributeUnsupported) is therefore a
        // valid, expected nil result here, never an error, and never silently downgraded to false;
        // a genuine read failure or a malformed (non-Boolean) value fails the whole read closed
        // instead. Reuses QAXElementReadRolePolicy (Phase 2J) unmodified — no broader,
        // arbitrary-role allowlist is introduced. Application identity is resolved by exact
        // matching via QBridgeAccessibility.resolveExactRunningApplication; target identity
        // resolved via the existing collectMatches/snapshotIfMatches primitives, identical to
        // ui.list_element_parameterized_attribute_names. This capability NEVER calls
        // AXUIElementPerformAction or AXUIElementSetAttributeValue — observing that a field is
        // required never authorizes any future mutation (e.g. ui.set_text_value) against it, which
        // must independently pass its own full capability/risk/approval/execution-identity
        // pipeline. Registered under toolFamily "ui" — the returned isRequired boolean is
        // structural form metadata, never free-form typed content requiring the
        // sanitize-before-persist boundary. Bounded to exactly 1 element touched, 0 traversal
        // depth, 0 children enumerated, 0 actions performed, 0 polling, 1 returned record. No
        // mutation, no approval, no recovery: a read that does not throw IS its own result. See
        // QBridgeAccessibility.readElementRequiredState and
        // docs/PHASE_2BQ_SEMANTIC_ELEMENT_REQUIRED_STATE.md for the full contract.
        "ui.read_element_required_state": ("ui", .level0ReadOnly),
        // Phase 2BR: semantic element protected-content state read — LEVEL 0 (READ-ONLY). Reads a
        // semantically-identified element's AXContainsProtectedContent attribute — whether the
        // element contains protected content (e.g. a secure field). AXContainsProtectedContent has
        // no C-level constant in this SDK's AXAttributeConstants.h; the SDK evidence is AppKit's
        // own NSAccessibilityContainsProtectedContentAttribute (NSAccessibilityConstants.h,
        // available since macOS 10.9), whose underlying NS_TYPED_ENUM type does not bridge
        // directly to the CFString AXUIElementCopyAttributeValue expects — the raw wire-format
        // string "AXContainsProtectedContent" is used directly, mirroring this file's own
        // established axRequiredAttributeName precedent (Phase 2BQ) for attributes lacking a
        // HIServices C constant. Unlike kAXModalAttribute (documented "Required for all window
        // elements"), AXContainsProtectedContent is meaningful only for elements that can
        // meaningfully hold sensitive content — genuine absence
        // (kAXErrorNoValue/kAXErrorAttributeUnsupported) is therefore a valid, expected nil result
        // here, never an error, and never silently downgraded to false; a genuine read failure or
        // a malformed (non-Boolean) value fails the whole read closed instead. Reuses
        // QAXElementReadRolePolicy (Phase 2J) unmodified — no broader, arbitrary-role allowlist is
        // introduced. Application identity is resolved by exact matching via
        // QBridgeAccessibility.resolveExactRunningApplication; target identity resolved via the
        // existing collectMatches/snapshotIfMatches primitives, identical to
        // ui.read_element_required_state. This is the first capability in the program whose entire
        // purpose is defensive/security-aware observation — the boolean it returns exists to help
        // a future planner AVOID sensitive content, never to expose any of that content itself.
        // This capability NEVER calls AXUIElementPerformAction or AXUIElementSetAttributeValue,
        // and NEVER reads any attribute other than AXContainsProtectedContent — observing that a
        // field is protected never authorizes any future read of its actual value (e.g.
        // ui.read_element_value), which must independently pass its own full
        // capability/risk/approval/execution-identity pipeline. Registered under toolFamily "ui" —
        // the returned isProtectedContent boolean is structural security-state metadata, never the
        // protected content itself, and never requires the sanitize-before-persist boundary since
        // no content ever crosses it. Bounded to exactly 1 element touched, 0 traversal depth, 0
        // children enumerated, 0 actions performed, 0 polling, 1 returned record. No mutation, no
        // approval, no recovery: a read that does not throw IS its own result. See
        // QBridgeAccessibility.readElementProtectedContentState and
        // docs/PHASE_2BR_SEMANTIC_ELEMENT_PROTECTED_CONTENT_STATE.md for the full contract.
        "ui.read_element_protected_content_state": ("ui", .level0ReadOnly),
        // Phase 2BS: semantic text selection state read — LEVEL 0 (READ-ONLY). Reads a
        // semantically-identified element's text-selection STATE via
        // kAXSelectedTextRangeAttribute (location/length) and kAXNumberOfCharactersAttribute
        // (total) — never the selected TEXT itself (kAXSelectedTextAttribute is never read).
        // Both attributes are documented "Required for all editable text elements" but not
        // universally present on every AX element, so this capability follows the
        // OPTIONAL-reference missing-vs-failure pattern established for AXRequired/
        // AXContainsProtectedContent (Phases 2BQ/2BR): genuine absence of EITHER attribute makes
        // the WHOLE result nil, never a partially-known state, and is never silently downgraded
        // to a fabricated zero/empty state. A structurally invalid range/count (negative
        // location/length/total) or an internally inconsistent triple (selectionLocation +
        // selectionLength exceeding totalCharacterCount, checked with overflow-safe arithmetic)
        // fails the whole read closed instead. A selectionLength of 0 is a fully valid result
        // (a caret/insertion point), never an error. Reuses QAXElementReadRolePolicy (Phase 2J)
        // unmodified — no broader, arbitrary-role allowlist is introduced, and AXSecureTextField
        // remains excluded as a target exactly as for every other read capability. Application
        // identity is resolved by exact matching via
        // QBridgeAccessibility.resolveExactRunningApplication; target identity resolved via the
        // existing collectMatches/snapshotIfMatches primitives, identical to
        // ui.read_element_protected_content_state. This capability NEVER calls
        // AXUIElementPerformAction or AXUIElementSetAttributeValue — even though
        // kAXSelectedTextRangeAttribute is itself documented Writable? Yes at the native API
        // level, this capability is strictly read-only and never writes it; observing selection
        // state never authorizes any future read of the actual text (ui.read_element_value) or
        // any mutation (ui.set_text_value), both of which must independently pass their own full
        // capability/risk/approval/execution-identity pipeline. Registered under toolFamily "ui"
        // — the returned fields are bounded numeric structural metadata, never the text content
        // itself, and never require the sanitize-before-persist boundary since no content ever
        // crosses it. Bounded to exactly 1 element touched, at most 2 AX attributes read, 0
        // traversal depth, 0 children enumerated, 0 actions performed, 0 polling, 1 returned
        // record. No mutation, no approval, no recovery: a read that does not throw IS its own
        // result. See QBridgeAccessibility.readTextSelectionState and
        // docs/PHASE_2BS_SEMANTIC_TEXT_SELECTION_STATE.md for the full contract.
        "ui.read_text_selection_state": ("ui", .level0ReadOnly),
        // Phase 2BT: semantic column sort-direction read — LEVEL 0 (READ-ONLY). Reads a
        // semantically-identified AXColumn's kAXSortDirectionAttribute. Complements
        // ui.list_table_columns (Phase 2BI), which enumerates a table's columns but never reads
        // this attribute. This SDK documents TWO distinct native representations for sort
        // direction: an NSString-based value enum (NSAccessibilitySortDirectionValue —
        // NSAccessibilityAscendingSortDirectionValue/NSAccessibilityDescendingSortDirectionValue/
        // NSAccessibilityUnknownSortDirectionValue) intended for the wire-format attribute value,
        // and a separate NSInteger enum (NSAccessibilitySortDirection: unknown=0/ascending=1/
        // descending=2) intended for the app-side settable property. Rather than assuming either
        // (this environment cannot empirically observe a live AX round-trip), the implementation
        // validates the returned value against BOTH sets of real, linked AppKit symbols — never a
        // hardcoded guessed literal. Genuine absence of the attribute itself
        // (kAXErrorNoValue/kAXErrorAttributeUnsupported) is a valid, expected nil result —
        // kAXSortDirectionAttribute carries no "required for all AXColumn elements"-style
        // documentation — and is never conflated with the equally valid "none" result (the
        // attribute present, reporting the column is simply not currently sorted). A recognized
        // CFType whose value matches neither documented set fails closed instead of ever being
        // silently mapped to "none". Uses a new, narrow QAXColumnReadRolePolicy (AXColumn only) —
        // a structural table/browser role that does not belong in the generic
        // QAXElementReadRolePolicy allowlist, mirroring QAXWindowRolePolicy's identical
        // single-role shape. Application identity is resolved by exact matching via
        // QBridgeAccessibility.resolveExactRunningApplication; target identity resolved via the
        // existing collectMatches/snapshotIfMatches primitives, identical to every prior
        // window/element-scoped read. This capability NEVER calls AXUIElementPerformAction or
        // AXUIElementSetAttributeValue — observing the current sort direction never authorizes
        // clicking the column header or any other mutation, which must independently pass its own
        // full capability/risk/approval/execution-identity pipeline. Registered under toolFamily
        // "ui" — the returned sortDirection is a bounded 3-value structural enum, never table/cell
        // content, never requiring the sanitize-before-persist boundary. Bounded to exactly 1
        // element touched, 0 traversal depth, 0 children enumerated, 0 actions performed, 0
        // polling, 1 returned record. No mutation, no approval, no recovery: a read that does not
        // throw IS its own result. See QBridgeAccessibility.readColumnSortDirection and
        // docs/PHASE_2BT_SEMANTIC_COLUMN_SORT_DIRECTION.md for the full contract.
        "ui.read_column_sort_direction": ("ui", .level0ReadOnly),
        // Phase 2BU: semantic table dimensions read — LEVEL 0 (READ-ONLY). Reads a
        // semantically-identified AXTable's kAXRowCountAttribute and kAXColumnCountAttribute.
        // Complements ui.list_table_rows/ui.list_table_columns (which each perform a full,
        // traversal-based enumeration) by letting a caller learn a table's bounded structural SIZE
        // first — exactly two scalar AX reads, zero traversal — before deciding whether a full
        // enumeration is worth its resource cost. Reuses QAXTableRolePolicy (Phase 2AE) completely
        // unmodified — the identical single-role allowlist (AXTable only) ui.list_table_rows/
        // ui.list_table_columns already establish; no new role policy was introduced. Unlike
        // kAXSortDirectionAttribute, kAXRowCountAttribute/kAXColumnCountAttribute are backed by
        // NON-OPTIONAL NSInteger properties on the modern AppKit accessibility protocol
        // (accessibilityRowCount/accessibilityColumnCount, never declared nullable) — this is the
        // INVERTED missing-vs-failure pattern (matching kAXModalAttribute, Phase 2BO): for a
        // genuine AXTable-role element, genuine absence of either attribute
        // (kAXErrorNoValue/kAXErrorAttributeUnsupported) is itself treated as a read FAILURE, never
        // silently downgraded to a default or a partial result. Both counts are validated as
        // genuine, non-negative, Int-representable integers (rejecting wrong CFType, floating-point
        // native subtypes, negative values, and Int overflow) before ever being exposed; the result
        // is ATOMIC — QAXTableDimensionsMetadata is only ever constructed once BOTH counts have
        // independently validated, a failure reading either one fails the whole call, never a
        // partially-populated result. Application identity is resolved by exact matching via
        // QBridgeAccessibility.resolveExactRunningApplication; target identity resolved via the
        // existing collectMatches/snapshotIfMatches primitives, identical to every prior
        // window/element-scoped read. This capability NEVER calls AXUIElementPerformAction or
        // AXUIElementSetAttributeValue — observing a table's dimensions never authorizes
        // ui.list_table_rows, ui.list_table_columns, ui.select_table_row, or any other mutation,
        // which must independently pass its own full capability/risk/approval/execution-identity
        // pipeline. Registered under toolFamily "ui" — the returned rowCount/columnCount are
        // bounded non-negative integers, never table/cell content, never requiring the
        // sanitize-before-persist boundary. Bounded to exactly 1 element touched, 0 traversal
        // depth, 0 children enumerated, 0 actions performed, 0 polling, 1 returned record. No
        // mutation, no approval, no recovery: a read that does not throw IS its own result. See
        // QBridgeAccessibility.readTableDimensions and
        // docs/PHASE_2BU_SEMANTIC_TABLE_DIMENSIONS.md for the full contract.
        "ui.read_table_dimensions": ("ui", .level0ReadOnly),
        // Phase 2BV: semantic element allowed-values read — LEVEL 0 (READ-ONLY). Reads a
        // semantically-identified element's kAXAllowedValuesAttribute. Directly complements
        // ui.read_element_range (Phase 2BJ): range describes the CONTINUOUS bound
        // (min/max/increment/current), while this capability describes the DISCRETE subset of
        // values within that bound a control may legitimately be set to — letting a caller learn
        // exactly which values ui.set_slider_value/ui.step_incrementor/ui.set_splitter_position
        // may safely target before ever attempting a mutation. Reuses QAXRangeReadRolePolicy
        // (AXSlider/AXIncrementor/AXSplitter) completely unmodified — the identical policy
        // ui.read_element_range already uses; no new role policy was introduced. Genuine absence
        // of the attribute (kAXErrorNoValue/kAXErrorAttributeUnsupported) is a valid, expected nil
        // whole-result — the SDK documents this attribute as applying only to elements "that can
        // only be set to a small subset of values", never a universal requirement — distinct from
        // a genuinely PRESENT but EMPTY array, which is its own valid, non-nil result. Every array
        // element is independently validated: a genuine NSNumber is required (the whole array
        // fails closed if even one element is not NSNumber-compatible, never silently dropping
        // invalid entries), integer representations are round-tripped through Double to reject any
        // value that cannot be represented exactly, and floating-point representations are
        // rejected if NaN or +/-Infinity. The array itself is bounded by maxAllowedValuesCount
        // (128) — exceeding it fails closed rather than ever silently truncating. Application
        // identity is resolved by exact matching via QBridgeAccessibility.resolveExactRunningApplication;
        // target identity resolved via the existing collectMatches/snapshotIfMatches primitives,
        // identical to every prior window/element-scoped read. This capability NEVER calls
        // AXUIElementPerformAction or AXUIElementSetAttributeValue — observing a control's allowed
        // values never authorizes ui.set_slider_value, ui.step_incrementor,
        // ui.set_splitter_position, or any other mutation, which must independently pass its own
        // full capability/risk/approval/execution-identity pipeline. Registered under toolFamily
        // "ui" — the returned allowedValues are a bounded array of validated Doubles, never
        // table/cell/text content, never requiring the sanitize-before-persist boundary. Bounded
        // to exactly 1 element touched, 0 traversal depth, 0 children enumerated, 0 actions
        // performed, 0 polling, 1 returned record. No mutation, no approval, no recovery: a read
        // that does not throw IS its own result. See
        // QBridgeAccessibility.readElementAllowedValues and
        // docs/PHASE_2BV_SEMANTIC_ELEMENT_ALLOWED_VALUES.md for the full contract.
        "ui.read_element_allowed_values": ("ui", .level0ReadOnly),
        // Phase 2BW: semantic element value-description read — LEVEL 0 (READ-ONLY). Reads a
        // semantically-identified element's kAXValueDescriptionAttribute. Directly complements
        // ui.read_element_value (Phase 2J/2K, kAXValueAttribute): this capability reads the
        // SDK-documented human-readable SUPPLEMENT to the raw value — the canonical example being
        // a color slider whose numeric kAXValueAttribute position is uninterpretable on its own,
        // but whose kAXValueDescriptionAttribute reads "Deep Blue". This capability NEVER reads
        // kAXValueAttribute itself — that remains ui.read_element_value's exclusive contract.
        // Reuses QAXElementReadRolePolicy (Phase 2J) completely unmodified — the identical
        // allowlist and secure-field-first-then-general-allowlist discipline
        // ui.read_element_value/ui.list_element_actions already establish; AXSecureTextField is
        // rejected before ever reaching the general allowlist. Genuine absence of the attribute
        // (kAXErrorNoValue/kAXErrorAttributeUnsupported) is a valid, expected nil whole-result —
        // the SDK documents this attribute as merely "Recommended for elements that support
        // kAXValueAttribute", never a universal requirement — distinct from a genuinely PRESENT
        // but EMPTY string, which is its own valid, non-nil result. The returned string is bounded
        // by maxValueDescriptionLength (256 characters) — exceeding it fails closed rather than
        // ever silently truncating. Application identity is resolved by exact matching via
        // QBridgeAccessibility.resolveExactRunningApplication; target identity resolved via the
        // existing collectMatches/snapshotIfMatches primitives, identical to every prior
        // window/element-scoped read. This capability NEVER calls AXUIElementPerformAction or
        // AXUIElementSetAttributeValue — observing an element's value description never
        // authorizes ui.set_text_value, ui.set_slider_value, ui.step_incrementor,
        // ui.set_element_state, or any other mutation, which must independently pass its own full
        // capability/risk/approval/execution-identity pipeline. Registered under toolFamily "ui"
        // — the returned valueDescription is bounded semantic UI metadata (the same sensitivity
        // class as an already-exposed title/help string), never arbitrary text content, never
        // requiring the sanitize-before-persist boundary. Bounded to exactly 1 element touched, 0
        // traversal depth, 0 children enumerated, 0 actions performed, 0 polling, 1 returned
        // record. No mutation, no approval, no recovery: a read that does not throw IS its own
        // result. See QBridgeAccessibility.readElementValueDescription and
        // docs/PHASE_2BW_SEMANTIC_ELEMENT_VALUE_DESCRIPTION.md for the full contract.
        "ui.read_element_value_description": ("ui", .level0ReadOnly),
        // Phase 2BX: semantic label served-elements read — LEVEL 0 (READ-ONLY). Reads a
        // semantically-identified element's kAXServesAsTitleForUIElementsAttribute — the
        // structural INVERSE of ui.read_element_title_reference (Phase 2BN,
        // kAXTitleUIElementAttribute): that capability answers "what titles ME"; this one answers
        // "which elements do I serve as the title FOR". Reuses QAXElementReadRolePolicy
        // (Phase 2J) completely unmodified — the identical allowlist and secure-field-first-then-
        // general-allowlist discipline ui.read_element_value/ui.read_element_title_reference
        // already establish for BOTH the source label element AND every individually-validated
        // served element. A bounded relationship query, never generic extraction: exactly one AX
        // attribute read on the resolved source element, then only bounded identity reads
        // (role/title/identifier) on each already-enumerated served element — never a recursive
        // descent, never a second relationship hop, never kAXValueAttribute. ATOMIC ARRAY
        // DISCIPLINE (mirrors ui.read_element_allowed_values, Phase 2BV): a single malformed,
        // unreadable, or disallowed-role served element fails the WHOLE array closed — invalid
        // entries are never silently dropped — and the array is bounded by
        // maxServedElementsCount (32), checked BEFORE any per-element extraction, never
        // truncated. Genuine absence of the attribute (kAXErrorNoValue/kAXErrorAttributeUnsupported)
        // is a valid, expected nil whole-result — most elements serve as the title for nothing at
        // all — distinct from a genuinely PRESENT but EMPTY array, which is its own valid, non-nil
        // result. Application identity is resolved by exact matching via
        // QBridgeAccessibility.resolveExactRunningApplication; target identity resolved via the
        // existing collectMatches/snapshotIfMatches primitives, identical to every prior
        // window/element-scoped read. This capability NEVER calls AXUIElementPerformAction or
        // AXUIElementSetAttributeValue — observing this relationship never authorizes any mutation
        // against either the source label or any served element, which must independently pass
        // its own full capability/risk/approval/execution-identity pipeline. Registered under
        // toolFamily "ui" — the returned servedElements are bounded identity-only references
        // (role/title/identifier), never content, never requiring the sanitize-before-persist
        // boundary. Bounded to exactly 1 source element touched, 0 traversal depth beyond the
        // bounded served-element identity reads, 0 actions performed, 0 polling, 1 returned
        // record. No mutation, no approval, no recovery: a read that does not throw IS its own
        // result. See QBridgeAccessibility.listLabelServedElements and
        // docs/PHASE_2BX_SEMANTIC_LABEL_SERVED_ELEMENTS.md for the full contract.
        "ui.list_label_served_elements": ("ui", .level0ReadOnly),
        // Phase 2BY: semantic window auxiliary buttons read — LEVEL 0 (READ-ONLY). Reads a
        // semantically-identified window's kAXZoomButtonAttribute/kAXMinimizeButtonAttribute/
        // kAXToolbarButtonAttribute/kAXFullScreenButtonAttribute references. A direct sibling of
        // ui.read_window_default_button (Phase 2BM), extended from 2 to 4 button attributes —
        // this capability NEVER reads kAXDefaultButtonAttribute/kAXCancelButtonAttribute (that
        // remains ui.read_window_default_button's exclusive contract) and NEVER reads
        // kAXCloseButtonAttribute (already used internally, for mutation, by ui.close_window).
        // All four fields are independently optional — many windows have none of these buttons;
        // all sixteen combinations are valid, expected results. Reuses QAXWindowRolePolicy
        // (Phase 2U) unmodified and, critically, reuses ui.read_window_default_button's own
        // resolveWindowButtonReference resolver and its complete QAXInteractionError taxonomy
        // VERBATIM — zero new error cases were introduced. Genuine absence
        // (kAXErrorNoValue/kAXErrorAttributeUnsupported) is a valid, expected nil for that field —
        // many windows have no such button — distinct from a genuine read failure, a malformed
        // reference, or a reference whose own role is not exactly AXButton, any of which for ANY
        // of the four buttons fails the WHOLE read closed (identical atomic discipline to
        // ui.read_window_default_button). Application identity is resolved by exact matching via
        // QBridgeAccessibility.resolveExactRunningApplication; window identity resolved via the
        // existing collectMatches/snapshotIfMatches primitives, identical to
        // ui.read_window_default_button/ui.set_window_main/ui.close_window. This capability NEVER
        // calls AXUIElementPerformAction or AXUIElementSetAttributeValue — it is strictly
        // observational; it never presses any button, never mutates window state, never changes
        // focus, never activates the application, and never authorizes ui.set_window_full_screen
        // or ui.set_window_minimized, which retain their own independent
        // capability/risk/approval/execution-identity pipelines. Registered under toolFamily "ui"
        // — button title/identifier are short structural labels, never free-form typed content
        // requiring the sanitize-before-persist boundary. Bounded to a maximum of 5 AX elements
        // ever touched (the window plus its four button references), 0 traversal depth beyond
        // the four direct reference follows, 0 children enumerated, 0 actions performed, 0
        // polling, 1 returned record (window-scoped, never a collection). No mutation, no
        // approval, no recovery: a read that does not throw IS its own result. See
        // QBridgeAccessibility.readWindowAuxiliaryButtons and
        // docs/PHASE_2BY_SEMANTIC_WINDOW_AUXILIARY_BUTTONS.md for the full contract.
        "ui.read_window_auxiliary_buttons": ("ui", .level0ReadOnly),
        // Phase 2BZ: semantic table row-header enumeration — LEVEL 0 (READ-ONLY). Enumerates
        // direct row-header elements belonging to exactly ONE named AXTable in an application via
        // kAXRowHeaderUIElementsAttribute — a direct child read only, never a recursive descent
        // into any row-header's own contents. Cell data is strictly out of scope, exactly like
        // ui.list_table_columns' own column-header-identity-only contract; this capability is the
        // direct structural mirror of ui.list_table_columns (Phase 2BI), using the SDK-symmetric
        // AXRow role in place of AXColumn (kAXRowRole/kAXColumnRole are direct sibling constants
        // in AXRoleConstants.h, exactly mirroring kAXRowHeaderUIElementsAttribute/
        // kAXColumnHeaderUIElementsAttribute's own naming symmetry). No mutation, no press, no
        // approval, no recovery. Reuses QAXTableRolePolicy (Phase 2AE) unmodified — the identical
        // single-role allowlist (AXTable only) ui.list_table_columns/ui.list_table_rows already
        // establish; no new role policy was introduced. Application identity is resolved by exact
        // matching via QBridgeAccessibility.resolveExactRunningApplication. Bounded by
        // maxDirectTableRowHeadersCount (32) — a maximum of 33 AX elements are ever touched in a
        // single call (the table plus at most 32 row headers), traversal depth never exceeds 1,
        // zero actions, zero polling. Unlike ui.list_table_columns' own dual-strategy fallback,
        // this capability applies the stricter, later-established atomic fail-closed discipline
        // (ui.read_element_allowed_values, Phase 2BV; ui.list_label_served_elements, Phase 2BX):
        // a malformed outer CFType, an oversized array, a non-AXUIElement element, a
        // disallowed-role element, or oversized element metadata each fails the WHOLE result
        // closed — never a silent fallback, never a silently filtered "mostly valid" result.
        // Genuine attribute absence (kAXErrorNoValue/kAXErrorAttributeUnsupported) remains a
        // fully valid, expected result (rowHeaders == []) — most ordinary tables have no row
        // headers at all. This is a POINT-IN-TIME SNAPSHOT ONLY: result is informational and
        // never enters durable persistence snapshots beyond an aggregate count; every subsequent
        // capability must independently perform its own fresh, exact target resolution. See
        // QBridgeAccessibility.listTableRowHeaders and
        // docs/PHASE_2BZ_SEMANTIC_TABLE_ROW_HEADER_ENUMERATION.md for the full contract.
        "ui.list_table_row_headers": ("ui", .level0ReadOnly),
        // Phase 2CA: semantic scroll position read — LEVEL 0 (READ-ONLY). Read-only counterpart to
        // ui.set_scroll_position (Phase 2W): reads exactly one AXScrollBar's kAXValueAttribute,
        // resolved via the identical, completely unmodified target-resolution chain
        // ui.set_scroll_position already established — QAXScrollAreaRolePolicy (AXScrollArea only)
        // as the search-criterion role, an explicit never-inferred orientation argument mapped to
        // kAXHorizontalScrollBarAttribute/kAXVerticalScrollBarAttribute, and the resolved scroll
        // bar's own kAXRoleAttribute independently re-validated as exactly AXScrollBar before ever
        // being treated as genuine. No mutation, no press, no approval, no recovery: neither
        // AXUIElementPerformAction nor AXUIElementSetAttributeValue is invoked anywhere in this
        // capability. Unlike kAXAllowedValuesAttribute/kAXValueDescriptionAttribute's own
        // optional-reference absence semantics, kAXValueAttribute on a genuine AXScrollBar has NO
        // valid-absence case — every failure mode (permission denial, unresolvable target, stale
        // target, a genuine AXError, a non-CFNumberRef returned value, a CFNumberGetValue
        // extraction failure, a non-finite value, or a value outside [0.0, 1.0]) fails closed with
        // its own dedicated diagnostic; nothing is ever silently defaulted, clamped, or guessed.
        // Bounded to exactly 1 resolved scroll-area target, 1 scroll-bar reference follow, 1
        // kAXValueAttribute read, 0 traversal beyond the single documented convenience-reference
        // hop, 0 actions, 0 polling, 0 retries. See QBridgeAccessibility.readScrollPosition and
        // docs/PHASE_2CA_SEMANTIC_SCROLL_POSITION.md for the full contract.
        "ui.read_scroll_position": ("ui", .level0ReadOnly),
        // Phase 2CB: semantic element role description read — LEVEL 0 (READ-ONLY). Reads exactly
        // one semantically-identified element's kAXRoleDescriptionAttribute — the SDK's own
        // localized, human-readable explanation of an element's basic type or purpose (e.g. "push
        // button", "checkbox", "text field"), distinct from both kAXRoleAttribute (the raw,
        // non-localized internal role string, e.g. "AXButton") and kAXValueDescriptionAttribute
        // (ui.read_element_value_description, Phase 2BW — a description of the element's CURRENT
        // VALUE, never its type). Reuses QAXElementReadRolePolicy (Phase 2J) and the identical
        // secure-field-first-then-general-allowlist discipline ui.read_element_value/
        // ui.list_element_actions/ui.read_element_value_description already establish — no
        // broader, arbitrary-role allowlist is introduced, and AXSecureTextField is rejected
        // before the general allowlist is ever consulted. No mutation, no press, no approval, no
        // recovery: neither AXUIElementPerformAction nor AXUIElementSetAttributeValue is invoked
        // anywhere in this capability, and kAXValueAttribute is never read. Unlike
        // kAXValueDescriptionAttribute's own optional-reference absence semantics,
        // kAXRoleDescriptionAttribute's SDK documentation states it is "Required for all
        // elements" (even a truly unclassifiable element must supply "unknown") — there is no
        // genuine, expected absence case, so every failure mode (permission denial, unresolvable
        // target, stale target, a genuine AXError, a non-CFStringRef returned value, a genuinely
        // empty string, or a string exceeding the defensive length bound) fails closed with its
        // own dedicated diagnostic; nothing is ever silently defaulted, derived from
        // kAXRoleAttribute, or truncated. Bounded to exactly 1 resolved target, 0 relationship
        // hops, 1 kAXRoleDescriptionAttribute read, 0 traversal, 0 actions, 0 polling, 0 retries.
        // See QBridgeAccessibility.readElementRoleDescription and
        // docs/PHASE_2CB_SEMANTIC_ROLE_DESCRIPTION.md for the full contract.
        "ui.read_element_role_description": ("ui", .level0ReadOnly),
        // Phase 2CC: semantic element help text read — LEVEL 0 (READ-ONLY). Reads exactly one
        // semantically-identified element's kAXHelpAttribute — the SDK's own localized,
        // human-readable help/tooltip content for an element ("often the same information that
        // would be provided in a help tag for the element"), distinct from both
        // kAXRoleDescriptionAttribute (ui.read_element_role_description, Phase 2CB — a description
        // of the element's TYPE) and kAXValueDescriptionAttribute (ui.read_element_value_description,
        // Phase 2BW — a description of the element's CURRENT VALUE). Reuses QAXElementReadRolePolicy
        // (Phase 2J) and the identical secure-field-first-then-general-allowlist discipline
        // ui.read_element_value/ui.list_element_actions/ui.read_element_value_description/
        // ui.read_element_role_description already establish — no broader, arbitrary-role allowlist
        // is introduced, and AXSecureTextField is rejected before the general allowlist is ever
        // consulted. No mutation, no press, no approval, no recovery: neither
        // AXUIElementPerformAction nor AXUIElementSetAttributeValue is invoked anywhere in this
        // capability, and kAXValueAttribute is never read. kAXHelpAttribute carries no
        // "required for all elements"-style documentation — the doc says only "Recommended for any
        // element that has help data available" — so genuine absence
        // (kAXErrorNoValue/kAXErrorAttributeUnsupported) is the OPTIONAL-REFERENCE pattern, a valid,
        // expected nil WHOLE RESULT, identical to ui.read_element_value_description's own absence
        // semantics (unlike ui.read_element_role_description's required-attribute, no-valid-absence
        // contract). Every other failure mode (permission denial, unresolvable target, stale target,
        // a genuine AXError, a non-CFStringRef returned value, or a string exceeding the defensive
        // length bound) fails closed with its own dedicated diagnostic; nothing is ever silently
        // defaulted or truncated. Bounded to exactly 1 resolved target, 0 relationship hops, 1
        // kAXHelpAttribute read, 0 traversal, 0 actions, 0 polling, 0 retries. See
        // QBridgeAccessibility.readElementHelpText and
        // docs/PHASE_2CC_SEMANTIC_HELP_TEXT.md for the full contract.
        "ui.read_element_help_text": ("ui", .level0ReadOnly),
        // Phase 2CD: `ui.read_element_placeholder_value` reads a semantically-identified element's
        // kAXPlaceholderValueAttribute — the UI-author-provided hint text a field shows while
        // empty, distinct from kAXValueAttribute (the field's actual, potentially sensitive,
        // user-entered content — never read here) and from kAXHelpAttribute/
        // kAXValueDescriptionAttribute/kAXRoleDescriptionAttribute (tooltip/value-description/type
        // strings). Reuses QAXElementReadRolePolicy and its AXSecureTextField exclusion completely
        // unmodified from every prior read capability in this family — no broader, arbitrary-role
        // allowlist is introduced, and AXSecureTextField is rejected before the general allowlist
        // is ever consulted. No mutation, no press, no approval, no recovery: neither
        // AXUIElementPerformAction nor AXUIElementSetAttributeValue is invoked anywhere in this
        // capability, and kAXValueAttribute is never read. kAXPlaceholderValueAttribute carries no
        // "required for all elements"-style documentation — most controls, and even most text
        // fields, legitimately lack a placeholder — so genuine absence
        // (kAXErrorNoValue/kAXErrorAttributeUnsupported) is the OPTIONAL-REFERENCE pattern, a
        // valid, expected nil WHOLE RESULT, identical to ui.read_element_help_text's/
        // ui.read_element_value_description's own absence semantics (unlike
        // ui.read_element_role_description's required-attribute, no-valid-absence contract). Every
        // other failure mode (permission denial, unresolvable target, stale target, a genuine
        // AXError, a non-CFStringRef returned value, or a string exceeding the defensive length
        // bound) fails closed with its own dedicated diagnostic; nothing is ever silently defaulted
        // or truncated. Bounded to exactly 1 resolved target, 0 relationship hops, 1
        // kAXPlaceholderValueAttribute read, 0 traversal, 0 actions, 0 polling, 0 retries. See
        // QBridgeAccessibility.readElementPlaceholderValue and
        // docs/PHASE_2CD_SEMANTIC_PLACEHOLDER_VALUE.md for the full contract.
        "ui.read_element_placeholder_value": ("ui", .level0ReadOnly),
        // Phase 2CE: `ui.read_element_expanded_state` reads a semantically-identified element's
        // kAXExpandedAttribute — whether a disclosure triangle, popup button, combo box, or menu
        // button is currently expanded/open, letting an agent check state before deciding to act
        // (e.g. before calling ui.toggle_disclosure) rather than guessing or unconditionally
        // toggling. Distinct from ui.toggle_disclosure's own current-state check, which reads
        // kAXValueAttribute (AXDisclosureTriangle's own 0/1 convention) — this capability reads a
        // different attribute and, unlike ui.toggle_disclosure, is not restricted to
        // AXDisclosureTriangle. Reuses QAXElementReadRolePolicy and its AXSecureTextField
        // exclusion completely unmodified from every prior read capability in this family — no
        // broader, arbitrary-role allowlist is introduced, and AXSecureTextField is rejected
        // before the general allowlist is ever consulted. No mutation, no press, no approval, no
        // recovery: neither AXUIElementPerformAction nor AXUIElementSetAttributeValue is invoked
        // anywhere in this capability, and kAXValueAttribute is never read. kAXExpandedAttribute
        // carries no "required for all elements"-style documentation — most controls have no
        // expanded/collapsed concept at all — so genuine absence
        // (kAXErrorNoValue/kAXErrorAttributeUnsupported) is the OPTIONAL-REFERENCE pattern, a
        // valid, expected nil result, identical to ui.read_element_required_state's own absence
        // semantics (unlike ui.read_element_role_description's required-attribute, no-valid-
        // absence contract). Every other failure mode (permission denial, unresolvable target,
        // stale target, a genuine AXError, a non-Boolean returned value) fails closed with its own
        // dedicated diagnostic; nothing is ever silently defaulted. Bounded to exactly 1 resolved
        // target, 0 relationship hops, 1 kAXExpandedAttribute read, 0 traversal, 0 actions, 0
        // polling, 0 retries. See QBridgeAccessibility.readElementExpandedState and
        // docs/PHASE_2CE_SEMANTIC_EXPANDED_STATE.md for the full contract.
        "ui.read_element_expanded_state": ("ui", .level0ReadOnly),
        // Phase 2CF: `ui.read_element_disclosure_level` reads a semantically-identified outline
        // row's kAXDisclosureLevelAttribute — its nesting depth (0 = top level, 1 = one level
        // nested, and so on), letting an agent understand hierarchical UI structure (Finder's
        // sidebar, Xcode's project navigator, any source list) without recursively walking parent
        // relationships itself. Complements ui.read_element_expanded_state ("is this row currently
        // open") and the existing ui.list_outline_items/ui.select_outline_row capabilities. Reuses
        // QAXOutlineRowRolePolicy (Phase 2T) — the SAME dedicated AXRow role policy
        // ui.select_outline_row already established — completely unmodified; no new, parallel role
        // mechanism is introduced. Deliberately unlike ui.select_outline_row, this read does NOT
        // additionally require the AXOutlineRow subrole or an AXOutline parent context: a MUTATION
        // on the wrong kind of row would be real, silent misbehavior, but a READ of an ordinary
        // AXRow that is not genuinely an outline row simply, honestly reports genuine attribute
        // absence (a valid, expected nil), never a fabricated depth. No mutation, no press, no
        // approval, no recovery: neither AXUIElementPerformAction nor AXUIElementSetAttributeValue
        // is invoked anywhere in this capability, and kAXValueAttribute is never read.
        // kAXDisclosureLevelAttribute carries no "required for all elements"-style documentation —
        // most controls, and even most plain table rows, legitimately lack it — so genuine absence
        // (kAXErrorNoValue/kAXErrorAttributeUnsupported) is the OPTIONAL-REFERENCE pattern, a
        // valid, expected nil result, identical to ui.read_element_expanded_state's/
        // ui.read_element_required_state's own absence semantics. Every other failure mode
        // (permission denial, unresolvable target, stale target, a genuine AXError, a malformed
        // non-integer returned value, or a negative/overflowing integer) fails closed with its own
        // dedicated diagnostic; nothing is ever silently defaulted or truncated. Bounded to exactly
        // 1 resolved target, 0 relationship hops, 1 kAXDisclosureLevelAttribute read, 0 traversal,
        // 0 actions, 0 polling, 0 retries. See QBridgeAccessibility.readElementDisclosureLevel and
        // docs/PHASE_2CF_SEMANTIC_DISCLOSURE_LEVEL.md for the full contract.
        "ui.read_element_disclosure_level": ("ui", .level0ReadOnly),
        // Phase 2CG: `ui.read_element_edited_state` reads a semantically-identified element's
        // kAXEditedAttribute — whether it currently has unsaved changes ("is dirty"), letting an
        // agent decide whether to warn before closing a window/document or discarding
        // in-progress edits, rather than guessing or unconditionally proceeding. Reuses
        // QAXElementReadRolePolicy and its AXSecureTextField exclusion completely unmodified from
        // every prior read capability in this family — no broader, arbitrary-role allowlist is
        // introduced, and AXSecureTextField is rejected before the general allowlist is ever
        // consulted. No mutation, no press, no approval, no recovery: neither
        // AXUIElementPerformAction nor AXUIElementSetAttributeValue is invoked anywhere in this
        // capability, and kAXValueAttribute is never read. kAXEditedAttribute carries no
        // "required for all elements"-style documentation — most controls have no unsaved-changes
        // concept at all — so genuine absence (kAXErrorNoValue/kAXErrorAttributeUnsupported) is
        // the OPTIONAL-REFERENCE pattern, a valid, expected nil result, identical to
        // ui.read_element_expanded_state's/ui.read_element_required_state's own absence
        // semantics. Every other failure mode (permission denial, unresolvable target, stale
        // target, a genuine AXError, a non-Boolean returned value) fails closed with its own
        // dedicated diagnostic; nothing is ever silently defaulted. Bounded to exactly 1 resolved
        // target, 0 relationship hops, 1 kAXEditedAttribute read, 0 traversal, 0 actions, 0
        // polling, 0 retries. See QBridgeAccessibility.readElementEditedState and
        // docs/PHASE_2CG_SEMANTIC_EDITED_STATE.md for the full contract.
        "ui.read_element_edited_state": ("ui", .level0ReadOnly)
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
