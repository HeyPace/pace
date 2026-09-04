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
        "ui.list_level_indicators": ("ui", .level0ReadOnly)
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
