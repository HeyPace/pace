//
//  QActionVerification.swift
//  leanring-buddy
//
//  Q Security Architecture — Closed-Loop Action Verification (Phase 1D.7).
//  Guarantees that state changes are empirically observed and verified
//  before an action is marked as successful.
//

import Foundation
import AppKit

// MARK: - Verification Strategy & Outcome

public enum QVerificationStrategy: Sendable {
    case fileExists(path: String, expectedContent: String? = nil)
    case fileDeleted(path: String)
    case windowOrAppActive(appName: String)
    case appNotRunning(appName: String)
    /// Phase 2H: re-resolves the same semantic target a ui.click_element step just pressed and
    /// diffs its own Accessibility state (identifier/title/enabled) against the pre-click
    /// snapshot. A successful AX press is not itself evidence of goal success — this is the
    /// closed loop that supplies the actual evidence, and it fails (never fabricates) when no
    /// change is observed.
    case axElementStateChanged(
        applicationName: String,
        role: String,
        matchIdentifier: String?,
        matchTitle: String?,
        beforeSnapshot: QAXElementSnapshot
    )
    /// Phase 2I: re-resolves the same semantic target a ui.set_text_value step just wrote to and
    /// confirms its CURRENT value hashes to the intended value's hash — never comparing or
    /// transmitting the plaintext itself. A successful AX write is not itself evidence of goal
    /// success; this is the independent closed-loop check that supplies the real evidence, and
    /// (deliberately, unlike axElementStateChanged) it FAILS rather than assumes success if the
    /// target becomes unresolvable — a text field disappearing after a value write is a more
    /// concerning signal than a button's identity changing after a press.
    case axTextValueChanged(
        applicationName: String,
        role: String,
        matchIdentifier: String?,
        matchTitle: String?,
        targetIdentity: String,
        previousLength: Int,
        previousValueHash: String,
        intendedValueHash: String
    )
    /// Phase 2K: re-resolves the same semantic checkbox/radio-button target a
    /// ui.set_element_state step just pressed (or correctly no-op'd) and confirms its CURRENT
    /// state hashes to the desired state's hash — never comparing or transmitting the raw AX
    /// value itself (only the small "on"/"off" enum and its hash ever exist). A successful press
    /// is not itself evidence of goal success; this is the independent closed-loop check that
    /// supplies the real evidence. Like `axTextValueChanged` (and deliberately unlike
    /// `axElementStateChanged`), an unresolvable target after the change is treated as `.failed`,
    /// not assumed success — a checkbox/radio's identity is not expected to change as a direct
    /// result of being toggled the way some buttons' identity does after a press.
    case axElementStateMatchesDesired(
        applicationName: String,
        role: String,
        matchIdentifier: String?,
        matchTitle: String?,
        targetIdentity: String,
        previousStateHash: String,
        desiredStateHash: String
    )
    /// Phase 2L: re-resolves the same top-level menu bar item and item title a
    /// ui.select_menu_item step just selected and evaluates `QMenuItemSelectionEvidence` — the
    /// item becoming unresolvable (the menu closed) is the expected, benign post-selection
    /// lifecycle and is treated as `.verified`; the item remaining resolvable and unchanged, or
    /// the application/menu-bar-item itself becoming unavailable, is treated as `.failed`. Never
    /// invents a stronger verification claim than AX alone can generically provide — see
    /// `QMenuItemSelectionEvidence`'s own documentation for the full evidence contract.
    case axMenuItemSelectionEvidence(
        applicationName: String,
        menuBarTitle: String,
        itemTitle: String,
        targetIdentity: String
    )
    /// Phase 2M: re-resolves the same semantic slider/stepper target a ui.set_slider_value step
    /// just set (or correctly no-op'd) and confirms its CURRENT value matches `desiredValue`
    /// using the same tolerance rule (`QBridgeAccessibility.sliderValuesAreEqual`) idempotency
    /// used — plain numeric comparison, since a slider's value is not sensitive content. A
    /// successful set is not itself evidence of goal success; this is the independent closed-loop
    /// check that supplies the real evidence. Like `axTextValueChanged`/
    /// `axElementStateMatchesDesired`, an unresolvable target after the change is `.failed`, not
    /// assumed success; an internally-inconsistent post-change range is likewise `.failed`.
    case axSliderValueMatchesDesired(
        applicationName: String,
        role: String,
        matchIdentifier: String?,
        matchTitle: String?,
        targetIdentity: String,
        desiredValue: Double
    )
    /// Phase 2N: re-observes `NSWorkspace.shared.frontmostApplication` independently of whatever
    /// `executeActivateApplication` itself observed (including its own bounded poll) and confirms
    /// it matches the resolved target's stable `processIdentifier` — never `localizedName`, which
    /// a same-named replacement process could otherwise satisfy. A successful `activate()` call
    /// (or an idempotent already-frontmost no-op) is not itself evidence of goal success; this is
    /// the independent closed-loop check that supplies the real evidence, and it fails — never
    /// assumes — if no frontmost application can be observed at all, or if the observed frontmost
    /// application's pid does not match.
    case processIsFrontmost(applicationName: String, targetProcessIdentifier: pid_t)
    /// Phase 2O: re-resolves the same semantic target a ui.focus_element step just focused (or
    /// correctly no-op'd) and independently re-reads `kAXFocusedUIElementAttribute` — a
    /// successful `AXUIElementSetAttributeValue` call is never itself treated as proof of
    /// success; this is the closed-loop check that supplies the real evidence. Like
    /// `axTextValueChanged`/`axElementStateMatchesDesired`/`axSliderValueMatchesDesired`
    /// (and deliberately unlike `axElementStateChanged`'s click-based model), an unresolvable
    /// target after the change is `.failed`, not assumed success — nothing about being focused
    /// should make an element disappear.
    case axElementIsFocused(
        applicationName: String,
        role: String,
        matchIdentifier: String?,
        matchTitle: String?,
        targetIdentity: String
    )
    /// Phase 2P: re-resolves the same semantic `AXPopUpButton` target a ui.select_popup_item
    /// step just selected (or correctly no-op'd) and independently re-reads its OWN
    /// `kAXValueAttribute` — a successful open+select press sequence is never itself treated as
    /// proof of success; this is the closed-loop check that supplies the real evidence. Unlike
    /// `axMenuItemSelectionEvidence`'s indirect "item disappeared" model, a popup's value is
    /// directly comparable, so this compares `currentValue` against `requestedItemTitle` plainly
    /// — the same direct-comparison model `axSliderValueMatchesDesired` already established. Like
    /// `axSliderValueMatchesDesired`/`axElementStateMatchesDesired` (and deliberately unlike
    /// `axElementStateChanged`'s click-based model), an unresolvable target after the change is
    /// `.failed`, not assumed success.
    case axPopupValueMatchesDesired(
        applicationName: String,
        role: String,
        matchIdentifier: String?,
        matchTitle: String?,
        targetIdentity: String,
        requestedItemTitle: String
    )
    /// Phase 2Q: re-resolves the same semantic `AXDisclosureTriangle` target a
    /// ui.toggle_disclosure step just toggled (or correctly no-op'd) and independently re-reads
    /// its `kAXValueAttribute` — a successful press is never itself treated as proof of success;
    /// this is the closed-loop check that supplies the real evidence. Structurally the same
    /// direct-comparison model `axElementStateMatchesDesired`/`axPopupValueMatchesDesired`
    /// already establish. Like those (and deliberately unlike `axElementStateChanged`'s
    /// click-based model), an unresolvable target after the change is `.failed`, not assumed
    /// success; an unreadable/indeterminate state is likewise `.failed`, never defaulted to
    /// either expanded or collapsed.
    case axDisclosureStateMatchesDesired(
        applicationName: String,
        role: String,
        matchIdentifier: String?,
        matchTitle: String?,
        targetIdentity: String,
        desiredState: QAXDisclosureState
    )
    /// Phase 2R: re-resolves the same semantic tab target (`AXRadioButton` + `AXTabButton`
    /// subrole — see `QAXTabRolePolicy`'s documentation for why "AXTab" is not a real role) a
    /// ui.select_tab step just selected (or correctly no-op'd) and independently re-reads its
    /// `kAXSelectedAttribute` — a successful press is never itself treated as proof of success;
    /// this is the closed-loop check that supplies the real evidence. Structurally the same
    /// direct-comparison model `axElementStateMatchesDesired`/`axPopupValueMatchesDesired`/
    /// `axDisclosureStateMatchesDesired` already establish, reading a different (but equally
    /// authoritative) boolean attribute. Like those (and deliberately unlike
    /// `axElementStateChanged`'s click-based model), an unresolvable/ambiguous/no-longer-
    /// subrole-qualified target after the change is `.failed`, not assumed success; an
    /// unreadable selection state is likewise `.failed`, never defaulted to either selected or
    /// not-selected.
    case axTabSelectionMatchesDesired(
        applicationName: String,
        role: String,
        matchIdentifier: String?,
        matchTitle: String?,
        targetIdentity: String,
        desiredSelected: Bool
    )
    /// Phase 2S: re-resolves the same semantic table-row target (`AXRow` + `AXTableRow` subrole +
    /// `AXTable` parent context — see `QAXTableRowRolePolicy`'s documentation) a
    /// ui.select_table_row step just selected (or correctly no-op'd) and independently re-reads
    /// its `kAXSelectedAttribute` — a successful press is never itself treated as proof of
    /// success; this is the closed-loop check that supplies the real evidence. Structurally the
    /// same direct-comparison model `axTabSelectionMatchesDesired` already establishes, reading
    /// the identical attribute. Like it (and deliberately unlike `axElementStateChanged`'s
    /// click-based model), an unresolvable/ambiguous/no-longer-subrole-or-context-qualified
    /// target after the change is `.failed`, not assumed success; an unreadable selection state
    /// is likewise `.failed`, never defaulted to either selected or not-selected. `desiredSelected`
    /// is carried through only for symmetry with `axTabSelectionMatchesDesired` — this
    /// capability's own contract already guarantees it is always `true` before this strategy is
    /// ever constructed.
    case axTableRowSelectionMatchesDesired(
        applicationName: String,
        role: String,
        matchIdentifier: String?,
        matchTitle: String?,
        targetIdentity: String,
        desiredSelected: Bool
    )
    /// Phase 2T: re-resolves the same semantic outline-row target (`AXRow` + `AXOutlineRow`
    /// subrole + `AXOutline` parent context — see `QAXOutlineRowRolePolicy`'s documentation) a
    /// ui.select_outline_row step just selected (or correctly no-op'd) and independently
    /// re-reads its `kAXSelectedAttribute` — a successful press is never itself treated as proof
    /// of success; this is the closed-loop check that supplies the real evidence. Structurally
    /// the same direct-comparison model `axTableRowSelectionMatchesDesired` already establishes,
    /// reading the identical attribute. Like it, an unresolvable/ambiguous/no-longer-subrole-or-
    /// context-qualified target after the change is `.failed`, not assumed success; an unreadable
    /// selection state is likewise `.failed`, never defaulted to either selected or not-selected.
    /// `desiredSelected` is carried through only for symmetry with
    /// `axTableRowSelectionMatchesDesired` — this capability's own contract already guarantees it
    /// is always `true` before this strategy is ever constructed.
    case axOutlineRowSelectionMatchesDesired(
        applicationName: String,
        role: String,
        matchIdentifier: String?,
        matchTitle: String?,
        targetIdentity: String,
        desiredSelected: Bool
    )
    /// Phase 2U: re-resolves the same semantic `AXWindow` target a ui.set_window_minimized step
    /// just mutated (or correctly no-op'd) and independently re-reads its own
    /// `kAXMinimizedAttribute` — a successful attribute-set call is never itself treated as proof
    /// of success; this is the closed-loop check that supplies the real evidence. Unlike every
    /// prior row/tab-selection strategy, `desiredMinimized` is genuinely bidirectional here — both
    /// `true` and `false` are valid, fully-verified target states, not carried through merely for
    /// structural symmetry. An unresolvable/ambiguous target after the change is `.failed`, not
    /// assumed success — a window's disappearance after a minimize/restore request is never
    /// automatically interpreted as success; an unreadable minimized state is likewise `.failed`,
    /// never defaulted to either minimized or not-minimized.
    case axWindowMinimizedStateMatchesDesired(
        applicationName: String,
        role: String,
        matchIdentifier: String?,
        matchTitle: String?,
        targetIdentity: String,
        desiredMinimized: Bool
    )
    /// Phase 2AS: re-resolves the same semantic `AXWindow` target a ui.set_window_full_screen step
    /// just mutated (or correctly no-op'd) and independently re-reads its own
    /// `kAXFullScreenAttribute` ("AXFullScreen") — a successful attribute-set call is never itself
    /// treated as proof of success; this is the closed-loop check that supplies the real evidence.
    /// `desiredFullScreen` is genuinely bidirectional — both `true` and `false` are valid,
    /// fully-verified target states. An unresolvable/ambiguous target after the change is `.failed`,
    /// not assumed success; an unreadable full-screen state is likewise `.failed`, never defaulted.
    case axWindowFullScreenMatchesDesired(
        applicationName: String,
        role: String,
        matchIdentifier: String?,
        matchTitle: String?,
        targetIdentity: String,
        desiredFullScreen: Bool
    )
    /// Phase 2V: re-resolves the same running application (by stable `processIdentifier`, never
    /// `localizedName`, which a same-named replacement process could otherwise satisfy) a
    /// ui.set_application_hidden step just mutated (or correctly no-op'd) and independently
    /// re-reads its own `NSRunningApplication.isHidden` — a successful `hide()`/`unhide()` call is
    /// never itself treated as proof of success; this is the closed-loop check that supplies the
    /// real evidence. Structurally the same direct-comparison, pid-anchored model
    /// `.processIsFrontmost` (Phase 2N) already establishes for the identical application-level
    /// resolution class — never `AXUIElement`, never gated on `AXIsProcessTrusted()`. Like
    /// `axWindowMinimizedStateMatchesDesired`, `desiredHidden` is genuinely bidirectional — both
    /// `true` and `false` are valid, fully-verified target states. If the target process can no
    /// longer be found by its resolved pid (the application quit), this is `.failed`, not assumed
    /// success — a process disappearing after a hide/unhide request is never automatically
    /// interpreted as success.
    case applicationHiddenStateMatchesDesired(
        applicationName: String,
        targetProcessIdentifier: pid_t,
        desiredHidden: Bool
    )
    /// Phase 2W: re-resolves the ENTIRE semantic identity chain a `ui.set_scroll_position` step
    /// just mutated (or correctly no-op'd) — the `AXScrollArea`, then the orientation
    /// convenience-reference, then the scroll bar's own role — fresh, and independently re-reads
    /// its `kAXValueAttribute`, comparing it against `desiredValue` using the identical
    /// `sliderValuesAreEqual` tolerance rule `axSliderValueMatchesDesired` already established. A
    /// successful attribute-set call is never itself treated as proof of success. An
    /// unresolvable/misqualified target anywhere in the chain, or an internally-inconsistent
    /// post-change range, is `.failed`, never assumed successful.
    case scrollPositionMatchesDesired(
        applicationName: String,
        role: String,
        matchIdentifier: String?,
        matchTitle: String?,
        orientation: String,
        targetIdentity: String,
        desiredValue: Double
    )
    /// Phase 2AU: re-resolves the target splitter within its split group in a named application window,
    /// independently re-reads its kAXValueAttribute, and compares it against desiredPosition within tolerance.
    case splitterPositionMatchesDesired(
        applicationName: String,
        windowTitle: String?,
        windowIdentifier: String?,
        splitGroupIdentifier: String?,
        splitGroupTitle: String?,
        splitterIndex: Int,
        desiredPosition: Double,
        tolerance: Double,
        targetIdentity: String
    )
    /// Phase 2X: re-resolves the same semantic `AXWindow` target a ui.set_window_main step just
    /// mutated (or correctly no-op'd) and independently re-reads its own `kAXMainAttribute` — a
    /// successful attribute-set call is never itself treated as proof of success. This strategy
    /// makes NO claim about activation, focus, raise, or any visual/ordering effect — it compares
    /// only `kAXMainAttribute`'s own observed value against `true` (this capability's contract
    /// already guarantees the desired state is always `true` before this strategy is ever
    /// constructed — select-only, by direct analogy to `axTabSelectionMatchesDesired`). An
    /// unresolvable/ambiguous target after the change is `.failed`, not assumed success — a
    /// window's disappearance after a set-main request is never automatically interpreted as
    /// success; an unreadable main state is likewise `.failed`, never defaulted.
    case windowMainStateMatchesDesired(
        applicationName: String,
        role: String,
        matchIdentifier: String?,
        matchTitle: String?,
        targetIdentity: String
    )
    /// Phase 2Y (`ui.close_window`, Level 3): ABSENCE-based verification — a first for this
    /// codebase. Independently re-resolves the OWNING APPLICATION first (a fresh, separate
    /// `NSRunningApplication` lookup), then independently re-resolves the exact original window
    /// identity. `.verified` ONLY when the application is confirmed still running AND the exact
    /// window no longer resolves — application termination is NEVER credited as a successful
    /// window close (a categorically different outcome), and an ambiguous or unobservable
    /// (permission-denied) result is NEVER folded into "absent." A close-button press's own
    /// `AXError` return value is never itself treated as proof — this strategy is the sole source
    /// of truth.
    case windowCloseVerified(
        applicationName: String,
        role: String,
        matchIdentifier: String?,
        matchTitle: String?,
        targetIdentity: String
    )
    /// Phase 2Z (`ui.list_windows`, Level 0): read-only verification. Unlike every mutation
    /// capability's verification — which exists specifically to independently re-observe a real
    /// side effect, never trusting the mutation call's own return value — a stateless enumeration
    /// has no separate physical state to re-observe after the fact: the read's own success/
    /// failure, established entirely inside `QBridgeAccessibility.listWindows` (exact application
    /// resolution, a successfully-read and well-formed windows collection, per-element role
    /// validation), already IS the ground truth. This strategy deliberately checks the execution
    /// result's own `success` flag as a genuine, meaningful assertion — never a bare `{ true }`
    /// bypass — so a step that somehow reached verification without a successful read is still
    /// correctly reported `.failed`. Its evidence string carries only the application name and a
    /// window COUNT, never any individual window's title/identifier — consistent with this
    /// capability's own privacy contract that per-window content never crosses into persisted
    /// evidence text.
    case windowEnumerationSucceeded(applicationName: String, windowCount: Int)
    /// Phase 2AA: semantic menu enumeration verification (Level 0, read-only). Success requires
    /// the execution result's own `success` flag to be true. Evidence string carries aggregate counts
    /// only, never any individual menu/item title or identifier.
    case menuEnumerationSucceeded(applicationName: String, menuCount: Int, itemCount: Int)
    /// Phase 2AD: semantic pop-up menu item enumeration verification (Level 0, read-only). Success requires
    /// the execution result's own `success` flag to be true. Evidence string carries aggregate counts
    /// only, never any individual popup item title or identifier.
    case popupEnumerationSucceeded(applicationName: String, itemCount: Int)
    /// Phase 2AE: semantic table row enumeration verification (Level 0, read-only). Success requires
    /// the execution result's own `success` flag to be true. Evidence string carries aggregate counts
    /// only, never any individual row title or identifier.
    case tableRowEnumerationSucceeded(applicationName: String, rowCount: Int, selectedCount: Int)
    /// Phase 2AF: semantic outline item enumeration verification (Level 0, read-only). Success requires
    /// the execution result's own `success` flag to be true. Evidence string carries aggregate counts
    /// only, never any individual outline item title or identifier.
    case outlineItemEnumerationSucceeded(applicationName: String, itemCount: Int, selectedCount: Int, expandedCount: Int)
    /// Phase 2AH: semantic tab item enumeration verification (Level 0, read-only). Success requires
    /// the execution result's own `success` flag to be true. Evidence string carries aggregate counts
    /// only, never any individual tab item title or identifier.
    case tabItemEnumerationSucceeded(applicationName: String, tabCount: Int, selectedCount: Int)
    /// Phase 2AI: semantic radio group item enumeration verification (Level 0, read-only). Success requires
    /// the execution result's own `success` flag to be true. Evidence string carries aggregate counts
    /// only, never any individual radio option title or identifier.
    case radioGroupEnumerationSucceeded(applicationName: String, itemCount: Int, selectedCount: Int)
    /// Phase 2AK: semantic toolbar item enumeration verification (Level 0, read-only). Success requires
    /// the execution result's own `success` flag to be true. Evidence string carries aggregate counts
    /// only, never any individual toolbar button title or identifier.
    case toolbarItemEnumerationSucceeded(applicationName: String, itemCount: Int)
    /// Phase 2AT: semantic split pane enumeration verification (Level 0, read-only). Success requires
    /// the execution result's own `success` flag to be true. Evidence string carries aggregate counts
    /// only, never any individual pane title or identifier.
    case splitPaneEnumerationSucceeded(applicationName: String, paneCount: Int)
    /// Phase 2AV: semantic multi-column browser enumeration verification (Level 0, read-only). Success requires
    /// the execution result's own `success` flag to be true. Evidence string carries aggregate counts
    /// only, never any individual column title or identifier.
    case browserColumnEnumerationSucceeded(applicationName: String, columnCount: Int)
    /// Phase 2AW: semantic popover container enumeration verification (Level 0, read-only). Success requires
    /// the execution result's own `success` flag to be true. Evidence string carries aggregate counts
    /// only, never any individual popover title or identifier.
    case popoverEnumerationSucceeded(applicationName: String, popoverCount: Int)
    /// Phase 2AX: semantic color well enumeration verification (Level 0, read-only). Success requires
    /// the execution result's own `success` flag to be true. Evidence string carries aggregate counts
    /// only, never any individual color value, title, or identifier.
    case colorWellEnumerationSucceeded(applicationName: String, colorWellCount: Int)
    /// Phase 2AY: semantic progress indicator enumeration verification (Level 0, read-only). Success requires
    /// the execution result's own `success` flag to be true. Evidence string carries aggregate counts
    /// only, never any individual value, title, or identifier.
    case progressIndicatorEnumerationSucceeded(applicationName: String, indicatorCount: Int)
    /// Phase 2AZ: semantic level indicator enumeration verification (Level 0, read-only). Success requires
    /// the execution result's own `success` flag to be true. Evidence string carries aggregate counts
    /// only, never any individual value, title, or identifier.
    case levelIndicatorEnumerationSucceeded(applicationName: String, indicatorCount: Int)
    /// Phase 2BA: semantic stepper / incrementor enumeration verification (Level 0, read-only). Success requires
    /// the execution result's own `success` flag to be true. Evidence string carries aggregate counts
    /// only, never any individual value, title, or identifier.
    case incrementorEnumerationSucceeded(applicationName: String, incrementorCount: Int)
    /// Phase 2BB: semantic combo box enumeration verification (Level 0, read-only). Success requires
    /// the execution result's own `success` flag to be true. Evidence string carries aggregate counts
    /// only, never any individual value, title, or identifier.
    case comboBoxEnumerationSucceeded(applicationName: String, comboBoxCount: Int)
    /// Phase 2BC: semantic ruler enumeration verification (Level 0, read-only). Success requires
    /// the execution result's own `success` flag to be true. Evidence string carries aggregate counts
    /// only, never any individual value, title, or identifier.
    case rulerEnumerationSucceeded(applicationName: String, rulerCount: Int)
    /// Phase 2BD: semantic combo box item enumeration verification (Level 0, read-only). Success requires
    /// the execution result's own `success` flag to be true. Evidence string carries aggregate counts
    /// only, never any individual item title or value.
    case comboBoxItemEnumerationSucceeded(applicationName: String, itemCount: Int)
    /// Phase 2AM: semantic segmented control item enumeration verification (Level 0, read-only). Success requires
    /// the execution result's own `success` flag to be true. Evidence string carries aggregate counts
    /// only, never any individual segment title or identifier.
    case segmentedControlEnumerationSucceeded(applicationName: String, itemCount: Int, selectedCount: Int)
    /// Phase 2AN: semantic sheet dialog enumeration verification (Level 0, read-only). Success requires
    /// the execution result's own `success` flag to be true. Evidence string carries aggregate counts
    /// only, never any individual sheet title or identifier.
    case sheetEnumerationSucceeded(applicationName: String, sheetCount: Int)
    /// Phase 2AO: semantic sheet action control enumeration verification (Level 0, read-only). Success requires
    /// the execution result's own `success` flag to be true. Evidence string carries aggregate counts
    /// only, never any individual action control title or identifier.
    case sheetActionEnumerationSucceeded(applicationName: String, actionCount: Int)
    /// Phase 2AQ: semantic segmented control item selection verification (Level 2). Re-resolves target
    /// and verifies post-mutation selection state independently.
    case axSegmentedControlSelectionMatchesDesired(
        applicationName: String,
        role: String,
        controlIdentifier: String?,
        controlTitle: String?,
        windowTitle: String?,
        windowIdentifier: String?,
        segmentIdentifier: String?,
        segmentTitle: String?,
        targetIdentity: String,
        desiredSelected: Bool
    )
    /// Phase 2BE: semantic combo box item selection verification (Level 2). Re-resolves target
    /// and verifies post-mutation value independently.
    case axComboBoxValueMatchesDesired(
        applicationName: String,
        role: String,
        matchIdentifier: String?,
        matchTitle: String?,
        targetIdentity: String,
        requestedItemTitle: String
    )
    /// Phase 2BF: semantic stepper / incrementor step mutation verification (Level 2). Re-resolves
    /// the target `AXIncrementor` independently and re-reads its own `kAXValueAttribute` fresh — the
    /// dispatch call's own `AXError` return is never itself treated as proof of a real side effect.
    /// `.verified` requires the freshly observed value to have moved strictly in the requested
    /// `direction` relative to `previousValue` (the value captured immediately before mutation), or,
    /// for the already-at-bound no-op path (`changeKind: .alreadyAtBound`), to be unchanged.
    case axIncrementorValueMovedAsDesired(
        applicationName: String,
        role: String,
        matchIdentifier: String?,
        matchTitle: String?,
        targetIdentity: String,
        direction: QAXIncrementorStepDirection,
        previousValue: Double,
        changeKind: QAXIncrementorStepChangeKind
    )
    /// Phase 2BG: semantic focused-element read verification (Level 0, read-only). Like every
    /// other Level 0 enumeration's verification, there is no separate physical state to
    /// re-observe after the fact — the read's own success/failure, established entirely inside
    /// `QBridgeAccessibility.readFocusedElement` (exact application resolution, cross-app PID
    /// match, a successfully-read focused element), already IS the ground truth. This strategy
    /// deliberately checks the execution result's own `success` flag as a genuine, meaningful
    /// assertion — never a bare `{ true }` bypass. Evidence carries only the resolved role and
    /// whether a value was exposed, never the value itself, the identifier, or any other
    /// individual field content.
    case focusedElementReadSucceeded(applicationName: String, role: String, hasValue: Bool)
    /// Phase 2BH: semantic application state read verification (Level 0, read-only). Like every
    /// other Level 0 read's verification, there is no separate physical state to re-observe after
    /// the fact — the read's own success/failure, established entirely inside
    /// `QBridgeAccessibility.readApplicationState` (exact application resolution, a successfully
    /// read hidden/frontmost boolean pair), already IS the ground truth. This strategy checks the
    /// execution result's own `success` flag as a genuine, meaningful assertion — never a bare
    /// `{ true }` bypass. Evidence carries only the application name, never the booleans or window
    /// titles themselves.
    case applicationStateReadSucceeded(applicationName: String)
    /// Phase 2BI: semantic table column enumeration verification (Level 0, read-only). Like every
    /// other Level 0 enumeration's verification, there is no separate physical state to
    /// re-observe after the fact — the read's own success/failure, established entirely inside
    /// `QBridgeAccessibility.listTableColumns` (exact application/table resolution, a
    /// successfully-read and well-formed column collection), already IS the ground truth. This
    /// strategy deliberately checks the execution result's own `success` flag as a genuine,
    /// meaningful assertion — never a bare `{ true }` bypass. Evidence carries only the
    /// application name and a column COUNT, never any individual column's title/identifier —
    /// consistent with `ui.list_table_rows`'/`ui.list_browser_columns`' own privacy contract that
    /// per-item content never crosses into persisted evidence text.
    case tableColumnEnumerationSucceeded(applicationName: String, columnCount: Int)
    /// Phase 2BJ: semantic element range read verification (Level 0, read-only). Like every other
    /// Level 0 read's verification, there is no separate physical state to re-observe after the
    /// fact — the read's own success/failure, established entirely inside
    /// `QBridgeAccessibility.readElementRange` (exact application/target resolution, a
    /// successfully-read and internally-consistent numeric range), already IS the ground truth.
    /// This strategy checks the execution result's own `success` flag as a genuine, meaningful
    /// assertion — never a bare `{ true }` bypass. Evidence carries only the application name and
    /// role, never the numeric bounds themselves.
    case elementRangeReadSucceeded(applicationName: String, role: String)
    /// Phase 2BK: semantic element action enumeration verification (Level 0, read-only). Like
    /// every other Level 0 read's verification, there is no separate physical state to
    /// re-observe after the fact — the read's own success/failure, established entirely inside
    /// `QBridgeAccessibility.listElementActions` (exact application/target resolution, a
    /// successfully-read and well-formed, bounded action-names collection), already IS the
    /// ground truth. This strategy checks the execution result's own `success` flag as a genuine,
    /// meaningful assertion — never a bare `{ true }` bypass, and never executes any discovered
    /// action as part of verifying the read. Evidence carries only the application name, role,
    /// and an aggregate action COUNT — never any individual action-name string, consistent with
    /// this capability's own privacy contract that per-action content never crosses into
    /// persisted evidence text.
    case elementActionsReadSucceeded(applicationName: String, role: String, actionCount: Int)
    /// Phase 2BL: semantic element attribute-name enumeration verification (Level 0, read-only).
    /// Like every other Level 0 read's verification, there is no separate physical state to
    /// re-observe after the fact — the read's own success/failure, established entirely inside
    /// `QBridgeAccessibility.listElementAttributes` (exact application/target resolution, a
    /// successfully-read and well-formed, bounded attribute-names collection), already IS the
    /// ground truth. This strategy checks the execution result's own `success` flag as a
    /// genuine, meaningful assertion — never a bare `{ true }` bypass — and independently
    /// re-validates the attribute count against the permitted bound rather than blindly trusting
    /// the dispatch layer. It never reads any attribute's actual value and never mutates
    /// anything. Evidence carries only the application name, role, and an aggregate attribute
    /// COUNT — never any individual attribute-name string.
    case elementAttributeNamesReadSucceeded(applicationName: String, role: String, attributeCount: Int)
    case customCheck(description: String, check: @Sendable () async -> Bool)
}

