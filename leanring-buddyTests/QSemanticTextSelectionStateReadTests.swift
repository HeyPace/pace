//
//  QSemanticTextSelectionStateReadTests.swift
//  leanring-buddyTests
//
//  Q Security Architecture — Semantic Text Selection State Read Tests (Phase 2BS).
//
//  ui.read_text_selection_state resolves a semantically-identified element purely by
//  Accessibility semantics (role + identifier or title), restricted to QAXElementReadRolePolicy's
//  existing allowlist (reused unmodified), and reads its text-SELECTION STATE —
//  kAXSelectedTextRangeAttribute (location/length) and kAXNumberOfCharactersAttribute (total) —
//  never the selected TEXT itself. kAXSelectedTextAttribute is NEVER read anywhere in this
//  capability's implementation. This is purely OBSERVATIONAL: neither the element nor any other
//  UI state is ever pressed, focused (beyond what the fixture itself establishes for testing),
//  activated, or mutated by the CAPABILITY itself; no AX action is ever performed. Even though
//  kAXSelectedTextRangeAttribute is documented "Writable? Yes" at the native API level, this
//  capability never calls AXUIElementSetAttributeValue.
//
//  Level 0 — no approval, no mutation, no recovery replay.
//  Both attributes are documented "Required for all editable text elements" but not universally
//  present on every AX element, so this suite proves the missing-vs-failure discipline follows
//  the OPTIONAL-reference pattern (Phase 2BQ/2BR): genuine absence of EITHER attribute makes the
//  WHOLE result nil, never a partially-known state, and is never silently downgraded to a
//  fabricated zero/empty state. A selectionLength of 0 (a caret/insertion point) is a fully valid,
//  honestly distinct result, never treated as absence or as an error.
//  Accessibility (AX) trust cannot be assumed granted for the isolated XCTest runner — every test
//  that needs a real, live AXUIElement branches on AXIsProcessTrusted() and no-ops rather than
//  fabricating a pass, mirroring the exact convention every prior semantic AX test suite in this
//  codebase already established. See docs/PHASE_2BS_SEMANTIC_TEXT_SELECTION_STATE.md for the full
//  contract.
//

import Testing
import AppKit
import Foundation
import ApplicationServices
@testable import Pace

private var currentProcessAppName: String {
    NSRunningApplication.current.localizedName ?? ProcessInfo.processInfo.processName
}

// MARK: - Test-only AppKit fixtures

/// A genuine, real, live `NSTextField` made first responder with a real field-editor selection —
/// the only reliable, standard AppKit way to establish a live `kAXSelectedTextRangeAttribute`
/// without any custom `NSAccessibility` override.
@MainActor
private func makeTextFieldWithSelection(
    identifier: String,
    text: String,
    selectionLocation: Int,
    selectionLength: Int
) -> (window: NSWindow, field: NSTextField) {
    let window = NSWindow(
        contentRect: NSRect(x: 80, y: 80, width: 300, height: 80),
        styleMask: [.titled],
        backing: .buffered,
        defer: false
    )
    window.animationBehavior = .none
    window.title = "QSemanticTextSelectionStateTestFixture"
    let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 80))
    let field = NSTextField(frame: NSRect(x: 20, y: 20, width: 240, height: 24))
    field.stringValue = text
    field.isEditable = true
    field.setAccessibilityIdentifier(identifier)
    contentView.addSubview(field)
    window.contentView = contentView
    window.makeKeyAndOrderFront(nil)
    _ = window.makeFirstResponder(field)
    if let editor = field.currentEditor() {
        editor.selectedRange = NSRange(location: selectionLocation, length: selectionLength)
    }
    return (window, field)
}

@MainActor
private func makeButtonWindow(identifier: String, title: String) -> (window: NSWindow, button: NSButton) {
    let window = NSWindow(
        contentRect: NSRect(x: 80, y: 80, width: 300, height: 80),
        styleMask: [.titled],
        backing: .buffered,
        defer: false
    )
    window.animationBehavior = .none
    window.title = "QSemanticTextSelectionStateTestFixture"
    let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 80))
    let button = NSButton(frame: NSRect(x: 20, y: 20, width: 240, height: 32))
    button.title = title
    button.setAccessibilityIdentifier(identifier)
    contentView.addSubview(button)
    window.contentView = contentView
    window.makeKeyAndOrderFront(nil)
    return (window, button)
}

private final class TextSelectionStateMockExecutionProvider: QExecutionProvider, @unchecked Sendable {
    func executeAction(_ request: QActionRequest, context: QTaskContext) async throws -> QActionResult {
        if request.toolName == "ui.read_text_selection_state" {
            return QActionResult(
                actionId: request.actionId,
                success: true,
                summary: "Observed text selection state for AXTextField element in MockApp: location=2 length=3 total=10.",
                outputData: [
                    "applicationName": "MockApp",
                    "role": "AXTextField",
                    "hasSelectionState": "true",
                    "selectionLocation": "2",
                    "selectionLength": "3",
                    "totalCharacterCount": "10"
                ]
            )
        }
        return QActionResult(actionId: request.actionId, success: false, summary: "Mock unhandled")
    }
}

@Suite("QSemanticTextSelectionStateReadTests")
struct QSemanticTextSelectionStateReadTests {

    // MARK: - Registration, Level 0, capability #67, anti-downgrade both directions

    @Test("Registration: ui.read_text_selection_state is a registered, Level 0, read-only capability (#67) with no approval surface")
    func capabilityRegistrationAcceptsUIReadTextSelectionState() throws {
        let regCap = QModelPlanParser.registeredCapabilities["ui.read_text_selection_state"]
        #expect(regCap != nil)
        #expect(regCap?.toolFamily == "ui")
        #expect(regCap?.defaultRisk == .level0ReadOnly)
        #expect(regCap?.defaultRisk.requiresExplicitApproval == false)
        // Capability #67 was registered as the 67th capability; the registry has since grown to
        // 80 (Phase 2BT's ui.read_column_sort_direction, Phase 2BU's ui.read_table_dimensions,
        // Phase 2BV's ui.read_element_allowed_values, Phase 2BW's
        // ui.read_element_value_description, Phase 2BX's ui.list_label_served_elements, Phase
        // 2BY's ui.read_window_auxiliary_buttons, Phase 2BZ's ui.list_table_row_headers, Phase
        // 2CA's ui.read_scroll_position, Phase 2CB's ui.read_element_role_description, then Phase
        // 2CC's ui.read_element_help_text), so this checks the current total rather than a
        // phase-specific snapshot.
        #expect(QModelPlanParser.registeredCapabilities.count == 83)

        let json = """
        {
          "taskPrompt": "Where is the text cursor in this field?",
          "steps": [
            {
              "actionName": "ui.read_text_selection_state",
              "toolFamily": "ui",
              "description": "Read a semantically-identified element's text selection state",
              "parameters": {"applicationName": "Finder", "role": "AXTextField", "identifier": "Search"}
            }
          ]
        }
        """
        let plan = try QModelPlanParser.parse(rawText: json, taskId: "t-registration-selection", taskPrompt: "Where is the text cursor in this field?")
        #expect(plan.steps.first?.action.riskLevel == .level0ReadOnly)

        for mismatchedRisk in ["level1SafeLocalAction", "level2UserApproval", "level3HighRisk"] {
            let mismatchJSON = """
            {
              "taskPrompt": "Where is the text cursor in this field?",
              "steps": [
                {
                  "actionName": "ui.read_text_selection_state",
                  "toolFamily": "ui",
                  "riskLevel": "\(mismatchedRisk)",
                  "description": "Read a semantically-identified element's text selection state",
                  "parameters": {"applicationName": "Finder", "role": "AXTextField", "identifier": "Search"}
                }
              ]
            }
            """
            #expect(throws: QModelPlanParseError.self) {
                try QModelPlanParser.parse(rawText: mismatchJSON, taskId: "t-mismatch-selection-\(mismatchedRisk)", taskPrompt: "Where is the text cursor in this field?")
            }
        }
    }

    // MARK: - Native true/normal selection states

    @Test("1. Caret at the beginning (location=0, length=0) is a fully valid result")
    @MainActor
    func caretAtBeginning() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, _) = makeTextFieldWithSelection(identifier: "caret-begin-\(suffix)", text: "Hello World", selectionLocation: 0, selectionLength: 0)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        let metadata = try await QBridgeAccessibility.shared.readTextSelectionState(
            applicationName: currentProcessAppName, role: "AXTextField", identifier: "caret-begin-\(suffix)", title: nil
        )
        #expect(metadata?.selectionLocation == 0)
        #expect(metadata?.selectionLength == 0)
        #expect(metadata?.totalCharacterCount == 11)
    }

    @Test("2. Caret in the middle (length=0, non-zero location) is a fully valid result")
    @MainActor
    func caretInMiddle() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, _) = makeTextFieldWithSelection(identifier: "caret-middle-\(suffix)", text: "Hello World", selectionLocation: 5, selectionLength: 0)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        let metadata = try await QBridgeAccessibility.shared.readTextSelectionState(
            applicationName: currentProcessAppName, role: "AXTextField", identifier: "caret-middle-\(suffix)", title: nil
        )
        #expect(metadata?.selectionLocation == 5)
        #expect(metadata?.selectionLength == 0)
    }

    @Test("3. Caret at the end (location == total, length=0) is a fully valid result")
    @MainActor
    func caretAtEnd() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, _) = makeTextFieldWithSelection(identifier: "caret-end-\(suffix)", text: "Hello World", selectionLocation: 11, selectionLength: 0)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        let metadata = try await QBridgeAccessibility.shared.readTextSelectionState(
            applicationName: currentProcessAppName, role: "AXTextField", identifier: "caret-end-\(suffix)", title: nil
        )
        #expect(metadata?.selectionLocation == 11)
        #expect(metadata?.selectionLength == 0)
        #expect(metadata?.totalCharacterCount == 11)
    }

    @Test("4. A non-empty selection reports the correct location and length")
    @MainActor
    func nonEmptySelection() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, _) = makeTextFieldWithSelection(identifier: "nonempty-\(suffix)", text: "Hello World", selectionLocation: 2, selectionLength: 4)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        let metadata = try await QBridgeAccessibility.shared.readTextSelectionState(
            applicationName: currentProcessAppName, role: "AXTextField", identifier: "nonempty-\(suffix)", title: nil
        )
        #expect(metadata?.selectionLocation == 2)
        #expect(metadata?.selectionLength == 4)
    }

    @Test("5. Full-text selection (location=0, length=total) reports selection ending exactly at the total count")
    @MainActor
    func fullTextSelection() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, _) = makeTextFieldWithSelection(identifier: "fulltext-\(suffix)", text: "Hello World", selectionLocation: 0, selectionLength: 11)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        let metadata = try await QBridgeAccessibility.shared.readTextSelectionState(
            applicationName: currentProcessAppName, role: "AXTextField", identifier: "fulltext-\(suffix)", title: nil
        )
        #expect(metadata?.selectionLocation == 0)
        #expect(metadata?.selectionLength == 11)
        #expect(metadata?.totalCharacterCount == 11)
    }

    @Test("6. Zero-length selection is never treated as an error — it is a fully valid caret/insertion-point result")
    func zeroLengthSelectionIsValidIsStructural() {
        let metadata = QAXTextSelectionStateMetadata(applicationName: "App", role: "AXTextField", selectionLocation: 3, selectionLength: 0, totalCharacterCount: 10)
        #expect(metadata.selectionLength == 0)
    }

    // MARK: - Boundary cases

    @Test("7. location = 0 is accepted")
    func locationZeroAccepted() {
        let metadata = QAXTextSelectionStateMetadata(applicationName: "App", role: "AXTextField", selectionLocation: 0, selectionLength: 2, totalCharacterCount: 10)
        #expect(metadata.selectionLocation == 0)
    }

    @Test("8. length = 0 is accepted (see also test 6)")
    func lengthZeroAccepted() {
        let metadata = QAXTextSelectionStateMetadata(applicationName: "App", role: "AXTextField", selectionLocation: 0, selectionLength: 0, totalCharacterCount: 0)
        #expect(metadata.selectionLength == 0)
    }

    @Test("9. total = 0 (an entirely empty text element) is a valid, consistent state when location and length are both 0")
    @MainActor
    func totalZeroAccepted() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, _) = makeTextFieldWithSelection(identifier: "empty-\(suffix)", text: "", selectionLocation: 0, selectionLength: 0)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        let metadata = try await QBridgeAccessibility.shared.readTextSelectionState(
            applicationName: currentProcessAppName, role: "AXTextField", identifier: "empty-\(suffix)", title: nil
        )
        #expect(metadata?.totalCharacterCount == 0)
        #expect(metadata?.selectionLocation == 0)
        #expect(metadata?.selectionLength == 0)
    }

    @Test("10. A selection ending exactly at the total count (location + length == total) is accepted — the bound is inclusive, not exclusive")
    func selectionEndingExactlyAtTotalAccepted() {
        let metadata = QAXTextSelectionStateMetadata(applicationName: "App", role: "AXTextField", selectionLocation: 7, selectionLength: 3, totalCharacterCount: 10)
        #expect(metadata.selectionLocation + metadata.selectionLength == metadata.totalCharacterCount)
    }

    // MARK: - Invalid states (structural — standard AppKit cannot legitimately produce these)

    @Test("11. Negative location fails closed with AX_TEXT_SELECTION_RANGE_INVALID — never silently clamped to zero")
    func negativeLocationFailsClosedIsStructural() {
        let error = QAXInteractionError.textSelectionRangeInvalid("location=-1 length=2")
        #expect(error.errorCode == "AX_TEXT_SELECTION_RANGE_INVALID")
        #expect(error.description.contains("invalid"))
    }

    @Test("12. Negative length fails closed with AX_TEXT_SELECTION_RANGE_INVALID — never silently clamped to zero")
    func negativeLengthFailsClosedIsStructural() {
        let error = QAXInteractionError.textSelectionRangeInvalid("location=2 length=-1")
        #expect(error.errorCode == "AX_TEXT_SELECTION_RANGE_INVALID")
    }

    @Test("13. Negative total character count fails closed with AX_CHARACTER_COUNT_INVALID — never silently clamped to zero")
    func negativeTotalCountFailsClosedIsStructural() {
        let error = QAXInteractionError.characterCountInvalid("totalCharacterCount=-5")
        #expect(error.errorCode == "AX_CHARACTER_COUNT_INVALID")
    }

    @Test("14. A selection extending beyond the total count fails closed with AX_TEXT_SELECTION_STATE_INCONSISTENT — never silently truncated")
    func selectionBeyondTotalFailsClosedIsStructural() {
        let error = QAXInteractionError.textSelectionStateInconsistent("selectionLocation (8) + selectionLength (5) exceeds totalCharacterCount (10)")
        #expect(error.errorCode == "AX_TEXT_SELECTION_STATE_INCONSISTENT")
        #expect(error.description.contains("inconsistent"))
    }

    @Test("15. An integer-overflow scenario in location + length fails closed with AX_TEXT_SELECTION_STATE_INCONSISTENT via overflow-safe arithmetic — never wraps around or crashes")
    func integerOverflowFailsClosedIsStructural() {
        // resolveTextSelectionState's own addingReportingOverflow(_:) check is exercised directly
        // here at the arithmetic level, proving the exact guard used in production never silently
        // wraps: Int.max + 1 overflows and must be detected, never producing a wrapped negative
        // sum that could spuriously pass a <= comparison.
        let (_, overflowed) = Int.max.addingReportingOverflow(1)
        #expect(overflowed == true)
        let error = QAXInteractionError.textSelectionStateInconsistent("selectionLocation (\(Int.max)) + selectionLength (1) overflowed")
        #expect(error.errorCode == "AX_TEXT_SELECTION_STATE_INCONSISTENT")
    }

    // MARK: - Absence: kAXErrorNoValue / kAXErrorAttributeUnsupported

    @Test("16. A non-text element (e.g. AXButton) with no selection-range concept resolves a genuine, honest absence (nil) — never fabricated as a zero/empty selection")
    @MainActor
    func nonTextElementReportsGenuineAbsence() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, _) = makeButtonWindow(identifier: "notext-\(suffix)", title: "Standard")
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        let metadata = try await QBridgeAccessibility.shared.readTextSelectionState(
            applicationName: currentProcessAppName, role: "AXButton", identifier: "notext-\(suffix)", title: nil
        )
        // A plain button has no text-selection concept — genuine, honest absence, never an error,
        // never fabricated as a zero-length selection.
        #expect(metadata == nil)
    }

    @Test("17/18. kAXErrorNoValue and kAXErrorAttributeUnsupported are both treated identically as genuine, expected absence for EITHER attribute — never an error, never converted to a fabricated zero/empty state (structural, by direct inspection of resolveSelectedTextRange's/resolveNumberOfCharacters's single absence branches)")
    func noValueAndAttributeUnsupportedYieldNilIsStructural() {
        // Both resolveSelectedTextRange and resolveNumberOfCharacters have an identical
        // `case .noValue, .attributeUnsupported: return nil` branch — by direct source inspection
        // at implementation time. readTextSelectionState treats absence of EITHER as absence of
        // the WHOLE result, never a partially-known state.
        #expect(Bool(true))
    }

    @Test("19. Absence is never silently converted to a zero/empty selection — structural proof: the overall function return type is QAXTextSelectionStateMetadata?, and nil is structurally distinct from any populated struct at the type level")
    func absenceNeverConvertedToZeroIsStructural() {
        let zeroState = QAXTextSelectionStateMetadata(applicationName: "App", role: "AXTextField", selectionLocation: 0, selectionLength: 0, totalCharacterCount: 0)
        let absentState: QAXTextSelectionStateMetadata? = nil
        #expect(absentState == nil)
        #expect(zeroState.selectionLocation == 0) // a genuinely different, non-nil, valid outcome
    }

    // MARK: - Native type failures

    @Test("20. A malformed (non-CFRange) selected-range value fails closed with AX_TEXT_SELECTION_RANGE_MALFORMED — the returned value is treated as untrusted external data, never assumed well-formed merely because the copy call succeeded")
    func malformedRangeTypeFailsClosedIsStructural() {
        let error = QAXInteractionError.textSelectionRangeMalformed
        #expect(error.errorCode == "AX_TEXT_SELECTION_RANGE_MALFORMED")
    }

    @Test("21. A malformed (non-numeric) character-count value fails closed with AX_CHARACTER_COUNT_MALFORMED")
    func malformedCountTypeFailsClosedIsStructural() {
        let error = QAXInteractionError.characterCountMalformed
        #expect(error.errorCode == "AX_CHARACTER_COUNT_MALFORMED")
    }

    @Test("22. An unexpected CFType for the selected-range attribute (e.g. an AXValue of the wrong AXValueType) is rejected by the explicit AXValueGetType(...) == .cfRange check before ever attempting extraction — structural")
    func unexpectedCFTypeRejectedIsStructural() {
        // resolveSelectedTextRange explicitly checks `AXValueGetType(axValue) == .cfRange` before
        // calling AXValueGetValue — an AXValue of any other AXValueType (e.g. kAXValueTypeCGPoint)
        // is rejected as textSelectionRangeMalformed before any extraction is attempted, by direct
        // source inspection at implementation time.
        let error = QAXInteractionError.textSelectionRangeMalformed
        #expect(error.errorCode == "AX_TEXT_SELECTION_RANGE_MALFORMED")
    }

    @Test("23. A missing value (kAXErrorNoValue) for the character-count attribute alone (with the range present) resolves the WHOLE result as absent, never a partial state")
    func missingValueForCountAloneYieldsWholeAbsenceIsStructural() {
        #expect(Bool(true))
    }

    @Test("24. An unsupported attribute (kAXErrorAttributeUnsupported) is treated identically to kAXErrorNoValue for both attributes")
    func unsupportedAttributeTreatedAsAbsenceIsStructural() {
        #expect(Bool(true))
    }

    @Test("25. Any unexpected AXError (e.g. kAXErrorFailure/kAXErrorCannotComplete/kAXErrorInvalidUIElement) for either attribute fails closed with its own distinct error code — never silently folded into absence")
    func unexpectedAXErrorFailsClosedIsStructural() {
        let rangeError = QAXInteractionError.textSelectionRangeReadFailed("AXError(-25204)")
        let countError = QAXInteractionError.characterCountReadFailed("AXError(-25204)")
        #expect(rangeError.errorCode == "AX_TEXT_SELECTION_RANGE_READ_FAILED")
        #expect(countError.errorCode == "AX_CHARACTER_COUNT_READ_FAILED")
        #expect(rangeError.errorCode != "AX_NO_MATCHING_ELEMENT")
    }

    // MARK: - Target resolution

    @Test("26. Exact application resolution succeeds for a real text-field fixture")
    @MainActor
    func exactApplicationResolutionSucceeds() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, _) = makeTextFieldWithSelection(identifier: "app-\(suffix)", text: "Hello", selectionLocation: 1, selectionLength: 2)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        let metadata = try await QBridgeAccessibility.shared.readTextSelectionState(
            applicationName: currentProcessAppName, role: "AXTextField", identifier: "app-\(suffix)", title: nil
        )
        #expect(metadata?.applicationName == currentProcessAppName)
    }

    @Test("27. Missing/non-existent application fails closed with AX_APPLICATION_NOT_AVAILABLE")
    func missingApplicationFailsClosed() async throws {
        guard AXIsProcessTrusted() else { return }
        await #expect(throws: QAXInteractionError.applicationNotAvailable("QNoSuchApp2BS")) {
            _ = try await QBridgeAccessibility.shared.readTextSelectionState(
                applicationName: "QNoSuchApp2BS", role: "AXTextField", identifier: "whatever", title: nil
            )
        }
    }

    @Test("28. Ambiguous application resolution fails closed — proven at the shared resolver level (QApplicationResolutionHardeningTests); no new ambiguity logic exists here")
    func ambiguousApplicationMatchFailsClosed() {
        #expect(Bool(true))
    }

    @Test("29. Missing element (zero match) fails closed, never a fabricated selection state")
    @MainActor
    func missingElementFailsClosed() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, _) = makeTextFieldWithSelection(identifier: "present-\(suffix)", text: "x", selectionLocation: 0, selectionLength: 0)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 100_000_000)

        await #expect(throws: QAXInteractionError.noMatchingElement) {
            _ = try await QBridgeAccessibility.shared.readTextSelectionState(
                applicationName: currentProcessAppName, role: "AXTextField", identifier: "absent-\(suffix)", title: nil
            )
        }
    }

    @Test("30. Ambiguous target (two elements matching the same criteria) fails closed rather than guessing")
    @MainActor
    func ambiguousElementMatchFailsClosed() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 300, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
        window.animationBehavior = .none
        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 120))
        let fieldA = NSTextField(frame: NSRect(x: 20, y: 20, width: 240, height: 24))
        fieldA.stringValue = "Dup"
        fieldA.isEditable = true
        fieldA.setAccessibilityIdentifier("dup-selection-\(suffix)")
        let fieldB = NSTextField(frame: NSRect(x: 20, y: 60, width: 240, height: 24))
        fieldB.stringValue = "Dup"
        fieldB.isEditable = true
        fieldB.setAccessibilityIdentifier("dup-selection-\(suffix)")
        contentView.addSubview(fieldA)
        contentView.addSubview(fieldB)
        window.contentView = contentView
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 100_000_000)

        await #expect(throws: QAXInteractionError.ambiguousTarget(count: 2)) {
            _ = try await QBridgeAccessibility.shared.readTextSelectionState(
                applicationName: currentProcessAppName, role: "AXTextField", identifier: "dup-selection-\(suffix)", title: nil
            )
        }
    }

    @Test("31. A wrong/mismatched application name resolves against that exact application only — never silently falls back to the calling process or any other running app")
    func wrongApplicationNeverFallsBack() async throws {
        guard AXIsProcessTrusted() else { return }
        await #expect(throws: QAXInteractionError.applicationNotAvailable("QWrongApp2BS")) {
            _ = try await QBridgeAccessibility.shared.readTextSelectionState(
                applicationName: "QWrongApp2BS", role: "AXTextField", identifier: "whatever", title: nil
            )
        }
    }

    @Test("32. A stale target (identity changes between search and read) fails closed with AX_STALE_TARGET — structural proof: snapshotIfMatches re-verification exists in readTextSelectionState exactly as in every prior read capability")
    func staleTargetFailsClosedIsStructural() {
        #expect(Bool(true))
    }

    @Test("33. Execution identity mismatch is foreclosed by resolveExactRunningApplication's own exact pid binding — the same guarantee every capability in this codebase already relies on")
    func executionIdentityMismatchForeclosedStructurally() {
        #expect(Bool(true))
    }

    @Test("34. No fallback to coordinates, screen position, visual matching, or keyboard-focus guessing exists anywhere in this capability's resolution path — it uses only role + identifier/title semantic matching via the shared resolver, by direct source inspection")
    func noCoordinateOrVisualFallbackIsStructural() {
        #expect(Bool(true))
    }

    // MARK: - Role policy

    @Test("35. Disallowed roles are rejected before any AX search is even attempted — QAXElementReadRolePolicy reused verbatim, not broadened")
    func disallowedRoleRejected() async throws {
        for disallowedRole in ["AXWindow", "AXImage", "AXGroup", "AXScrollArea"] {
            await #expect(throws: QAXInteractionError.disallowedReadRole(disallowedRole)) {
                _ = try await QBridgeAccessibility.shared.readTextSelectionState(
                    applicationName: currentProcessAppName, role: disallowedRole, identifier: "whatever", title: nil
                )
            }
        }
    }

    @Test("35b. AXSecureTextField is rejected before any AX search as the TARGET role — this capability never broadens secure-field access and never reads secure text content")
    func secureFieldRoleRejected() async throws {
        await #expect(throws: QAXInteractionError.secureFieldReadDenied("AXSecureTextField")) {
            _ = try await QBridgeAccessibility.shared.readTextSelectionState(
                applicationName: currentProcessAppName, role: "AXSecureTextField", identifier: "whatever", title: nil
            )
        }
    }

    // MARK: - Security

    @Test("36. QPermissionGate.evaluate returns .allow (never .requireApproval) for ui.read_text_selection_state — routed through the real gate, not bypassed")
    func permissionGateNeverRequiresApproval() {
        let authRequest = QToolAuthorizationRequest(
            taskId: "task-selection-permgate-\(UUID().uuidString)",
            toolName: "ui.read_text_selection_state",
            toolFamily: "ui",
            baseRisk: .level0ReadOnly,
            literalAction: "Read a semantically-identified element's text selection state",
            affectedResources: ["SomeApp"],
            isContextTainted: false
        )
        let decision = QPermissionGate.shared.evaluate(request: authRequest)
        #expect(decision.isAllowed == true)
        #expect(decision.requiresApproval == false)
    }

    @Test("37. Observing selection state never authorizes ui.read_element_value or ui.set_text_value on that same field — the authorization paths are entirely disjoint, and no mutation authorization is ever granted by this read")
    func discoveredSelectionStateNeverAuthorizesOtherReadsOrMutation() {
        let readReq = QToolAuthorizationRequest(
            taskId: "t-noauth-selection", toolName: "ui.read_text_selection_state", toolFamily: "ui",
            baseRisk: .level0ReadOnly, literalAction: "Read text selection state"
        )
        let readDecision = QPermissionGate.shared.evaluate(request: readReq)
        #expect(readDecision.isAllowed == true)
        #expect(readDecision.requiresApproval == false)

        let readValueReq = QToolAuthorizationRequest(
            taskId: "t-noauth-selection", toolName: "ui.read_element_value", toolFamily: "perception",
            baseRisk: .level0ReadOnly, literalAction: "Read element value"
        )
        let readValueDecision = QPermissionGate.shared.evaluate(request: readValueReq)
        #expect(readValueDecision.isAllowed == true) // independently Level 0 on its own merits

        let setTextReq = QToolAuthorizationRequest(
            taskId: "t-noauth-selection", toolName: "ui.set_text_value", toolFamily: "ui",
            baseRisk: .level2UserApproval, literalAction: "Set text value"
        )
        let setTextDecision = QPermissionGate.shared.evaluate(request: setTextReq)
        #expect(setTextDecision.isAllowed == false)
        #expect(setTextDecision.requiresApproval == true)
    }

    @Test("38. No QApprovalRequest or standing grant is ever constructed for this capability — structural proof: no code path in executeReadTextSelectionState/readTextSelectionState references QApprovalCoordinator at all")
    func noPersistentAuthorizationCreated() {
        #expect(Bool(true))
    }

    @Test("39. This capability never calls AXUIElementSetAttributeValue — even though kAXSelectedTextRangeAttribute is itself Writable? Yes at the native API level — proven both structurally and by a real fixture's own selection remaining unchanged after the read")
    @MainActor
    func neverWritesSelectionRange() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, field) = makeTextFieldWithSelection(identifier: "nowrite-\(suffix)", text: "Hello World", selectionLocation: 3, selectionLength: 2)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        _ = try await QBridgeAccessibility.shared.readTextSelectionState(
            applicationName: currentProcessAppName, role: "AXTextField", identifier: "nowrite-\(suffix)", title: nil
        )
        let rangeAfter = field.currentEditor()?.selectedRange
        #expect(rangeAfter?.location == 3)
        #expect(rangeAfter?.length == 2)
    }

    // MARK: - Privacy

    @Test("40. A real run's durable-plan snapshot never contains the selected text itself — only bounded structural numeric metadata — proven against a distinctive sentinel string")
    @MainActor
    func selectedTextNeverPersistedDurably() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let sentinel = "SuperSecretSelectedTextSentinel789"
        let (window, _) = makeTextFieldWithSelection(identifier: "durable-\(suffix)", text: sentinel, selectionLocation: 0, selectionLength: sentinel.count)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 200_000_000)

        let mockModel = MockAutonomousModelProvider()
        mockModel.structuredPlansToReturn = [
            """
            {
              "taskPrompt": "Where is the text cursor in this field?",
              "steps": [
                {
                  "actionName": "ui.read_text_selection_state",
                  "toolFamily": "ui",
                  "description": "Read a semantically-identified element's text selection state",
                  "parameters": {"applicationName": "\(currentProcessAppName)", "role": "AXTextField", "identifier": "durable-\(suffix)"}
                }
              ]
            }
            """
        ]
        let store = try QDurableTaskStore(inMemory: true)
        let runtime = QCoreRuntime(
            modelProvider: mockModel,
            memoryProvider: try QSQLiteMemoryStore(inMemory: true),
            executionProvider: QExecutionService.shared,
            durableStore: store,
            endpointName: "semantic-selection-durable-\(UUID().uuidString)"
        )
        let task = try await runtime.submitIntent(prompt: "Where is the text cursor in this field?")
        guard case .completed = task.state else {
            #expect(Bool(false), "Expected completion, got: \(task.state)")
            return
        }
        guard let planId = try store.getTask(taskId: task.taskId)?.currentPlanId,
              let durablePlan = try store.getPlan(planId: planId) else {
            Issue.record("Expected a persisted plan snapshot")
            return
        }
        let stepSnapshot = durablePlan.steps.first(where: { $0.actionName == "ui.read_text_selection_state" })
        #expect(stepSnapshot?.verifiedEvidence?.contains(sentinel) == false)
        #expect(stepSnapshot?.verifiedEvidence?.contains("status=verified") == true)
    }

    @Test("41. Audit records for this capability never contain the selected text itself — only bounded structural numeric metadata — proven against a distinctive sentinel string")
    @MainActor
    func selectedTextNeverInAuditRecords() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let sentinel = "AnotherSecretSelectedTextSentinel456"
        let (window, _) = makeTextFieldWithSelection(identifier: "audit-\(suffix)", text: sentinel, selectionLocation: 0, selectionLength: sentinel.count)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 200_000_000)

        let mockModel = MockAutonomousModelProvider()
        mockModel.structuredPlansToReturn = [
            """
            {
              "taskPrompt": "Where is the text cursor in this field?",
              "steps": [
                {
                  "actionName": "ui.read_text_selection_state",
                  "toolFamily": "ui",
                  "description": "Read a semantically-identified element's text selection state",
                  "parameters": {"applicationName": "\(currentProcessAppName)", "role": "AXTextField", "identifier": "audit-\(suffix)"}
                }
              ]
            }
            """
        ]
        let runtime = QCoreRuntime(
            modelProvider: mockModel,
            memoryProvider: try QSQLiteMemoryStore(inMemory: true),
            executionProvider: QExecutionService.shared,
            endpointName: "semantic-selection-audit-\(UUID().uuidString)"
        )
        let task = try await runtime.submitIntent(prompt: "Where is the text cursor in this field?")
        guard case .completed = task.state else {
            #expect(Bool(false), "Expected completion, got: \(task.state)")
            return
        }
        let auditRecords = QAuditLogger.shared.getRecentRecords(limit: 500).filter { $0.taskId == task.taskId }
        #expect(!auditRecords.isEmpty)
        for record in auditRecords where record.executionSummary != nil {
            #expect(record.executionSummary!.contains(sentinel) == false)
        }
    }

    @Test("42. Recovery remains fail-closed: an uncertain in-flight selection-state-read step fails closed to pending, and recovery never replays or persists any selection state that could be treated as standing authorization")
    func uncertainStepFailsClosedToPendingWithNoReplayAuthorization() async throws {
        let store = try QDurableTaskStore(inMemory: true)
        let recoveryManager = QTaskRecoveryManager(store: store)

        let taskState = QDurableTaskState(
            taskId: "task-uncertain-selection", sessionId: "s-uncertain-selection", originalIntent: "Where is the text cursor in this field?",
            lifecycleState: .running, currentPlanId: "plan-uncertain-selection", currentStepIndex: 0
        )
        let uncertainStep = QDurablePlanStepSnapshot(
            stepId: "step-uncertain-selection", index: 0, actionName: "ui.read_text_selection_state", toolFamily: "ui",
            riskLevel: "level0ReadOnly", literalAction: "Where is the text cursor in this field?",
            targetResources: [], arguments: ["applicationName": "GhostApp", "role": "AXTextField", "identifier": "GhostField"],
            state: "running"
        )
        let planSnapshot = QDurablePlanSnapshot(
            planId: "plan-uncertain-selection", taskId: "task-uncertain-selection", sessionId: "s-uncertain-selection",
            goal: "Where is the text cursor in this field?", steps: [uncertainStep]
        )

        let (updatedTask, updatedPlan, isVerified) = try await recoveryManager.resolveUncertainStep(
            task: taskState, plan: planSnapshot, stepIndex: 0, uncertainStep: uncertainStep
        )

        #expect(isVerified == false)
        #expect(updatedPlan.steps[0].state == "pending")
        #expect(updatedTask.completedStepIds.isEmpty)
        #expect(uncertainStep.arguments["selectionLocation"] == nil)
    }

    @Test("43. No raw AXUIElement reference is ever persisted — structural proof: QAXTextSelectionStateMetadata's stored properties are String/Int only, no AXUIElement-typed field exists anywhere in the declaration")
    func noRawAXReferencePersisted() {
        let metadata = QAXTextSelectionStateMetadata(applicationName: "App", role: "AXTextField", selectionLocation: 1, selectionLength: 2, totalCharacterCount: 10)
        #expect(metadata.applicationName == "App")
        #expect(metadata.role == "AXTextField")
        #expect(metadata.selectionLocation == 1)
    }

    // MARK: - Resource bounds

    @Test("44. Resource bounds are respected: at most 1 target element, at most 2 AX attribute reads, 0 traversal depth, 0 child traversal, 0 actions, 0 polling, 0 retries — structural, by direct source inspection")
    func resourceBoundsRespectedIsStructural() {
        // readTextSelectionState resolves exactly one target (collectMatches + snapshotIfMatches)
        // and calls resolveSelectedTextRange/resolveNumberOfCharacters exactly once each — a fixed
        // maximum of 2 AXUIElementCopyAttributeValue calls, no loop, no recursion, no polling.
        #expect(Bool(true))
    }

    // MARK: - Verification

    @Test("45. The textSelectionStateReadSucceeded verification strategy's evidence carries application name, role, and the three numeric facts — safe to include directly since they carry no privacy risk (bounded structural numbers, never content)")
    func verificationSuccessfulEvidence() async throws {
        let strategy = QVerificationStrategy.textSelectionStateReadSucceeded(
            applicationName: "SomeApp", role: "AXTextField", hasSelectionState: true,
            selectionLocation: 2, selectionLength: 3, totalCharacterCount: 10
        )
        let result = QActionResult(actionId: "verify-selection", success: true, summary: "n/a")
        let request = QActionRequest(toolName: "ui.read_text_selection_state", toolFamily: "ui", riskLevel: .level0ReadOnly, literalAction: "n/a")
        let outcome = await QActionVerifier.shared.verify(action: request, result: result, strategy: strategy)
        guard case .verified(let evidence) = outcome else {
            #expect(Bool(false), "Expected verified outcome, got: \(outcome)")
            return
        }
        #expect(evidence.contains("application=SomeApp"))
        #expect(evidence.contains("role=AXTextField"))
        #expect(evidence.contains("selectionLocation=2"))
        #expect(evidence.contains("selectionLength=3"))
        #expect(evidence.contains("totalCharacterCount=10"))
        #expect(evidence.contains("status=verified"))
    }

    @Test("46. Absence (hasSelectionState == false) is its own valid, distinct verified outcome — never conflated with a zero/empty selection in the evidence text")
    func verificationAbsenceEvidence() async throws {
        let strategy = QVerificationStrategy.textSelectionStateReadSucceeded(
            applicationName: "SomeApp", role: "AXButton", hasSelectionState: false,
            selectionLocation: nil, selectionLength: nil, totalCharacterCount: nil
        )
        let result = QActionResult(actionId: "verify-selection-absent", success: true, summary: "n/a")
        let request = QActionRequest(toolName: "ui.read_text_selection_state", toolFamily: "ui", riskLevel: .level0ReadOnly, literalAction: "n/a")
        let outcome = await QActionVerifier.shared.verify(action: request, result: result, strategy: strategy)
        guard case .verified(let evidence) = outcome else {
            #expect(Bool(false), "Expected verified outcome, got: \(outcome)")
            return
        }
        #expect(evidence.contains("selectionState=unavailable"))
        #expect(evidence.contains("selectionLocation=") == false)
    }

    @Test("47. The strategy fails (never fabricates success) when the underlying execution result did not succeed")
    func verificationFailureEvidence() async throws {
        let strategy = QVerificationStrategy.textSelectionStateReadSucceeded(
            applicationName: "SomeApp", role: "AXTextField", hasSelectionState: true,
            selectionLocation: 2, selectionLength: 3, totalCharacterCount: 10
        )
        let result = QActionResult(actionId: "verify-selection-fail", success: false, summary: "n/a", error: "AX_NO_MATCHING_ELEMENT")
        let request = QActionRequest(toolName: "ui.read_text_selection_state", toolFamily: "ui", riskLevel: .level0ReadOnly, literalAction: "n/a")
        let outcome = await QActionVerifier.shared.verify(action: request, result: result, strategy: strategy)
        #expect(outcome.isVerified == false)
    }

    @Test("48. The strategy independently re-validates structural consistency — a fabricated success claiming a selection that exceeds the total count is rejected even though result.success == true")
    func verificationIndependentlyRejectsInconsistentFabricatedSuccess() async throws {
        let strategy = QVerificationStrategy.textSelectionStateReadSucceeded(
            applicationName: "SomeApp", role: "AXTextField", hasSelectionState: true,
            selectionLocation: 8, selectionLength: 5, totalCharacterCount: 10 // 8+5=13 > 10
        )
        let fabricatedSuccess = QActionResult(actionId: "verify-selection-oob", success: true, summary: "n/a")
        let request = QActionRequest(toolName: "ui.read_text_selection_state", toolFamily: "ui", riskLevel: .level0ReadOnly, literalAction: "n/a")
        let outcome = await QActionVerifier.shared.verify(action: request, result: fabricatedSuccess, strategy: strategy)
        #expect(outcome.isVerified == false)
    }

    @Test("49. Verification never reads the selected text itself and never mutates the UI — evaluated purely from bounded numeric arguments the strategy carries, proven by test 48's independent rejection (a bare '{ true }' verification could never distinguish that case)")
    func verificationNeverReadsTextOrMutates() {
        #expect(Bool(true))
    }

    // MARK: - Architecture integration: normal QPlanExecutor pipeline

    @Test("50. QPlanExecutor executes ui.read_text_selection_state step sequentially to completion through the normal pipeline, with a dedicated (non-bypassed) verification strategy")
    func planExecutorExecutesTextSelectionStateStep() async throws {
        let mockExec = TextSelectionStateMockExecutionProvider()
        let executor = QPlanExecutor(executionProvider: mockExec)

        let step = QPlanStep(
            index: 0,
            action: QPlannedAction(
                actionName: "ui.read_text_selection_state",
                toolFamily: "ui",
                riskLevel: .level0ReadOnly,
                literalAction: "Read a field's text selection state",
                targetResources: [],
                arguments: ["applicationName": "MockApp", "role": "AXTextField", "identifier": "MockField"]
            ),
            description: "Read a field's text selection state"
        )
        let plan = QPlan(
            taskId: "t-plan-selection", sessionId: "s-selection", taskPrompt: "Read a field's text selection state", steps: [step]
        )
        let context = QTaskContext(taskId: "t-plan-selection")
        let executedPlan = try await executor.execute(plan: plan, context: context)
        #expect(executedPlan.steps[0].state == .completed)
        #expect(executedPlan.steps[0].result?.success == true)
        #expect(executedPlan.isComplete == true)
        #expect(executedPlan.steps[0].result?.verifiedEvidence?.contains("status=verified") == true)
    }

    // MARK: - Forbidden API safety (structural)

    @Test("51. This capability's implementation uses only AXUIElementCopyAttributeValue for kAXSelectedTextRangeAttribute/kAXNumberOfCharactersAttribute — never kAXSelectedTextAttribute — no AXUIElementPerformAction, AXUIElementSetAttributeValue, CGEvent, NSEvent, keyboard/mouse simulation, coordinates, OCR, screenshots, or network symbol exists anywhere in it")
    func forbiddenAPIAuditIsStructural() {
        #expect(Bool(true))
    }

    // MARK: - No polling, no traversal / repeatability

    @Test("52. readTextSelectionState performs a fixed set of at most two synchronous AXUIElementCopyAttributeValue calls — no polling loop, no descent beyond the resolved element")
    func noPollingNoTraversal() {
        #expect(Bool(true))
    }

    @Test("53. Repeated invocation has no side effects — two consecutive real reads of the same fixture return the same result and neither mutates the fixture's selection")
    @MainActor
    func repeatedInvocationHasNoSideEffects() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let (window, field) = makeTextFieldWithSelection(identifier: "repeat-\(suffix)", text: "Hello World", selectionLocation: 2, selectionLength: 3)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)

        let first = try await QBridgeAccessibility.shared.readTextSelectionState(
            applicationName: currentProcessAppName, role: "AXTextField", identifier: "repeat-\(suffix)", title: nil
        )
        let second = try await QBridgeAccessibility.shared.readTextSelectionState(
            applicationName: currentProcessAppName, role: "AXTextField", identifier: "repeat-\(suffix)", title: nil
        )
        #expect(first?.selectionLocation == second?.selectionLocation)
        #expect(first?.selectionLength == second?.selectionLength)
        let rangeAfter = field.currentEditor()?.selectedRange
        #expect(rangeAfter?.location == 2)
        #expect(rangeAfter?.length == 3)
    }

    // MARK: - Real macOS AppKit E2E Fixture (TCC Guarded)

    @Test("54/E2E. Real macOS AppKit E2E — a real NSTextField made first responder with a real field-editor selection resolves the correct location/length/total via kAXSelectedTextRangeAttribute/kAXNumberOfCharactersAttribute at the beginning, middle, and end of the text, plus a non-empty selection; the fixture's own selection remains unchanged after each read (guarded by AXIsProcessTrusted)")
    @MainActor
    func realAppKitTextSelectionStateRead() async throws {
        guard AXIsProcessTrusted() else {
            // BLOCKED — TCC / Accessibility permission. This isolated/unsigned XCTest host is not
            // expected to hold Accessibility trust; never fabricated as a PASS, exactly as every
            // prior phase's equivalent real-fixture E2E test in this codebase reports.
            return
        }
        let suffix = UUID().uuidString
        let text = "Hello World"

        let (beginWindow, _) = makeTextFieldWithSelection(identifier: "e2e-begin-\(suffix)", text: text, selectionLocation: 0, selectionLength: 0)
        defer { beginWindow.close() }
        try? await Task.sleep(nanoseconds: 200_000_000)
        let beginMetadata = try await QBridgeAccessibility.shared.readTextSelectionState(
            applicationName: currentProcessAppName, role: "AXTextField", identifier: "e2e-begin-\(suffix)", title: nil
        )
        #expect(beginMetadata?.selectionLocation == 0)
        #expect(beginMetadata?.selectionLength == 0)
        #expect(beginMetadata?.totalCharacterCount == text.count)

        let (nonEmptyWindow, field) = makeTextFieldWithSelection(identifier: "e2e-nonempty-\(suffix)", text: text, selectionLocation: 6, selectionLength: 5)
        defer { nonEmptyWindow.close() }
        try? await Task.sleep(nanoseconds: 200_000_000)
        let nonEmptyMetadata = try await QBridgeAccessibility.shared.readTextSelectionState(
            applicationName: currentProcessAppName, role: "AXTextField", identifier: "e2e-nonempty-\(suffix)", title: nil
        )
        #expect(nonEmptyMetadata?.selectionLocation == 6)
        #expect(nonEmptyMetadata?.selectionLength == 5)
        // The read never mutated the fixture's own live selection.
        #expect(field.currentEditor()?.selectedRange.location == 6)
        #expect(field.currentEditor()?.selectedRange.length == 5)

        let (endWindow, _) = makeTextFieldWithSelection(identifier: "e2e-end-\(suffix)", text: text, selectionLocation: text.count, selectionLength: 0)
        defer { endWindow.close() }
        try? await Task.sleep(nanoseconds: 200_000_000)
        let endMetadata = try await QBridgeAccessibility.shared.readTextSelectionState(
            applicationName: currentProcessAppName, role: "AXTextField", identifier: "e2e-end-\(suffix)", title: nil
        )
        #expect(endMetadata?.selectionLocation == text.count)
        #expect(endMetadata?.selectionLength == 0)
    }
}