public enum QVerificationOutcome: Equatable, Sendable {
    case verified(evidence: String)
    case failed(reason: String, evidence: String)

    public var isVerified: Bool {
        if case .verified = self { return true }
        return false
    }
}

// MARK: - Closed-Loop Action Verifier

public final class QActionVerifier: Sendable {
    public static let shared = QActionVerifier()

    public func verify(
        action: QActionRequest,
        result: QActionResult,
        strategy: QVerificationStrategy
    ) async -> QVerificationOutcome {
        // If execution result already failed, verification confirms failure
        guard result.success else {
            return .failed(
                reason: "Action execution returned error: \(result.error ?? "unknown")",
                evidence: "Execution failed prior to post-observation."
            )
        }

        switch strategy {
        case .fileExists(let path, let expectedContent):
            let stdPath = (path as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: stdPath) else {
                return .failed(
                    reason: "Verification failed: file '\(path)' does not exist on disk.",
                    evidence: "stat(\(path)) returned ENOENT"
                )
            }

            if let expectedContent {
                let actual = (try? String(contentsOfFile: stdPath, encoding: .utf8)) ?? ""
                if actual == expectedContent || actual.contains(expectedContent) {
                    return .verified(evidence: "File '\(path)' exists and content matches expected value (\(actual.count) chars).")
                } else {
                    return .failed(
                        reason: "Verification failed: file content mismatch in '\(path)'.",
                        evidence: "Expected '\(expectedContent)', found '\(actual.prefix(80))'"
                    )
                }
            }
            return .verified(evidence: "File '\(path)' exists on filesystem.")

        case .fileDeleted(let path):
            let stdPath = (path as NSString).expandingTildeInPath
            if FileManager.default.fileExists(atPath: stdPath) {
                return .failed(
                    reason: "Verification failed: file '\(path)' still exists.",
                    evidence: "File was observed on disk after deletion attempt."
                )
            }
            return .verified(evidence: "File '\(path)' is confirmed deleted from disk.")

        case .windowOrAppActive(let appName):
            let runningApps = NSWorkspace.shared.runningApplications
            let isRunning = runningApps.contains { app in
                (app.localizedName?.caseInsensitiveCompare(appName) == .orderedSame) ||
                (app.bundleIdentifier?.caseInsensitiveCompare(appName) == .orderedSame)
            }
            if isRunning {
                return .verified(evidence: "Application '\(appName)' verified running in NSWorkspace.")
            } else {
                // In headless tests or if app not launched, return empirical failure
                return .failed(
                    reason: "Application '\(appName)' not found among running applications.",
                    evidence: "NSWorkspace runningApplications query returned negative."
                )
            }

        case .appNotRunning(let appName):
            let runningApps = NSWorkspace.shared.runningApplications
            let stillRunning = runningApps.contains { app in
                (app.localizedName?.caseInsensitiveCompare(appName) == .orderedSame) ||
                (app.bundleIdentifier?.caseInsensitiveCompare(appName) == .orderedSame)
            }
            if stillRunning {
                return .failed(
                    reason: "Application '\(appName)' is still running after a termination request.",
                    evidence: "NSWorkspace runningApplications query returned positive after quit dispatch."
                )
            } else {
                return .verified(evidence: "Application '\(appName)' verified terminated (absent from NSWorkspace runningApplications).")
            }

        case .axElementStateChanged(let applicationName, let role, let matchIdentifier, let matchTitle, let beforeSnapshot):
            guard let afterSnapshot = await QBridgeAccessibility.shared.observeElement(
                applicationName: applicationName,
                role: role,
                identifier: matchIdentifier,
                title: matchTitle
            ) else {
                // The element is no longer uniquely resolvable by the same criteria used to find
                // it before the click — a legitimate, common outcome for a control whose own
                // identity changes when pressed (see docs/PHASE_2H_SEMANTIC_CLICK.md), so this
                // counts as an observed state change, not a failure.
                return .verified(
                    evidence: "Target element (role=\(role)) is no longer resolvable by its pre-click identity after the press — its state visibly changed."
                )
            }
            guard afterSnapshot != beforeSnapshot else {
                return .failed(
                    reason: "No observable Accessibility state change on the target element after the press.",
                    evidence: "role=\(role) identifier=\(afterSnapshot.identifier ?? "none") label=\(afterSnapshot.titleOrDescription ?? "none") enabled=\(afterSnapshot.isEnabled) unchanged before/after."
                )
            }
            return .verified(
                evidence: "Target element (role=\(role)) state changed after press: identifier \(beforeSnapshot.identifier ?? "none") -> \(afterSnapshot.identifier ?? "none"), label \(beforeSnapshot.titleOrDescription ?? "none") -> \(afterSnapshot.titleOrDescription ?? "none")."
            )

        case .axTextValueChanged(let applicationName, let role, let matchIdentifier, let matchTitle, let targetIdentity, let previousLength, let previousValueHash, let intendedValueHash):
            guard let (currentValueHash, currentLength) = await QBridgeAccessibility.shared.observeTextValueHashAndLength(
                applicationName: applicationName,
                role: role,
                identifier: matchIdentifier,
                title: matchTitle
            ) else {
                // Unlike axElementStateChanged, an unresolvable text-entry target after a write
                // is NOT treated as an observed success — a text field disappearing after having
                // its value set is a more concerning signal than a control's identity changing as
                // a direct, expected effect of being pressed. Fail closed rather than assume.
                let evidence = QSafeTextEntryVerificationEvidence(
                    valueChanged: false,
                    previousLength: previousLength,
                    currentLength: 0,
                    targetIdentity: targetIdentity,
                    verificationStatus: .failed
                )
                return .failed(
                    reason: "Target element (role=\(role)) is no longer resolvable for verification after the write.",
                    evidence: evidence.safeEvidenceDescription
                )
            }

            if currentValueHash == intendedValueHash {
                let evidence = QSafeTextEntryVerificationEvidence(
                    valueChanged: currentValueHash != previousValueHash,
                    previousLength: previousLength,
                    currentLength: currentLength,
                    targetIdentity: targetIdentity,
                    verificationStatus: .verified
                )
                return .verified(evidence: evidence.safeEvidenceDescription)
            } else {
                let evidence = QSafeTextEntryVerificationEvidence(
                    valueChanged: currentValueHash != previousValueHash,
                    previousLength: previousLength,
                    currentLength: currentLength,
                    targetIdentity: targetIdentity,
                    verificationStatus: .failed
                )
                return .failed(
                    reason: "Target element (role=\(role)) current value does not match the intended value after the write.",
                    evidence: evidence.safeEvidenceDescription
                )
            }

        case .axElementStateMatchesDesired(let applicationName, let role, let matchIdentifier, let matchTitle, let targetIdentity, let previousStateHash, let desiredStateHash):
            guard let currentStateHash = await QBridgeAccessibility.shared.observeElementStateHash(
                applicationName: applicationName,
                role: role,
                identifier: matchIdentifier,
                title: matchTitle
            ) else {
                return .failed(
                    reason: "Target element (role=\(role)) is no longer resolvable for verification after the state change.",
                    evidence: "target=\(targetIdentity) status=failed"
                )
            }

            if currentStateHash == desiredStateHash {
                return .verified(
                    evidence: "target=\(targetIdentity) stateChanged=\(currentStateHash != previousStateHash) status=verified"
                )
            } else {
                return .failed(
                    reason: "Target element (role=\(role)) current state does not match the desired state after the change.",
                    evidence: "target=\(targetIdentity) status=failed"
                )
            }

        case .axMenuItemSelectionEvidence(let applicationName, let menuBarTitle, let itemTitle, let targetIdentity):
            let evidence = await QBridgeAccessibility.shared.observeMenuItemSelectionEvidence(
                applicationName: applicationName,
                menuBarTitle: menuBarTitle,
                itemTitle: itemTitle
            )
            switch evidence {
            case .itemNoLongerResolvable:
                // The expected, benign post-selection lifecycle — selecting an item closes its
                // menu. This is the strongest generic evidence AX alone can provide for this
                // capability; no stronger claim is made.
                return .verified(evidence: "target=\(targetIdentity) evidenceType=itemDisappeared status=verified")
            case .itemStillResolvable:
                return .failed(
                    reason: "Target menu item (\(itemTitle)) remained resolvable and unchanged after selection — no evidence the selection took effect.",
                    evidence: "target=\(targetIdentity) evidenceType=itemUnchanged status=failed"
                )
            case .applicationOrTargetUnavailable:
                return .failed(
                    reason: "Application or menu bar item (\(menuBarTitle)) became unavailable during verification — physical state is uncertain.",
                    evidence: "target=\(targetIdentity) evidenceType=uncertainLifecycle status=failed"
                )
            }

        case .axSliderValueMatchesDesired(let applicationName, let role, let matchIdentifier, let matchTitle, let targetIdentity, let desiredValue):
            let evidence = await QBridgeAccessibility.shared.observeSliderValueEvidence(
                applicationName: applicationName,
                role: role,
                identifier: matchIdentifier,
                title: matchTitle
            )
            switch evidence {
            case .resolved(let currentValue):
                if QBridgeAccessibility.sliderValuesAreEqual(currentValue, desiredValue) {
                    return .verified(
                        evidence: "target=\(targetIdentity) currentValue=\(currentValue) desiredValue=\(desiredValue) status=verified"
                    )
                } else {
                    return .failed(
                        reason: "Target element (role=\(role)) current value does not match the desired value after the change.",
                        evidence: "target=\(targetIdentity) currentValue=\(currentValue) desiredValue=\(desiredValue) status=failed"
                    )
                }
            case .rangeInvalid(let currentValue):
                return .failed(
                    reason: "Target element (role=\(role)) reported an internally inconsistent range after the change — verification cannot be trusted.",
                    evidence: "target=\(targetIdentity) currentValue=\(currentValue) status=failed"
                )
            case .targetUnavailable:
                return .failed(
                    reason: "Target element (role=\(role)) is no longer resolvable for verification after the change.",
                    evidence: "target=\(targetIdentity) status=failed"
                )
            }

        case .scrollPositionMatchesDesired(let applicationName, let role, let matchIdentifier, let matchTitle, let orientation, let targetIdentity, let desiredValue):
            let evidence = await QBridgeAccessibility.shared.observeScrollPositionEvidence(
                applicationName: applicationName,
                role: role,
                identifier: matchIdentifier,
                title: matchTitle,
                orientation: orientation
            )
            switch evidence {
            case .resolved(let currentValue):
                if QBridgeAccessibility.sliderValuesAreEqual(currentValue, desiredValue) {
                    return .verified(
                        evidence: "target=\(targetIdentity) currentValue=\(currentValue) desiredValue=\(desiredValue) status=verified"
                    )
                } else {
                    return .failed(
                        reason: "Target scroll bar (role=\(role) orientation=\(orientation)) current position does not match the desired position after the change.",
                        evidence: "target=\(targetIdentity) currentValue=\(currentValue) desiredValue=\(desiredValue) status=failed"
                    )
                }
            case .rangeInvalid(let currentValue):
                return .failed(
                    reason: "Target scroll bar (role=\(role) orientation=\(orientation)) reported an internally inconsistent range after the change — verification cannot be trusted.",
                    evidence: "target=\(targetIdentity) currentValue=\(currentValue) status=failed"
                )
            case .targetUnavailable:
                return .failed(
                    reason: "Target scroll bar (role=\(role) orientation=\(orientation)) is no longer resolvable or role-qualified, for verification after the change.",
                    evidence: "target=\(targetIdentity) status=failed"
                )
            }

        case .windowMainStateMatchesDesired(let applicationName, let role, let matchIdentifier, let matchTitle, let targetIdentity):
            let evidence = await QBridgeAccessibility.shared.observeWindowMainEvidence(
                applicationName: applicationName,
                role: role,
                identifier: matchIdentifier,
                title: matchTitle
            )
            switch evidence {
            case .resolved(let currentMain):
                if currentMain {
                    return .verified(
                        evidence: "target=\(targetIdentity) currentMain=\(currentMain) desiredMain=true status=verified"
                    )
                } else {
                    return .failed(
                        reason: "Target window (role=\(role)) is not reporting main=true after the change.",
                        evidence: "target=\(targetIdentity) currentMain=\(currentMain) desiredMain=true status=failed"
                    )
                }
            case .stateUnreadable:
                return .failed(
                    reason: "Target window (role=\(role)) current main state could not be read after the change — unreadable state fails closed.",
                    evidence: "target=\(targetIdentity) status=failed"
                )
            case .targetUnavailable:
                return .failed(
                    reason: "Target window (role=\(role)) is no longer resolvable or is ambiguous, for verification after the change.",
                    evidence: "target=\(targetIdentity) status=failed"
                )
            }

        case .windowCloseVerified(let applicationName, let role, let matchIdentifier, let matchTitle, let targetIdentity):
            let evidence = await QBridgeAccessibility.shared.observeWindowCloseEvidence(
                applicationName: applicationName,
                role: role,
                identifier: matchIdentifier,
                title: matchTitle
            )
            switch evidence {
            case .windowAbsentApplicationRunning:
                return .verified(
                    evidence: "target=\(targetIdentity) applicationRunning=true windowResolvable=false status=verified"
                )
            case .windowStillPresent:
                return .failed(
                    reason: "Target window (role=\(role)) still resolves after the close request — the close did not take effect (or a save/discard sheet is blocking it).",
                    evidence: "target=\(targetIdentity) applicationRunning=true windowResolvable=true status=failed"
                )
            case .ambiguousTarget(let count):
                return .failed(
                    reason: "Target window criteria (role=\(role)) now match \(count) elements after the close request — physical state is uncertain, never assumed absent.",
                    evidence: "target=\(targetIdentity) status=failed"
                )
            case .applicationNotRunning:
                return .failed(
                    reason: "Owning application '\(applicationName)' is no longer running — application termination is never credited as a successful window close.",
                    evidence: "target=\(targetIdentity) applicationRunning=false status=failed"
                )
            case .permissionUnavailable:
                return .failed(
                    reason: "Accessibility permission is unavailable — target window state could not be observed after the close request.",
                    evidence: "target=\(targetIdentity) status=failed"
                )
            }

        case .windowEnumerationSucceeded(let applicationName, let windowCount):
            if result.success {
                return .verified(
                    evidence: "application=\(applicationName) windowCount=\(windowCount) status=verified"
                )
            } else {
                return .failed(
                    reason: "Window enumeration for application '\(applicationName)' did not succeed.",
                    evidence: "application=\(applicationName) status=failed"
                )
            }

        case .menuEnumerationSucceeded(let applicationName, let menuCount, let itemCount):
            if result.success {
                return .verified(
                    evidence: "application=\(applicationName) menuCount=\(menuCount) itemCount=\(itemCount) status=verified"
                )
            } else {
                return .failed(
                    reason: "Menu enumeration for application '\(applicationName)' did not succeed.",
                    evidence: "application=\(applicationName) status=failed"
                )
            }

        case .popupEnumerationSucceeded(let applicationName, let itemCount):
            if result.success {
                return .verified(
                    evidence: "application=\(applicationName) popupRole=AXPopUpButton itemCount=\(itemCount) status=verified"
                )
            } else {
                return .failed(
                    reason: "Pop-up menu item enumeration for application '\(applicationName)' did not succeed.",
                    evidence: "application=\(applicationName) popupRole=AXPopUpButton status=failed"
                )
            }

        case .tableRowEnumerationSucceeded(let applicationName, let rowCount, let selectedCount):
            if result.success {
                return .verified(
                    evidence: "application=\(applicationName) tableRole=AXTable rowCount=\(rowCount) selectedCount=\(selectedCount) status=verified"
                )
            } else {
                return .failed(
                    reason: "Table row enumeration for application '\(applicationName)' did not succeed.",
                    evidence: "application=\(applicationName) tableRole=AXTable status=failed"
                )
            }

        case .outlineItemEnumerationSucceeded(let applicationName, let itemCount, let selectedCount, let expandedCount):
            if result.success {
                return .verified(
                    evidence: "application=\(applicationName) outlineRole=AXOutline itemCount=\(itemCount) selectedCount=\(selectedCount) expandedCount=\(expandedCount) status=verified"
                )
            } else {
                return .failed(
                    reason: "Outline item enumeration for application '\(applicationName)' did not succeed.",
                    evidence: "application=\(applicationName) outlineRole=AXOutline status=failed"
                )
            }

        case .tabItemEnumerationSucceeded(let applicationName, let tabCount, let selectedCount):
            if result.success {
                return .verified(
                    evidence: "application=\(applicationName) tabGroupRole=AXTabGroup tabCount=\(tabCount) selectedCount=\(selectedCount) status=verified"
                )
            } else {
                return .failed(
                    reason: "Tab item enumeration for application '\(applicationName)' did not succeed.",
                    evidence: "application=\(applicationName) tabGroupRole=AXTabGroup status=failed"
                )
            }

        case .radioGroupEnumerationSucceeded(let applicationName, let itemCount, let selectedCount):
            if result.success {
                return .verified(
                    evidence: "application=\(applicationName) radioGroupRole=AXRadioGroup itemCount=\(itemCount) selectedCount=\(selectedCount) status=verified"
                )
            } else {
                return .failed(
                    reason: "Radio group item enumeration for application '\(applicationName)' did not succeed.",
                    evidence: "application=\(applicationName) radioGroupRole=AXRadioGroup status=failed"
                )
            }

        case .toolbarItemEnumerationSucceeded(let applicationName, let itemCount):
            if result.success {
                return .verified(
                    evidence: "application=\(applicationName) toolbarRole=AXToolbar itemCount=\(itemCount) status=verified"
                )
            } else {
                return .failed(
                    reason: "Toolbar item enumeration for application '\(applicationName)' did not succeed.",
                    evidence: "application=\(applicationName) toolbarRole=AXToolbar status=failed"
                )
            }

        case .splitPaneEnumerationSucceeded(let applicationName, let paneCount):
            if result.success {
                return .verified(
                    evidence: "application=\(applicationName) splitGroupRole=AXSplitGroup paneCount=\(paneCount) status=verified"
                )
            } else {
                return .failed(
                    reason: "Split pane enumeration for application '\(applicationName)' did not succeed.",
                    evidence: "application=\(applicationName) splitGroupRole=AXSplitGroup status=failed"
                )
            }

        case .browserColumnEnumerationSucceeded(let applicationName, let columnCount):
            if result.success {
                return .verified(
                    evidence: "application=\(applicationName) browserRole=AXBrowser columnCount=\(columnCount) status=verified"
                )
            } else {
                return .failed(
                    reason: "Browser column enumeration for application '\(applicationName)' did not succeed.",
                    evidence: "application=\(applicationName) browserRole=AXBrowser status=failed"
                )
            }

        case .popoverEnumerationSucceeded(let applicationName, let popoverCount):
            if result.success {
                return .verified(
                    evidence: "application=\(applicationName) popoverRole=AXPopover popoverCount=\(popoverCount) status=verified"
                )
            } else {
                return .failed(
                    reason: "Popover enumeration for application '\(applicationName)' did not succeed.",
                    evidence: "application=\(applicationName) popoverRole=AXPopover status=failed"
                )
            }

        case .colorWellEnumerationSucceeded(let applicationName, let colorWellCount):
            if result.success {
                return .verified(
                    evidence: "application=\(applicationName) colorWellRole=AXColorWell colorWellCount=\(colorWellCount) status=verified"
                )
            } else {
                return .failed(
                    reason: "Color well enumeration for application '\(applicationName)' did not succeed.",
                    evidence: "application=\(applicationName) colorWellRole=AXColorWell status=failed"
                )
            }

        case .progressIndicatorEnumerationSucceeded(let applicationName, let indicatorCount):
            if result.success {
                return .verified(
                    evidence: "application=\(applicationName) indicatorRole=AXProgressIndicator indicatorCount=\(indicatorCount) status=verified"
                )
            } else {
                return .failed(
                    reason: "Progress indicator enumeration for application '\(applicationName)' did not succeed.",
                    evidence: "application=\(applicationName) indicatorRole=AXProgressIndicator status=failed"
                )
            }

        case .levelIndicatorEnumerationSucceeded(let applicationName, let indicatorCount):
            if result.success {
                return .verified(
                    evidence: "application=\(applicationName) indicatorRole=AXLevelIndicator indicatorCount=\(indicatorCount) status=verified"
                )
            } else {
                return .failed(
                    reason: "Level indicator enumeration for application '\(applicationName)' did not succeed.",
                    evidence: "application=\(applicationName) indicatorRole=AXLevelIndicator status=failed"
                )
            }

        case .incrementorEnumerationSucceeded(let applicationName, let incrementorCount):
            if result.success {
                return .verified(
                    evidence: "application=\(applicationName) incrementorRole=AXIncrementor incrementorCount=\(incrementorCount) status=verified"
                )
            } else {
                return .failed(
                    reason: "Incrementor enumeration for application '\(applicationName)' did not succeed.",
                    evidence: "application=\(applicationName) incrementorRole=AXIncrementor status=failed"
                )
            }

        case .comboBoxEnumerationSucceeded(let applicationName, let comboBoxCount):
            if result.success {
                return .verified(
                    evidence: "application=\(applicationName) comboBoxRole=AXComboBox comboBoxCount=\(comboBoxCount) status=verified"
                )
            } else {
                return .failed(
                    reason: "Combo box enumeration for application '\(applicationName)' did not succeed.",
                    evidence: "application=\(applicationName) comboBoxRole=AXComboBox status=failed"
                )
            }

        case .rulerEnumerationSucceeded(let applicationName, let rulerCount):
            if result.success {
                return .verified(
                    evidence: "application=\(applicationName) rulerRole=AXRuler rulerCount=\(rulerCount) status=verified"
                )
            } else {
                return .failed(
                    reason: "Ruler enumeration for application '\(applicationName)' did not succeed.",
                    evidence: "application=\(applicationName) rulerRole=AXRuler status=failed"
                )
            }

        case .comboBoxItemEnumerationSucceeded(let applicationName, let itemCount):
            if result.success {
                return .verified(
                    evidence: "application=\(applicationName) comboBoxRole=AXComboBox itemCount=\(itemCount) status=verified"
                )
            } else {
                return .failed(
                    reason: "Combo box item enumeration for application '\(applicationName)' did not succeed.",
                    evidence: "application=\(applicationName) comboBoxRole=AXComboBox status=failed"
                )
            }

        case .segmentedControlEnumerationSucceeded(let applicationName, let itemCount, let selectedCount):
            if result.success {
                return .verified(
                    evidence: "application=\(applicationName) segmentedControlRole=AXSegmentedControl itemCount=\(itemCount) selectedCount=\(selectedCount) status=verified"
                )
            } else {
                return .failed(
                    reason: "Segmented control item enumeration for application '\(applicationName)' did not succeed.",
                    evidence: "application=\(applicationName) segmentedControlRole=AXSegmentedControl status=failed"
                )
            }

        case .sheetEnumerationSucceeded(let applicationName, let sheetCount):
            if result.success {
                return .verified(
                    evidence: "application=\(applicationName) sheetRole=AXSheet sheetCount=\(sheetCount) status=verified"
                )
            } else {
                return .failed(
                    reason: "Sheet dialog enumeration for application '\(applicationName)' did not succeed.",
                    evidence: "application=\(applicationName) sheetRole=AXSheet status=failed"
                )
            }

        case .sheetActionEnumerationSucceeded(let applicationName, let actionCount):
            if result.success {
                return .verified(
                    evidence: "application=\(applicationName) sheetActionRole=AXSheetAction actionCount=\(actionCount) status=verified"
                )
            } else {
                return .failed(
                    reason: "Sheet action enumeration for application '\(applicationName)' did not succeed.",
                    evidence: "application=\(applicationName) sheetActionRole=AXSheetAction status=failed"
                )
            }

        case .processIsFrontmost(let applicationName, let targetProcessIdentifier):
            guard let frontmost = NSWorkspace.shared.frontmostApplication else {
                return .failed(
                    reason: "No frontmost application could be observed after activating '\(applicationName)'.",
                    evidence: "NSWorkspace.shared.frontmostApplication returned nil."
                )
            }
            if frontmost.processIdentifier == targetProcessIdentifier {
                return .verified(
                    evidence: "target=\(applicationName) pid=\(targetProcessIdentifier) status=verified frontmost=true"
                )
            } else {
                return .failed(
                    reason: "Application '\(applicationName)' is not the frontmost application after activation.",
                    evidence: "target=\(applicationName) expectedPid=\(targetProcessIdentifier) actualFrontmostPid=\(frontmost.processIdentifier) actualFrontmostName=\(frontmost.localizedName ?? "unknown") status=failed"
                )
            }

        case .axElementIsFocused(let applicationName, let role, let matchIdentifier, let matchTitle, let targetIdentity):
            let evidence = await QBridgeAccessibility.shared.observeFocusedElementIdentity(
                applicationName: applicationName,
                role: role,
                identifier: matchIdentifier,
                title: matchTitle
            )
            switch evidence {
            case .focused:
                return .verified(
                    evidence: "target=\(targetIdentity) status=verified focused=true"
                )
            case .notFocused:
                return .failed(
                    reason: "Target element (role=\(role)) is not the currently focused Accessibility element after the change.",
                    evidence: "target=\(targetIdentity) status=failed focused=false"
                )
            case .targetUnavailable:
                return .failed(
                    reason: "Target element (role=\(role)) is no longer resolvable for verification after the focus change.",
                    evidence: "target=\(targetIdentity) status=failed"
                )
            }

        case .axPopupValueMatchesDesired(let applicationName, let role, let matchIdentifier, let matchTitle, let targetIdentity, let requestedItemTitle):
            let evidence = await QBridgeAccessibility.shared.observePopupValueEvidence(
                applicationName: applicationName,
                role: role,
                identifier: matchIdentifier,
                title: matchTitle
            )
            switch evidence {
            case .resolved(let currentValue):
                if currentValue == requestedItemTitle {
                    return .verified(
                        evidence: "target=\(targetIdentity) currentValue=\(currentValue) requestedItemTitle=\(requestedItemTitle) status=verified"
                    )
                } else {
                    return .failed(
                        reason: "Target popup (role=\(role)) current value does not match the requested item after the selection.",
                        evidence: "target=\(targetIdentity) currentValue=\(currentValue) requestedItemTitle=\(requestedItemTitle) status=failed"
                    )
                }
            case .targetUnavailable:
                return .failed(
                    reason: "Target popup (role=\(role)) is no longer resolvable, or its value could not be read, for verification after the selection.",
                    evidence: "target=\(targetIdentity) status=failed"
                )
            }

        case .axComboBoxValueMatchesDesired(let applicationName, let role, let matchIdentifier, let matchTitle, let targetIdentity, let requestedItemTitle):
            let evidence = await QBridgeAccessibility.shared.observeComboBoxValueEvidence(
                applicationName: applicationName,
                role: role,
                identifier: matchIdentifier,
                title: matchTitle
            )
            switch evidence {
            case .resolved(let currentValue):
                if currentValue == requestedItemTitle {
                    return .verified(
                        evidence: "target=\(targetIdentity) currentValue=\(currentValue) requestedItemTitle=\(requestedItemTitle) status=verified"
                    )
                } else {
                    return .failed(
                        reason: "Target combo box (role=\(role)) current value does not match the requested item after selection.",
                        evidence: "target=\(targetIdentity) currentValue=\(currentValue) requestedItemTitle=\(requestedItemTitle) status=failed"
                    )
                }
            case .targetUnavailable:
                return .failed(
                    reason: "Target combo box (role=\(role)) is no longer resolvable, or its value could not be read, for verification after selection.",
                    evidence: "target=\(targetIdentity) status=failed"
                )
            }

        case .axIncrementorValueMovedAsDesired(let applicationName, let role, let matchIdentifier, let matchTitle, let targetIdentity, let direction, let previousValue, let changeKind):
            let evidence = await QBridgeAccessibility.shared.observeIncrementorValueEvidence(
                applicationName: applicationName,
                role: role,
                identifier: matchIdentifier,
                title: matchTitle
            )
            switch evidence {
            case .resolved(let currentValue):
                switch changeKind {
                case .alreadyAtBound:
                    if currentValue == previousValue {
                        return .verified(
                            evidence: "target=\(targetIdentity) currentValue=\(currentValue) previousValue=\(previousValue) direction=\(direction.rawValue) status=verified-noop"
                        )
                    } else {
                        return .failed(
                            reason: "Target incrementor (role=\(role)) value changed even though it was reported already at its bound.",
                            evidence: "target=\(targetIdentity) currentValue=\(currentValue) previousValue=\(previousValue) status=failed"
                        )
                    }
                case .changed:
                    let movedCorrectly = direction == .increment ? currentValue > previousValue : currentValue < previousValue
                    if movedCorrectly {
                        return .verified(
                            evidence: "target=\(targetIdentity) currentValue=\(currentValue) previousValue=\(previousValue) direction=\(direction.rawValue) status=verified"
                        )
                    } else {
                        return .failed(
                            reason: "Target incrementor (role=\(role)) current value (\(currentValue)) did not move in the requested direction (\(direction.rawValue)) from its previous value (\(previousValue)).",
                            evidence: "target=\(targetIdentity) currentValue=\(currentValue) previousValue=\(previousValue) status=failed"
                        )
                    }
                }
            case .targetUnavailable:
                return .failed(
                    reason: "Target incrementor (role=\(role)) is no longer resolvable, or its value could not be read, for verification after the step mutation.",
                    evidence: "target=\(targetIdentity) status=failed"
                )
            }

        case .axDisclosureStateMatchesDesired(let applicationName, let role, let matchIdentifier, let matchTitle, let targetIdentity, let desiredState):
            let evidence = await QBridgeAccessibility.shared.observeDisclosureStateEvidence(
                applicationName: applicationName,
                role: role,
                identifier: matchIdentifier,
                title: matchTitle
            )
            switch evidence {
            case .resolved(let currentState):
                if currentState == desiredState {
                    return .verified(
                        evidence: "target=\(targetIdentity) currentState=\(currentState.rawValue) desiredState=\(desiredState.rawValue) status=verified"
                    )
                } else {
                    return .failed(
                        reason: "Target disclosure triangle (role=\(role)) current state does not match the desired state after the toggle.",
                        evidence: "target=\(targetIdentity) currentState=\(currentState.rawValue) desiredState=\(desiredState.rawValue) status=failed"
                    )
                }
            case .stateUnreadable:
                return .failed(
                    reason: "Target disclosure triangle (role=\(role)) current state could not be read or interpreted after the toggle — unknown state fails closed.",
                    evidence: "target=\(targetIdentity) status=failed"
                )
            case .targetUnavailable:
                return .failed(
                    reason: "Target disclosure triangle (role=\(role)) is no longer resolvable for verification after the toggle.",
                    evidence: "target=\(targetIdentity) status=failed"
                )
            }

        case .axTabSelectionMatchesDesired(let applicationName, let role, let matchIdentifier, let matchTitle, let targetIdentity, let desiredSelected):
            let evidence = await QBridgeAccessibility.shared.observeTabSelectionEvidence(
                applicationName: applicationName,
                role: role,
                identifier: matchIdentifier,
                title: matchTitle
            )
            switch evidence {
            case .resolved(let currentSelected):
                if currentSelected == desiredSelected {
                    return .verified(
                        evidence: "target=\(targetIdentity) currentSelected=\(currentSelected) desiredSelected=\(desiredSelected) status=verified"
                    )
                } else {
                    return .failed(
                        reason: "Target tab (role=\(role)) current selection state does not match the desired state after the selection.",
                        evidence: "target=\(targetIdentity) currentSelected=\(currentSelected) desiredSelected=\(desiredSelected) status=failed"
                    )
                }
            case .stateUnreadable:
                return .failed(
                    reason: "Target tab (role=\(role)) current selection state could not be read after the selection — unreadable state fails closed.",
                    evidence: "target=\(targetIdentity) status=failed"
                )
            case .targetUnavailable:
                return .failed(
                    reason: "Target tab (role=\(role)) is no longer resolvable, ambiguous, or no longer subrole-qualified as a tab, for verification after the selection.",
                    evidence: "target=\(targetIdentity) status=failed"
                )
            }

        case .axTableRowSelectionMatchesDesired(let applicationName, let role, let matchIdentifier, let matchTitle, let targetIdentity, let desiredSelected):
            let evidence = await QBridgeAccessibility.shared.observeTableRowSelectionEvidence(
                applicationName: applicationName,
                role: role,
                identifier: matchIdentifier,
                title: matchTitle
            )
            switch evidence {
            case .resolved(let currentSelected):
                if currentSelected == desiredSelected {
                    return .verified(
                        evidence: "target=\(targetIdentity) currentSelected=\(currentSelected) desiredSelected=\(desiredSelected) status=verified"
                    )
                } else {
                    return .failed(
                        reason: "Target table row (role=\(role)) current selection state does not match the desired state after the selection.",
                        evidence: "target=\(targetIdentity) currentSelected=\(currentSelected) desiredSelected=\(desiredSelected) status=failed"
                    )
                }
            case .stateUnreadable:
                return .failed(
                    reason: "Target table row (role=\(role)) current selection state could not be read after the selection — unreadable state fails closed.",
                    evidence: "target=\(targetIdentity) status=failed"
                )
            case .targetUnavailable:
                return .failed(
                    reason: "Target table row (role=\(role)) is no longer resolvable, ambiguous, or no longer subrole/table-context-qualified, for verification after the selection.",
                    evidence: "target=\(targetIdentity) status=failed"
                )
            }

        case .axOutlineRowSelectionMatchesDesired(let applicationName, let role, let matchIdentifier, let matchTitle, let targetIdentity, let desiredSelected):
            let evidence = await QBridgeAccessibility.shared.observeOutlineRowSelectionEvidence(
                applicationName: applicationName,
                role: role,
                identifier: matchIdentifier,
                title: matchTitle
            )
            switch evidence {
            case .resolved(let currentSelected):
                if currentSelected == desiredSelected {
                    return .verified(
                        evidence: "target=\(targetIdentity) currentSelected=\(currentSelected) desiredSelected=\(desiredSelected) status=verified"
                    )
                } else {
                    return .failed(
                        reason: "Target outline row (role=\(role)) current selection state does not match the desired state after the selection.",
                        evidence: "target=\(targetIdentity) currentSelected=\(currentSelected) desiredSelected=\(desiredSelected) status=failed"
                    )
                }
            case .stateUnreadable:
                return .failed(
                    reason: "Target outline row (role=\(role)) current selection state could not be read after the selection — unreadable state fails closed.",
                    evidence: "target=\(targetIdentity) status=failed"
                )
            case .targetUnavailable:
                return .failed(
                    reason: "Target outline row (role=\(role)) is no longer resolvable, ambiguous, or no longer subrole/outline-context-qualified, for verification after the selection.",
                    evidence: "target=\(targetIdentity) status=failed"
                )
            }

        case .axWindowMinimizedStateMatchesDesired(let applicationName, let role, let matchIdentifier, let matchTitle, let targetIdentity, let desiredMinimized):
            let evidence = await QBridgeAccessibility.shared.observeWindowMinimizedStateEvidence(
                applicationName: applicationName,
                role: role,
                identifier: matchIdentifier,
                title: matchTitle
            )
            switch evidence {
            case .resolved(let currentMinimized):
                if currentMinimized == desiredMinimized {
                    return .verified(
                        evidence: "target=\(targetIdentity) currentMinimized=\(currentMinimized) desiredMinimized=\(desiredMinimized) status=verified"
                    )
                } else {
                    return .failed(
                        reason: "Target window (role=\(role)) current minimized state does not match the desired state after the mutation.",
                        evidence: "target=\(targetIdentity) currentMinimized=\(currentMinimized) desiredMinimized=\(desiredMinimized) status=failed"
                    )
                }
            case .stateUnreadable:
                return .failed(
                    reason: "Target window (role=\(role)) current minimized state could not be read after the mutation — unreadable state fails closed.",
                    evidence: "target=\(targetIdentity) status=failed"
                )
            case .targetUnavailable:
                return .failed(
                    reason: "Target window (role=\(role)) is no longer resolvable or is ambiguous, for verification after the mutation.",
                    evidence: "target=\(targetIdentity) status=failed"
                )
            }

        case .axWindowFullScreenMatchesDesired(let applicationName, let role, let matchIdentifier, let matchTitle, let targetIdentity, let desiredFullScreen):
            let evidence = await QBridgeAccessibility.shared.observeWindowFullScreenStateEvidence(
                applicationName: applicationName,
                role: role,
                identifier: matchIdentifier,
                title: matchTitle
            )
            switch evidence {
            case .resolved(let currentFullScreen):
                if currentFullScreen == desiredFullScreen {
                    return .verified(
                        evidence: "target=\(targetIdentity) currentFullScreen=\(currentFullScreen) desiredFullScreen=\(desiredFullScreen) status=verified"
                    )
                } else {
                    return .failed(
                        reason: "Target window (role=\(role)) current full-screen state does not match the desired state after the mutation.",
                        evidence: "target=\(targetIdentity) currentFullScreen=\(currentFullScreen) desiredFullScreen=\(desiredFullScreen) status=failed"
                    )
                }
            case .stateUnreadable:
                return .failed(
                    reason: "Target window (role=\(role)) current full-screen state could not be read after the mutation — unreadable state fails closed.",
                    evidence: "target=\(targetIdentity) status=failed"
                )
            case .targetUnavailable:
                return .failed(
                    reason: "Target window (role=\(role)) is no longer resolvable or is ambiguous, for verification after the mutation.",
                    evidence: "target=\(targetIdentity) status=failed"
                )
            }

        case .applicationHiddenStateMatchesDesired(let applicationName, let targetProcessIdentifier, let desiredHidden):
            guard let target = NSWorkspace.shared.runningApplications.first(where: { $0.processIdentifier == targetProcessIdentifier }) else {
                return .failed(
                    reason: "Application '\(applicationName)' (pid=\(targetProcessIdentifier)) is no longer running, for verification after the hidden-state mutation.",
                    evidence: "target=\(applicationName) pid=\(targetProcessIdentifier) status=failed"
                )
            }
            let currentHidden = target.isHidden
            if currentHidden == desiredHidden {
                return .verified(
                    evidence: "target=\(applicationName) pid=\(targetProcessIdentifier) currentHidden=\(currentHidden) desiredHidden=\(desiredHidden) status=verified"
                )
            } else {
                return .failed(
                    reason: "Application '\(applicationName)' current hidden state does not match the desired state after the mutation.",
                    evidence: "target=\(applicationName) pid=\(targetProcessIdentifier) currentHidden=\(currentHidden) desiredHidden=\(desiredHidden) status=failed"
                )
            }

        case .axSegmentedControlSelectionMatchesDesired(let applicationName, let role, let controlIdentifier, let controlTitle, let windowTitle, let windowIdentifier, let segmentIdentifier, let segmentTitle, let targetIdentity, let desiredSelected):
            let evidence = await QBridgeAccessibility.shared.observeSegmentedControlSelectionEvidence(
                applicationName: applicationName,
                role: role,
                controlIdentifier: controlIdentifier,
                controlTitle: controlTitle,
                windowTitle: windowTitle,
                windowIdentifier: windowIdentifier,
                segmentIdentifier: segmentIdentifier,
                segmentTitle: segmentTitle
            )
            switch evidence {
            case .resolved(let currentSelected):
                if currentSelected == desiredSelected {
                    return .verified(
                        evidence: "target=\(targetIdentity) currentSelected=\(currentSelected) desiredSelected=\(desiredSelected) status=verified"
                    )
                } else {
                    return .failed(
                        reason: "Target segmented control item (role=\(role)) current selection state does not match the desired state after the selection.",
                        evidence: "target=\(targetIdentity) currentSelected=\(currentSelected) desiredSelected=\(desiredSelected) status=failed"
                    )
                }
            case .stateUnreadable:
                return .failed(
                    reason: "Target segmented control item (role=\(role)) current selection state could not be read after the selection — unreadable state fails closed.",
                    evidence: "target=\(targetIdentity) status=failed"
                )
            case .targetUnavailable:
                return .failed(
                    reason: "Target segmented control item (role=\(role)) is no longer resolvable, ambiguous, or no longer role-qualified, for verification after the selection.",
                    evidence: "target=\(targetIdentity) status=failed"
                )
            }

        case .splitterPositionMatchesDesired(let applicationName, let windowTitle, let windowIdentifier, let splitGroupIdentifier, let splitGroupTitle, let splitterIndex, let desiredPosition, let tolerance, let targetIdentity):
            let evidence = await QBridgeAccessibility.shared.reobserveSplitterPosition(
                applicationName: applicationName,
                windowTitle: windowTitle,
                windowIdentifier: windowIdentifier,
                splitGroupIdentifier: splitGroupIdentifier,
                splitGroupTitle: splitGroupTitle,
                splitterIndex: splitterIndex
            )
            switch evidence {
            case .resolved(let currentPosition):
                if QBridgeAccessibility.splitterPositionsAreEqual(currentPosition, desiredPosition, tolerance: tolerance) {
                    return .verified(
                        evidence: "target=\(targetIdentity) currentPosition=\(currentPosition) desiredPosition=\(desiredPosition) tolerance=\(tolerance) status=verified"
                    )
                } else {
                    return .failed(
                        reason: "Target splitter (index=\(splitterIndex)) current position (\(currentPosition)) does not match desired position (\(desiredPosition)) within tolerance (\(tolerance)).",
                        evidence: "target=\(targetIdentity) currentPosition=\(currentPosition) desiredPosition=\(desiredPosition) tolerance=\(tolerance) status=failed"
                    )
                }
            case .rangeInvalid(let currentPosition):
                return .failed(
                    reason: "Target splitter (index=\(splitterIndex)) reported an internally inconsistent range or position (\(currentPosition)) after mutation.",
                    evidence: "target=\(targetIdentity) currentPosition=\(currentPosition) status=failed"
                )
            case .targetUnavailable:
                return .failed(
                    reason: "Target splitter (index=\(splitterIndex)) is no longer resolvable or role-qualified for verification.",
                    evidence: "target=\(targetIdentity) status=failed"
                )
            }

        case .focusedElementReadSucceeded(let applicationName, let role, let hasValue):
            if result.success {
                return .verified(
                    evidence: "application=\(applicationName) role=\(role) hasValue=\(hasValue) status=verified"
                )
            } else {
                return .failed(
                    reason: "Focused element read for application '\(applicationName)' did not succeed.",
                    evidence: "application=\(applicationName) status=failed"
                )
            }

        case .applicationStateReadSucceeded(let applicationName):
            if result.success {
                return .verified(
                    evidence: "application=\(applicationName) status=verified"
                )
            } else {
                return .failed(
                    reason: "Application state read for '\(applicationName)' did not succeed.",
                    evidence: "application=\(applicationName) status=failed"
                )
            }

        case .tableColumnEnumerationSucceeded(let applicationName, let columnCount):
            if result.success {
                return .verified(
                    evidence: "application=\(applicationName) tableRole=AXTable columnCount=\(columnCount) status=verified"
                )
            } else {
                return .failed(
                    reason: "Table column enumeration for application '\(applicationName)' did not succeed.",
                    evidence: "application=\(applicationName) tableRole=AXTable status=failed"
                )
            }

        case .elementRangeReadSucceeded(let applicationName, let role):
            if result.success {
                return .verified(
                    evidence: "application=\(applicationName) role=\(role) status=verified"
                )
            } else {
                return .failed(
                    reason: "Element range read for application '\(applicationName)' did not succeed.",
                    evidence: "application=\(applicationName) role=\(role) status=failed"
                )
            }

        case .elementActionsReadSucceeded(let applicationName, let role, let actionCount):
            guard actionCount >= 0, actionCount <= 16 else {
                return .failed(
                    reason: "Action count (\(actionCount)) for application '\(applicationName)' is outside the permitted bound [0, 16].",
                    evidence: "application=\(applicationName) role=\(role) status=failed"
                )
            }
            if result.success {
                return .verified(
                    evidence: "application=\(applicationName) role=\(role) actionCount=\(actionCount) status=verified"
                )
            } else {
                return .failed(
                    reason: "Element action enumeration for application '\(applicationName)' did not succeed.",
                    evidence: "application=\(applicationName) role=\(role) status=failed"
                )
            }

        case .elementAttributeNamesReadSucceeded(let applicationName, let role, let attributeCount):
            guard attributeCount >= 0, attributeCount <= 32 else {
                return .failed(
                    reason: "Attribute count (\(attributeCount)) for application '\(applicationName)' is outside the permitted bound [0, 32].",
                    evidence: "application=\(applicationName) role=\(role) status=failed"
                )
            }
            if result.success {
                return .verified(
                    evidence: "application=\(applicationName) role=\(role) attributeCount=\(attributeCount) status=verified"
                )
            } else {
                return .failed(
                    reason: "Element attribute name enumeration for application '\(applicationName)' did not succeed.",
                    evidence: "application=\(applicationName) role=\(role) status=failed"
                )
            }

        case .customCheck(let description, let check):
            let passed = await check()
            if passed {
                return .verified(evidence: "Custom assertion passed: \(description)")
            } else {
                return .failed(
                    reason: "Custom assertion failed: \(description)",
                    evidence: "Predicate returned false."
                )
            }
        }
    }
}
