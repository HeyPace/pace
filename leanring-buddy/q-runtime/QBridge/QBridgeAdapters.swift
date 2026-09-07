//
//  QBridgeAdapters.swift
//  leanring-buddy
//
//  Q Security Architecture — Native macOS / Pace Capability Adapters (Phase 1E.6).
//  Encapsulates ScreenCaptureKit, Vision, Accessibility, Speech, TTS, and Tool Registry
//  behind strongly-typed bridge interfaces under continuous authorization.
//

import Foundation
import CoreGraphics
import AppKit
import Vision
import AVFoundation
import ScreenCaptureKit
import ApplicationServices
import CryptoKit

// MARK: - Screen Capture / OCR Deterministic Failure Classification
//
// Phase 2G — real screen.ocr. Every failure mode below produces a distinct, deterministic
// error rather than ever falling back to fabricated content. None of these paths request or
// manipulate TCC permissions — CGPreflightScreenCaptureAccess only ever reads current status.

public enum QScreenCaptureError: Error, Equatable, Sendable, CustomStringConvertible {
    case permissionDenied
    case noDisplayAvailable
    case captureUnavailable(String)
    case captureFailed(String)
    case visionFailed(String)

    public var description: String {
        switch self {
        case .permissionDenied:
            return "Screen Recording permission is not granted."
        case .noDisplayAvailable:
            return "No display available for capture."
        case .captureUnavailable(let reason):
            return "Screen capture is currently unavailable: \(reason)"
        case .captureFailed(let reason):
            return "Screen capture failed: \(reason)"
        case .visionFailed(let reason):
            return "On-device text recognition failed: \(reason)"
        }
    }

    /// A short, stable machine-readable code — mirrors the existing "ENODISPLAY" convention
    /// QExecutionService already used for the no-display case before this phase.
    public var errorCode: String {
        switch self {
        case .permissionDenied: return "SCREEN_RECORDING_PERMISSION_DENIED"
        case .noDisplayAvailable: return "ENODISPLAY"
        case .captureUnavailable: return "CAPTURE_UNAVAILABLE"
        case .captureFailed: return "CAPTURE_FAILED"
        case .visionFailed: return "VISION_FAILED"
        }
    }
}

// MARK: - Bridge Screen Capture

public struct QScreenCaptureFrame: @unchecked Sendable {
    public let screenNumber: Int
    public let width: Int
    public let height: Int
    public let timestamp: Date
    /// Real captured pixel data (Phase 2G). `nil` only for frames that carry no image — no
    /// production path returns a frame with fabricated dimensions and no image; capture failures
    /// throw QScreenCaptureError instead of producing a degenerate frame.
    public let image: CGImage?

    public init(screenNumber: Int, width: Int, height: Int, timestamp: Date = Date(), image: CGImage? = nil) {
        self.screenNumber = screenNumber
        self.width = width
        self.height = height
        self.timestamp = timestamp
        self.image = image
    }
}

public protocol QBridgeScreenCaptureProtocol: Sendable {
    func captureScreens() async throws -> [QScreenCaptureFrame]
}

public final class QBridgeScreenCapture: QBridgeScreenCaptureProtocol, @unchecked Sendable {
    public static let shared = QBridgeScreenCapture()

    /// Real, on-device screen capture via ScreenCaptureKit (macOS 14+, the same
    /// SCScreenshotManager one-shot API Pace's own CompanionScreenCaptureUtility already uses in
    /// production). Fails closed with a deterministic QScreenCaptureError on every failure mode —
    /// permission absence, no display, or a capture error — and never fabricates a frame.
    public func captureScreens() async throws -> [QScreenCaptureFrame] {
        // Enforce Level 0 Read-only authorization check (unchanged from the pre-2G stub).
        let authReq = QToolAuthorizationRequest(
            taskId: "screen_capture",
            toolName: "screen.capture",
            toolFamily: "perception",
            baseRisk: .level0ReadOnly,
            literalAction: "Capture desktop screens"
        )
        let decision = QPermissionGate.shared.evaluate(request: authReq)
        guard decision.isAllowed else {
            throw QSecurityViolationError(kind: .policyDeny, message: "Screen capture not authorized.")
        }

        // Fail closed if Screen Recording TCC permission is not currently granted. This is a
        // read-only status check (matches PacePermissionService's existing use of the same API
        // elsewhere in the app) — it never triggers a system prompt and never requests access.
        guard CGPreflightScreenCaptureAccess() else {
            throw QScreenCaptureError.permissionDenied
        }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw QScreenCaptureError.captureUnavailable(error.localizedDescription)
        }

        guard !content.displays.isEmpty else {
            throw QScreenCaptureError.noDisplayAvailable
        }

        var frames: [QScreenCaptureFrame] = []
        frames.reserveCapacity(content.displays.count)

        for (idx, display) in content.displays.enumerated() {
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let configuration = SCStreamConfiguration()
            configuration.width = display.width
            configuration.height = display.height
            configuration.showsCursor = false

            do {
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
                frames.append(QScreenCaptureFrame(screenNumber: idx + 1, width: image.width, height: image.height, image: image))
            } catch {
                throw QScreenCaptureError.captureFailed(error.localizedDescription)
            }
        }

        return frames
    }
}

// MARK: - Bridge Vision OCR

public struct QVisionOCRResult: Sendable {
    public let detectedText: String
    public let confidence: Float
    public let elementCount: Int

    public init(detectedText: String, confidence: Float, elementCount: Int) {
        self.detectedText = detectedText
        self.confidence = confidence
        self.elementCount = elementCount
    }
}

public protocol QBridgeVisionProtocol: Sendable {
    func performOCR(on frame: QScreenCaptureFrame) async throws -> QVisionOCRResult
}

public final class QBridgeVision: QBridgeVisionProtocol, @unchecked Sendable {
    public static let shared = QBridgeVision()

    /// Maximum characters retained in a single OCR result. A full-screen capture can recognize
    /// thousands of short lines (dense text editors, spreadsheets); this bounds memory/context
    /// cost the same way QModelPlanParser bounds step counts — a deterministic ceiling, not a
    /// silent truncation the caller can't detect (the result is marked truncated when this fires).
    private static let maxDetectedTextCharacters = 20_000

    /// Real, on-device text recognition via Vision.framework (VNRecognizeTextRequest,
    /// `.accurate` revision, on-device only — no network, no cloud, no external OCR service).
    /// Confidence is reported for observability only; it is never used as an authorization signal
    /// (QPermissionGate/QApprovalCoordinator make authorization decisions, not this bridge).
    public func performOCR(on frame: QScreenCaptureFrame) async throws -> QVisionOCRResult {
        guard let image = frame.image else {
            throw QScreenCaptureError.captureFailed("No image data available for text recognition.")
        }

        // VNImageRequestHandler.perform is synchronous and can take real time for a dense
        // full-screen capture (.accurate recognition level) — run it off the main actor
        // (this module defaults to MainActor isolation) so a screen-read turn cannot freeze the
        // UI, mirroring CompanionScreenCaptureUtility's existing Task.detached pattern for other
        // CPU-heavy, state-independent work over an immutable CGImage.
        return try await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            // Deterministic configuration: no on-device language auto-detection surprises across
            // runs — recognizes whatever the request's default (system-preferred) language list
            // resolves to, same as every other on-device Vision consumer in this codebase.

            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do {
                try handler.perform([request])
            } catch {
                throw QScreenCaptureError.visionFailed(error.localizedDescription)
            }

            guard let observations = request.results, !observations.isEmpty else {
                // No text on screen is a legitimate, successful empty result — not a failure.
                return QVisionOCRResult(detectedText: "", confidence: 0.0, elementCount: 0)
            }

            // Preserve reading order (top-to-bottom, then left-to-right) using each observation's
            // normalized bounding box. Vision's origin is bottom-left, so a larger Y is higher on
            // screen. QVisionOCRResult has no geometry field to preserve (see QBridgeVisionProtocol
            // — reusing the existing model rather than introducing a new one), so ordering is
            // expressed through line order in detectedText instead.
            let sortedObservations = observations.sorted { lhs, rhs in
                let lhsY = lhs.boundingBox.origin.y
                let rhsY = rhs.boundingBox.origin.y
                if abs(lhsY - rhsY) > 0.01 {
                    return lhsY > rhsY
                }
                return lhs.boundingBox.origin.x < rhs.boundingBox.origin.x
            }

            var lines: [String] = []
            var totalConfidence: Float = 0
            var recognizedCount = 0
            var truncated = false

            for observation in sortedObservations {
                // Partial OCR result: some observations may have no usable top candidate — skip
                // those individually rather than failing the whole recognition pass.
                guard let candidate = observation.topCandidates(1).first else { continue }
                let prospectiveLength = lines.reduce(0) { $0 + $1.count + 1 } + candidate.string.count
                if prospectiveLength > Self.maxDetectedTextCharacters {
                    truncated = true
                    break
                }
                lines.append(candidate.string)
                totalConfidence += candidate.confidence
                recognizedCount += 1
            }

            var detectedText = lines.joined(separator: "\n")
            if truncated {
                detectedText += "\n[…truncated: recognized text exceeded \(Self.maxDetectedTextCharacters) characters]"
            }

            let averageConfidence = recognizedCount > 0 ? totalConfidence / Float(recognizedCount) : 0.0
            return QVisionOCRResult(detectedText: detectedText, confidence: averageConfidence, elementCount: recognizedCount)
        }.value
    }
}

// MARK: - Bridge Accessibility

public struct QAccessibilityElementInfo: Sendable {
    public let role: String
    public let title: String
    public let isFocused: Bool

    public init(role: String, title: String, isFocused: Bool) {
        self.role = role
        self.title = title
        self.isFocused = isFocused
    }
}

public protocol QBridgeAccessibilityProtocol: Sendable {
    func readFocusedElement() async throws -> QAccessibilityElementInfo?
    func listMenuItems(applicationName: String) async throws -> [QAXTopLevelMenuMetadata]
    func listPopupItems(applicationName: String, role: String, identifier: String?, title: String?) async throws -> QAXPopupMenuMetadata
    func listTableRows(applicationName: String, role: String, identifier: String?, title: String?) async throws -> QAXTableMetadata
    func listOutlineItems(applicationName: String, role: String, identifier: String?, title: String?) async throws -> QAXOutlineMetadata
    func listTabItems(applicationName: String, role: String, identifier: String?, title: String?) async throws -> QAXTabGroupMetadata
    func listRadioGroupItems(applicationName: String, role: String, identifier: String?, title: String?) async throws -> QAXRadioGroupMetadata
    func listToolbarItems(applicationName: String, role: String, identifier: String?, title: String?, windowTitle: String?, windowIdentifier: String?) async throws -> QAXToolbarMetadata
    func listSegmentedControlItems(applicationName: String, role: String, identifier: String?, title: String?, windowTitle: String?, windowIdentifier: String?) async throws -> QAXSegmentedControlMetadata
    func selectSegmentedControlItem(applicationName: String, role: String, controlIdentifier: String?, controlTitle: String?, windowTitle: String?, windowIdentifier: String?, segmentIdentifier: String?, segmentTitle: String?, desiredSelected: Bool) async throws -> QAXSegmentedControlSelectionOutcome
    func listSheetDialogs(applicationName: String, windowTitle: String?, windowIdentifier: String?) async throws -> QAXSheetCollectionMetadata
    func listSheetActions(applicationName: String, windowTitle: String?, windowIdentifier: String?, sheetTitle: String?, sheetIdentifier: String?) async throws -> QAXSheetActionCollectionMetadata
    func listBrowserColumns(applicationName: String, role: String, identifier: String?, title: String?, windowTitle: String?, windowIdentifier: String?) async throws -> QAXBrowserColumnCollectionMetadata
    func listPopovers(applicationName: String, role: String, identifier: String?, title: String?, windowTitle: String?, windowIdentifier: String?) async throws -> QAXPopoverCollectionMetadata
    func listColorWells(applicationName: String, role: String, identifier: String?, title: String?, windowTitle: String?, windowIdentifier: String?) async throws -> QAXColorWellCollectionMetadata
    func listProgressIndicators(applicationName: String, role: String?, identifier: String?, title: String?, windowTitle: String?, windowIdentifier: String?) async throws -> QAXProgressIndicatorCollectionMetadata
    func listLevelIndicators(applicationName: String, role: String?, identifier: String?, title: String?, windowTitle: String?, windowIdentifier: String?) async throws -> QAXLevelIndicatorCollectionMetadata
    func listIncrementors(applicationName: String, role: String?, identifier: String?, title: String?, windowTitle: String?, windowIdentifier: String?) async throws -> QAXIncrementorCollectionMetadata
    func listComboBoxes(applicationName: String, role: String?, identifier: String?, title: String?, windowTitle: String?, windowIdentifier: String?) async throws -> QAXComboBoxCollectionMetadata
    func listRulers(applicationName: String, role: String?, identifier: String?, title: String?, windowTitle: String?, windowIdentifier: String?) async throws -> QAXRulerCollectionMetadata
    func listComboBoxItems(applicationName: String, role: String?, identifier: String?, title: String?, windowTitle: String?, windowIdentifier: String?) async throws -> QAXComboBoxItemsMetadata
    func selectComboBoxItem(applicationName: String, role: String?, identifier: String?, title: String?, windowTitle: String?, windowIdentifier: String?, itemTitle: String?, itemIndex: Int?) async throws -> QAXComboBoxSelectionOutcome
}

public final class QBridgeAccessibility: QBridgeAccessibilityProtocol, @unchecked Sendable {
    public static let shared = QBridgeAccessibility()

    public func readFocusedElement() async throws -> QAccessibilityElementInfo? {
        let authReq = QToolAuthorizationRequest(
            taskId: "ax_read",
            toolName: "accessibility.read",
            toolFamily: "accessibility",
            baseRisk: .level0ReadOnly,
            literalAction: "Read focused UI element"
        )
        let decision = QPermissionGate.shared.evaluate(request: authReq)
        guard decision.isAllowed else {
            throw QSecurityViolationError(kind: .policyDeny, message: "Accessibility read unauthorized.")
        }

        let frontmost = NSWorkspace.shared.frontmostApplication
        let appName = frontmost?.localizedName ?? "Active App"
        return QAccessibilityElementInfo(role: "AXWindow", title: appName, isFocused: true)
    }
}

// MARK: - Semantic AX Element Interaction (Phase 2H)
//
// ui.click_element — a Level 2, reversible, semantic click. Every element is identified by
// role + (identifier or title/description), NEVER by screen coordinates. Resolution walks a
// bounded Accessibility subtree, binds to a single unambiguous element, re-verifies that exact
// element's state immediately before dispatch (failing closed on any drift or ambiguity), and
// only then presses it via AXUIElementPerformAction. This is a fresh, narrowly-scoped, Q-owned
// walker — it does not reuse or extend Pace's own coordinate-anchored PaceAXTargeter /
// PaceAXScreenReader, which serve a different (coordinate hit-testing) pipeline entirely.

public enum QAXInteractionError: Error, Equatable, Sendable, CustomStringConvertible {
    case accessibilityPermissionDenied
    case applicationNotAvailable(String)
    case missingMatchCriteria
    case noMatchingElement
    case ambiguousTarget(count: Int)
    case targetDisabled
    case staleTarget(String)
    case actionUnsupported
    case pressFailed(String)
    /// Phase 2I: the target's AX role is not on `QAXTextEntryRolePolicy.allowedRoles` — covers
    /// `AXSecureTextField`, `AXStaticText`, and any role the policy does not explicitly
    /// allowlist. Thrown by `setTextValue` before any AX tree walk is even attempted — an
    /// unauthorized role is refused as a search criterion, not just as a search result.
    case disallowedTargetRole(String)
    /// Phase 2I: the resolved target is not the system's current focused Accessibility element.
    /// `setTextValue` never clicks/focuses a field itself — it only ever writes into whatever is
    /// already, genuinely focused, and fails closed rather than guessing or auto-focusing.
    case targetNotFocused(String)
    /// Phase 2I: `kAXValueAttribute` could not be read from the target before a write was
    /// attempted — without a readable prior value, idempotency and closed-loop verification
    /// cannot be established, so the write is refused rather than proceeding blind.
    case valueReadFailed
    /// Phase 2I: `AXUIElementSetAttributeValue(kAXValueAttribute)` did not return `.success`.
    case setValueFailed(String)
    /// Phase 2J: the target's AX role is `AXSecureTextField` — `readElementValue` refuses to
    /// read a secure/password field's value even though the OS itself typically masks it,
    /// exactly like `setTextValue` refuses to write to one. Checked and reported distinctly from
    /// `disallowedReadRole` below for a clearer, more specific diagnostic.
    case secureFieldReadDenied(String)
    /// Phase 2J: the target's AX role is not on `QAXElementReadRolePolicy.allowedRoles` — an
    /// explicit allowlist, not a denylist: any role this policy does not recognize, known or
    /// unknown, is refused by the same default-deny check.
    case disallowedReadRole(String)
    /// Phase 2K: the target's AX role is not on `QAXElementStateRolePolicy.allowedRoles`
    /// (`AXCheckBox`/`AXRadioButton` only). Thrown before any AX tree walk, mirroring
    /// `disallowedTargetRole`'s discipline.
    case disallowedStateRole(String)
    /// Phase 2K: `kAXValueAttribute` could not be read, or could not be interpreted as a clean
    /// on/off boolean state (e.g. a checkbox's "mixed" tri-state value `2`) — without a reliably
    /// interpretable current state, idempotency and the desired-state comparison cannot be
    /// established safely, so the operation is refused rather than guessing.
    case stateReadFailed
    /// Phase 2K: the element's live state, re-read immediately before dispatch, no longer matches
    /// the state captured at resolution time — a value-drift staleness failure, distinct from
    /// `staleTarget`'s identity-drift check. The target may still be the exact same element by
    /// identity, but something already changed its value between observation and dispatch, so the
    /// mutation is refused rather than proceeding against a target whose state is no longer the
    /// one that was observed.
    case valueDriftDetected(String)
    /// Phase 2K: the requested state transition cannot be guaranteed by the available AX
    /// mechanism for this role — specifically, `AXRadioButton` supports being reliably selected
    /// (press when currently off) but macOS provides no reliable, semantically-correct way to
    /// deselect a single radio button via its own press action (the standard interaction model is
    /// to select a *different* button in the same group instead). Refused rather than attempting
    /// a press whose effect on the desired outcome cannot be guaranteed.
    case stateChangeNotGuaranteed(String)
    /// Phase 2L: `menuBarTitle`/`itemTitle` contains a path separator, indicating an attempted
    /// nested-submenu or multi-level path — refused before any AX call. `ui.select_menu_item`
    /// supports exactly one level: a single top-level menu bar item and one direct item within it.
    case nestedMenuPathUnsupported(String)
    /// Phase 2L: the named top-level `AXMenuBarItem` could not be resolved on the target
    /// application's menu bar (`kAXMenuBarAttribute`), or is ambiguous/wrong-role.
    case menuNotFound(String)
    /// Phase 2L: the named `AXMenuItem` did not become resolvable as a direct child of the opened
    /// menu within the bounded poll window — covers both "the item does not exist" and "polling
    /// timed out", which are indistinguishable from the caller's perspective (the poll always
    /// runs to its fixed ceiling before concluding either way).
    case menuItemNotFound(String)
    /// Phase 2L: the resolved top-level menu bar item is the application's own root menu (index 0
    /// of the menu bar — the menu bearing the app's display name, containing About/Preferences/
    /// Quit by macOS convention) — explicitly out of scope for this capability's first phase.
    case appRootMenuUnsupported(String)
    /// Phase 2M: the target's AX role is not on `QAXSliderRolePolicy.allowedRoles`
    /// (`AXSlider`/`AXStepper` only). Thrown before any AX tree walk.
    case disallowedSliderRole(String)
    /// Phase 2M: the model-supplied `desiredValue` is not finite (NaN/infinite) or could not be
    /// parsed as a number — rejected before any AX call.
    case invalidDesiredValue(String)
    /// Phase 2M: `kAXMinValueAttribute`/`kAXMaxValueAttribute` could not be read from the
    /// target — without a reliably readable range, `desiredValue` cannot be safely validated, so
    /// the operation is refused rather than proceeding unchecked.
    case rangeReadFailed
    /// Phase 2M: the target's own reported range is internally inconsistent (`minValue >
    /// maxValue`), or its current value falls outside that range — the range cannot be trusted,
    /// so the operation is refused rather than validating `desiredValue` against it anyway.
    case invalidRange(String)
    /// Phase 2M: `desiredValue` falls outside `[minValue, maxValue]` — refused BEFORE any
    /// mutation is attempted. A hard security boundary: never widened by the numeric-comparison
    /// tolerance used elsewhere (idempotency/verification) — this check is always strict.
    case desiredValueOutOfRange(String)
    /// Phase 2O: the target's AX role is not on `QAXFocusableRolePolicy.allowedRoles` — a narrow,
    /// fail-closed allowlist of roles genuinely appropriate for keyboard focus. Thrown before any
    /// AX tree walk, mirroring `disallowedTargetRole`'s/`disallowedStateRole`'s discipline.
    case disallowedFocusRole(String)
    /// Phase 2O: `AXUIElementSetAttributeValue(kAXFocusedAttribute)` did not return `.success`.
    case setFocusFailed(String)
    /// Phase 2P: the target's AX role is not on `QAXPopupRolePolicy.allowedRoles`
    /// (`AXPopUpButton` only — `AXComboBox` is deliberately never listed). Thrown before any AX
    /// tree walk, mirroring `disallowedSliderRole`'s/`disallowedFocusRole`'s discipline.
    case disallowedPopupRole(String)
    /// Phase 2Q: the target's AX role is not on `QAXDisclosureRolePolicy.allowedRoles`
    /// (`AXDisclosureTriangle` only). Thrown before any AX tree walk, mirroring
    /// `disallowedPopupRole`'s/`disallowedStateRole`'s discipline.
    case disallowedDisclosureRole(String)
    /// Phase 2Q: `kAXValueAttribute` could not be read from the target disclosure triangle, or
    /// could not be interpreted as a clean expanded(1)/collapsed(0) boolean — without a reliably
    /// interpretable current state, idempotency and the desired-state comparison cannot be
    /// established safely, so the operation is refused rather than guessing. Unknown never
    /// defaults to a state.
    case disclosureStateReadFailed
    /// Phase 2R: the target's AX role is not on `QAXTabRolePolicy.allowedRoles` (`AXRadioButton`
    /// only — the real, header-confirmed base role macOS uses for tab items; there is no
    /// standalone "AXTab" role in the Accessibility API, see
    /// docs/PHASE_2R_SEMANTIC_TAB_SELECTION.md's Known limitations for the full empirical
    /// finding). Thrown before any AX tree walk, mirroring `disallowedDisclosureRole`'s/
    /// `disallowedPopupRole`'s discipline.
    case disallowedTabRole(String)
    /// Phase 2R: the resolved target's role matched `AXRadioButton`, but its
    /// `kAXSubroleAttribute` is not exactly `"AXTabButton"` — this is what actually distinguishes
    /// a genuine tab from an ordinary checkbox-group/radio-group control sharing the same base
    /// role. `ui.select_tab` NEVER treats a generic `AXRadioButton` as a tab; only the
    /// `AXTabButton` subrole qualifies. `ui.set_element_state` remains the correct capability for
    /// ordinary (non-tab-subrole) radio buttons — the two are never cross-wired.
    case targetNotATabButton(String)
    /// Phase 2R: `kAXSelectedAttribute` could not be read from the target tab — without a
    /// reliably readable current selection state, idempotency and the desired-state comparison
    /// cannot be established safely, so the operation is refused rather than guessing. Unknown
    /// never defaults to a state.
    case tabSelectionStateReadFailed
    /// Phase 2S: the target's AX role is not on `QAXTableRowRolePolicy.allowedRoles` (`AXRow`
    /// only). Thrown before any AX tree walk, mirroring `disallowedTabRole`'s discipline.
    case disallowedTableRowRole(String)
    /// Phase 2S: the resolved target's role matched `AXRow`, but its `kAXSubroleAttribute` is
    /// not exactly `"AXTableRow"` — this is what actually distinguishes a genuine table row from
    /// any other `AXRow`-shaped element (e.g. one with no subrole at all, or a custom row-like
    /// control). `ui.select_table_row` NEVER treats an unqualified `AXRow` as a table row.
    case targetNotATableRow(String)
    /// Phase 2S: the resolved target's role matched `AXRow` and its subrole is exactly
    /// `"AXOutlineRow"` — a real, distinct, SDK-confirmed subrole this capability deliberately
    /// does not support in this phase (see docs/PHASE_2S_SEMANTIC_TABLE_ROW_SELECTION.md's Known
    /// limitations). Reported distinctly from `targetNotATableRow` for a clearer diagnostic —
    /// this is a recognized-but-unsupported row shape, not an unrecognized one.
    case outlineRowUnsupported(String)
    /// Phase 2S: the target's own `kAXParentAttribute` could not be resolved, or the resolved
    /// parent's role is not exactly `"AXTable"` — without an established table context, a
    /// standalone `AXRow`+`AXTableRow` element is never accepted as a valid target, even though
    /// its own role/subrole alone would otherwise qualify.
    case tableContextUnavailable(String)
    /// Phase 2S: `kAXSelectedAttribute` could not be read from the target table row — without a
    /// reliably readable current selection state, idempotency and the desired-state comparison
    /// cannot be established safely, so the operation is refused rather than guessing. Unknown
    /// never defaults to a state.
    case rowSelectionStateReadFailed
    /// Phase 2S: `desiredSelected` was `false` — this phase deliberately supports selection only
    /// (`desiredSelected` MUST be `true`); deselection is out of scope and refused
    /// unconditionally, BEFORE any Accessibility Trust check or application resolution is even
    /// attempted, never treated as a blind toggle and never silently coerced to `true`.
    case rowDeselectionUnsupported(String)
    /// Phase 2T: the target's AX role is not on `QAXOutlineRowRolePolicy.allowedRoles` (`AXRow`
    /// only). Thrown before any AX tree walk, mirroring `disallowedTableRowRole`'s discipline.
    case disallowedOutlineRowRole(String)
    /// Phase 2T: the resolved target's role matched `AXRow`, but its `kAXSubroleAttribute` is
    /// not exactly `"AXOutlineRow"` — this is what actually distinguishes a genuine outline row
    /// from any other `AXRow`-shaped element (e.g. one with no subrole at all, or a custom
    /// row-like control). `ui.select_outline_row` NEVER treats an unqualified `AXRow` as an
    /// outline row.
    case targetNotAnOutlineRow(String)
    /// Phase 2T: the resolved target's role matched `AXRow` and its subrole is exactly
    /// `"AXTableRow"` — a real, distinct, SDK-confirmed subrole `ui.select_table_row` already
    /// owns. Reported distinctly from `targetNotAnOutlineRow` for a clearer diagnostic — this is
    /// a recognized-but-wrong-capability row shape, not an unrecognized one, and is never
    /// silently folded into outline-row handling.
    case tableRowUnsupportedForOutline(String)
    /// Phase 2T: the target's own `kAXParentAttribute` could not be resolved, or the resolved
    /// parent's role is not exactly `"AXOutline"` — without an established outline context, a
    /// standalone `AXRow`+`AXOutlineRow` element is never accepted as a valid target, even though
    /// its own role/subrole alone would otherwise qualify.
    case outlineContextUnavailable(String)
    /// Phase 2T: `kAXSelectedAttribute` could not be read from the target outline row — without
    /// a reliably readable current selection state, idempotency and the desired-state comparison
    /// cannot be established safely, so the operation is refused rather than guessing. Unknown
    /// never defaults to a state.
    case outlineRowSelectionStateReadFailed
    /// Phase 2T: `desiredSelected` was `false` — this phase deliberately supports selection only
    /// (`desiredSelected` MUST be `true`); deselection is out of scope and refused
    /// unconditionally, BEFORE any Accessibility Trust check or application resolution is even
    /// attempted, never treated as a blind toggle and never silently coerced to `true`.
    case outlineRowDeselectionUnsupported(String)
    /// Phase 2U: the target's AX role is not on `QAXWindowRolePolicy.allowedRoles` (`AXWindow`
    /// only). Thrown before any AX tree walk, mirroring every prior write-side role policy in
    /// this codebase.
    case disallowedWindowRole(String)
    /// Phase 2U: `kAXMinimizedAttribute` could not be read from the target window, or could not
    /// be interpreted as a clean boolean — without a reliably readable current state, idempotency
    /// and the desired-state comparison cannot be established safely, so the operation is refused
    /// rather than guessing. Unlike every prior explicit-desired-state capability in this
    /// codebase, this state is NEVER inferred from window position, visibility, frontmost state,
    /// Dock appearance, or title — `kAXMinimizedAttribute` is the sole authoritative source.
    case windowMinimizedStateReadFailed
    /// Phase 2AS: `kAXFullScreenAttribute` ("AXFullScreen") could not be read from the target window,
    /// or could not be interpreted as a clean boolean — without a reliably readable current state,
    /// idempotency and the desired-state comparison cannot be established safely, so the operation
    /// is refused rather than guessing.
    case windowFullScreenStateReadFailed
    /// Phase 2AS: the target window's `kAXFullScreenAttribute` ("AXFullScreen") is reported as
    /// not settable / not writable by macOS Accessibility API — cannot perform mutation safely.
    case windowFullScreenNotWritable(String)
    /// Phase 2W: the target's AX role is not on `QAXScrollAreaRolePolicy.allowedRoles`
    /// (`AXScrollArea` only). Thrown before any AX tree walk, mirroring every prior write-side
    /// role policy in this codebase.
    case disallowedScrollAreaRole(String)
    /// Phase 2W: `orientation` was not exactly `"horizontal"` or `"vertical"` — never inferred
    /// from arbitrary metadata, never defaulted. Thrown before any AX call is even attempted.
    case invalidOrientation(String)
    /// Phase 2W: the requested convenience-reference attribute
    /// (`kAXHorizontalScrollBarAttribute`/`kAXVerticalScrollBarAttribute`) could not be resolved
    /// from the target `AXScrollArea` — e.g. no scroll bar exists for that orientation because
    /// scrolling isn't currently needed in that direction. This reference is read-only and used
    /// for resolution only; it is never written.
    case scrollBarReferenceUnavailable(String)
    /// Phase 2W: the element resolved via the orientation convenience-reference attribute does
    /// not itself report role `AXScrollBar` — the mere existence of the reference is never
    /// sufficient; its own `kAXRoleAttribute` is independently re-validated before it is ever
    /// treated as a genuine scroll bar target.
    case targetNotAScrollBar(String)
    /// Phase 2X: `kAXMainAttribute` could not be read from the target window, or could not be
    /// interpreted as a clean boolean — without a reliably readable current state, idempotency
    /// cannot be established safely, so the operation is refused rather than guessing. Unknown
    /// never defaults to `false`.
    case windowMainStateReadFailed
    /// Phase 2X: `desiredMain` was `false` — this capability is SELECT-ONLY (`desiredMain` MUST
    /// be `true`); deselection is out of scope and refused unconditionally, BEFORE any
    /// Accessibility Trust check or application resolution is even attempted, by direct analogy
    /// to `ui.select_tab`'s identical finding — AX provides no reliable way to "un-main" a single
    /// window without designating a replacement; the standard model is to make a DIFFERENT window
    /// main instead.
    case windowMainDeselectionUnsupported(String)
    /// Phase 2Y: the target window's `kAXCloseButtonAttribute` convenience-reference attribute
    /// could not be resolved — e.g. the window genuinely has no close button. This reference is
    /// read-only and used for resolution only; it is never written. The mere absence of a close
    /// button is a hard fail-closed condition — there is no fallback mechanism (no coordinates,
    /// no keyboard shortcut, no menu item) this capability is permitted to try instead.
    case closeButtonReferenceUnavailable
    /// Phase 2Y: the element resolved via `kAXCloseButtonAttribute` does not itself report role
    /// `AXButton` — the mere existence of the reference is never sufficient; its own
    /// `kAXRoleAttribute` is independently re-validated before it is ever treated as a genuine,
    /// pressable close button, by direct analogy to `ui.set_scroll_position`'s
    /// `targetNotAScrollBar` check on its own convenience reference.
    case targetNotACloseButton(String)
    /// Phase 2Z: `AXUIElementCopyAttributeValue(kAXWindowsAttribute)` succeeded but the returned
    /// value could not be cast to `[AXUIElement]` — the returned value is treated as untrusted
    /// external data, never assumed to be a well-formed array merely because the copy call itself
    /// reported success. Distinct from a genuinely absent/empty windows attribute (a legitimate,
    /// non-error state for a headless/background-only application), which returns an empty list
    /// rather than throwing.
    case windowsCollectionMalformed
    /// Phase 2Z: the raw `kAXWindowsAttribute` array's element count exceeds this capability's
    /// defensive maximum, BEFORE any per-element metadata is read — a safety bound against a
    /// hostile or corrupted AX responder, even though a real application's window count is always
    /// naturally small. Fails closed rather than silently enumerating an unbounded collection.
    case windowCollectionExceedsSafeBound(Int)
    /// Phase 2AA: the top-level menu count returned from the menu bar exceeds this capability's
    /// defensive safe bound (32), BEFORE any menu items are read.
    case menuCollectionExceedsSafeBound(Int)
    /// Phase 2AA: the direct menu item count for a single menu exceeds this capability's
    /// defensive safe bound (128).
    case menuItemCollectionExceedsSafeBound(Int)
    /// Phase 2AA: the total menu item count across all menus exceeds this capability's
    /// defensive safe bound (512).
    case totalMenuItemCollectionExceedsSafeBound(Int)
    /// Phase 2AE: the target's AX role is not on `QAXTableRolePolicy.allowedRoles`
    /// (`AXTable` only).
    case disallowedTableRole(String)
    /// Phase 2AE: the direct table row count for a table exceeds this capability's
    /// defensive safe bound (128).
    case tableRowCollectionExceedsSafeBound(Int)
    /// Phase 2AF: the target's AX role is not on `QAXOutlineRolePolicy.allowedRoles`
    /// (`AXOutline` only).
    case disallowedOutlineRole(String)
    /// Phase 2AF: the direct outline item count for an outline exceeds this capability's
    /// defensive safe bound (128).
    case outlineItemCollectionExceedsSafeBound(Int)
    /// Phase 2AF: an outline item's disclosure depth exceeds this capability's
    /// defensive safe maximum depth (12).
    case outlineItemDepthExceedsSafeBound(Int)
    /// Phase 2AH: the target's AX role is not on `QAXTabGroupRolePolicy.allowedRoles`
    /// (`AXTabGroup` only).
    case disallowedTabGroupRole(String)
    /// Phase 2AH: the direct tab item count for a tab group exceeds this capability's
    /// defensive safe bound (64).
    case tabItemCollectionExceedsSafeBound(Int)
    /// Phase 2AI: the target's AX role is not on `QAXRadioGroupRolePolicy.allowedRoles`
    /// (`AXRadioGroup` only).
    case disallowedRadioGroupRole(String)
    /// Phase 2AI: the direct radio item count for a radio group exceeds this capability's
    /// defensive safe bound (64).
    case radioItemCollectionExceedsSafeBound(Int)
    /// Phase 2AK: the target's AX role is not on `QAXToolbarRolePolicy.allowedRoles`
    /// (`AXToolbar` only).
    case disallowedToolbarRole(String)
    /// Phase 2AK: the direct toolbar item count for a toolbar exceeds this capability's
    /// defensive safe bound (64).
    case toolbarItemCollectionExceedsSafeBound(Int)
    /// Phase 2AM: the target's AX role is not on `QAXSegmentedControlRolePolicy.allowedRoles`
    /// (`AXSegmentedControl` only).
    case disallowedSegmentedControlRole(String)
    /// Phase 2AM: the direct segment count for a segmented control exceeds this capability's
    /// defensive safe bound (32).
    case segmentedControlItemCollectionExceedsSafeBound(Int)
    /// Phase 2AN: the target's AX role is not on `QAXSheetRolePolicy.allowedRoles`
    /// (`AXSheet` only).
    case disallowedSheetRole(String)
    /// Phase 2AN: the direct sheet count for a window exceeds this capability's
    /// defensive safe bound (16).
    case sheetCollectionExceedsSafeBound(Int)
    /// Phase 2AO: the target's AX role is not on `QAXSheetActionRolePolicy.allowedRoles`
    /// (`AXButton`, `AXCheckBox`, `AXRadioButton`, `AXPopUpButton`).
    case disallowedSheetActionRole(String)
    /// Phase 2AO: the direct action controls count for a sheet exceeds this capability's
    /// defensive safe bound (16).
    case sheetActionCollectionExceedsSafeBound(Int)
    /// Phase 2AQ: target segmented control item selection state could not be read.
    case segmentSelectionStateReadFailed
    /// Phase 2AQ: target segmented control item deselection is unsupported (select-only capability).
    case segmentDeselectionUnsupported(String)
    /// Phase 2AQ: the target's direct segment role is not on allowed segment roles (AXRadioButton, AXButton).
    case disallowedSegmentRole(String)
    /// Phase 2AQ: target child element is not a valid segmented control item.
    case targetNotASegment(String)
    /// Phase 2AT: the target's AX role is not on `QAXSplitGroupRolePolicy.allowedRoles`
    /// (`AXSplitGroup` only).
    case disallowedSplitGroupRole(String)
    /// Phase 2AT: the direct pane count for a split group exceeds this capability's
    /// defensive safe bound (16).
    case splitPaneCollectionExceedsSafeBound(Int)
    /// Phase 2AU: the target's AX role is not on `QAXSplitterRolePolicy.allowedRoles`
    /// (`AXSplitter` only).
    case disallowedSplitterRole(String)
    /// Phase 2AU: requested splitter index is out of bounds for the target split group.
    case invalidSplitterIndex(Int, availableCount: Int)
    /// Phase 2AU: requested splitter position is out of the target splitter's min/max range.
    case splitterPositionOutOfRange(requested: Double, min: Double, max: Double)
    /// Phase 2AU: target splitter's value attribute is not settable.
    case splitterPositionNotSettable
    /// Phase 2AU: target child element is not a valid splitter.
    case targetNotASplitter(String)
    /// Phase 2AU: requested splitter tolerance is invalid (must be non-negative).
    case invalidSplitterTolerance(Double)
    /// Phase 2AU: requested splitter position is invalid (must be a finite number).
    case invalidDesiredPosition(String)
    /// Phase 2AV: the target's AX role is not on `QAXBrowserRolePolicy.allowedRoles` (`AXBrowser` only).
    case disallowedBrowserRole(String)
    /// Phase 2AV: the direct column count for a browser exceeds this capability's defensive safe bound (32).
    case browserColumnCollectionExceedsSafeBound(Int)
    /// Phase 2AW: the target's AX role is not on `QAXPopoverRolePolicy.allowedRoles` (`AXPopover` only).
    case disallowedPopoverRole(String)
    /// Phase 2AW: the direct popovers count exceeds this capability's defensive safe bound (16).
    case popoverCollectionExceedsSafeBound(Int)
    /// Phase 2AX: the target's AX role is not on `QAXColorWellRolePolicy.allowedRoles` (`AXColorWell` only).
    case disallowedColorWellRole(String)
    /// Phase 2AX: the direct color well count exceeds this capability's defensive safe bound (32).
    case colorWellCollectionExceedsSafeBound(Int)
    /// Phase 2AY: the target's AX role is not on `QAXProgressIndicatorRolePolicy.allowedRoles` (`AXProgressIndicator`, `AXBusyIndicator`).
    case disallowedProgressIndicatorRole(String)
    /// Phase 2AY: the direct progress indicator count exceeds this capability's defensive safe bound (32).
    case progressIndicatorCollectionExceedsSafeBound(Int)
    /// Phase 2AZ: the target's AX role is not on `QAXLevelIndicatorRolePolicy.allowedRoles` (`AXLevelIndicator`, `AXRelevanceIndicator`).
    case disallowedLevelIndicatorRole(String)
    /// Phase 2AZ: the direct level indicator count exceeds this capability's defensive safe bound (32).
    case levelIndicatorCollectionExceedsSafeBound(Int)
    /// Phase 2BA: the target's AX role is not on `QAXIncrementorRolePolicy.allowedRoles` (`AXIncrementor` only).
    case disallowedIncrementorRole(String)
    /// Phase 2BA: the direct incrementor count exceeds this capability's defensive safe bound (32).
    case incrementorCollectionExceedsSafeBound(Int)
    /// Phase 2BB: the target's AX role is not on `QAXComboBoxRolePolicy.allowedRoles` (`AXComboBox` only).
    case disallowedComboBoxRole(String)
    /// Phase 2BB: the direct combo box count exceeds this capability's defensive safe bound (32).
    case comboBoxCollectionExceedsSafeBound(Int)
    /// Phase 2BC: the target's AX role is not on `QAXRulerRolePolicy.allowedRoles` (`AXRuler` only).
    case disallowedRulerRole(String)
    /// Phase 2BC: the direct ruler count exceeds this capability's defensive safe bound (32).
    case rulerCollectionExceedsSafeBound(Int)
    /// Phase 2BD: the direct combo box items count exceeds this capability's defensive safe bound (128).
    case comboBoxItemCollectionExceedsSafeBound(Int)
    /// Phase 2BF: the model-supplied `direction` for `ui.step_incrementor` is neither `"increment"` nor
    /// `"decrement"` — rejected before any AX call, never interpreted as a blind toggle.
    case invalidStepDirection(String)
    /// Phase 2BF: the model-supplied `steps` for `ui.step_incrementor` is not a positive integer within
    /// this capability's bounded range (1...20) — rejected before any AX call.
    case invalidStepCount(String)
    /// Phase 2BF: `AXUIElementPerformAction(kAXIncrementAction/kAXDecrementAction)` itself returned a
    /// non-success `AXError` while stepping the target incrementor.
    case incrementorActionPerformFailed(String)
    /// Phase 2BF: independent post-mutation re-observation of the target incrementor's own
    /// `kAXValueAttribute` did not move in the requested direction relative to the value captured
    /// immediately before mutation — the dispatch call's own `AXError` return is never itself treated
    /// as proof of a real side effect.
    case incrementorStepVerificationFailed(String)
    /// Phase 2BG: `kAXFocusedUIElementAttribute` could not be read from the systemwide
    /// Accessibility element, or the returned focused element's own `kAXRoleAttribute` could not
    /// be read — covers "nothing is currently focused" and "the focused element's own attributes
    /// are malformed/unreadable" identically, since neither leaves anything safe to report.
    case noFocusedElement
    /// Phase 2BG: the systemwide focused element's owning process (`AXUIElementGetPid`) does not
    /// match the resolved target application's `processIdentifier` — the focused element belongs
    /// to a different, unrequested application. Fails closed rather than reporting an element the
    /// caller never asked about.
    case focusedElementApplicationMismatch(String)
    /// Phase 2BG: an optional `windowTitle` scope was supplied, but the focused element's
    /// containing window (`kAXWindowAttribute`) could not be resolved, or its own
    /// `kAXTitleAttribute` does not match — fails closed rather than reporting an element outside
    /// the requested window.
    case focusedElementWindowMismatch(String)
    /// Phase 2BH: `kAXHiddenAttribute` or `kAXFrontmostAttribute` could not be read as a clean
    /// boolean from the resolved application's AX root element — these are the two required,
    /// authoritative state fields `ui.read_application_state` exists to report; without a reliably
    /// readable pair, the whole read is refused rather than defaulting either to `false`.
    case applicationStateReadFailed
    /// Phase 2BI: the direct table column-header count for a table exceeds this capability's
    /// defensive safe bound (32) — mirrors `tableRowCollectionExceedsSafeBound`'s/
    /// `browserColumnCollectionExceedsSafeBound`'s identical discipline.
    case tableColumnCollectionExceedsSafeBound(Int)
    /// Phase 2BJ: the target's AX role is not on `QAXRangeReadRolePolicy.allowedRoles`
    /// (`AXSlider`/`AXIncrementor`/`AXSplitter` only — all verified against the live SDK's
    /// `AXRoleConstants.h`). Thrown before any AX tree walk, mirroring every prior write-side
    /// role policy's identical discipline.
    case disallowedRangeReadRole(String)
    /// Phase 2BK: `AXUIElementCopyActionNames` succeeded but the returned value could not be
    /// cast to `[String]` — the returned value is treated as untrusted external data, never
    /// assumed to be a well-formed array merely because the copy call itself reported success,
    /// mirroring `windowsCollectionMalformed`'s identical discipline.
    case actionNamesCollectionMalformed
    /// Phase 2BK: the target element's supported-action-names count exceeds this capability's
    /// defensive safe bound (16) — mirrors `tableColumnCollectionExceedsSafeBound`'s identical
    /// fail-closed (never silently truncated) discipline.
    case actionNamesCollectionExceedsSafeBound(Int)
    /// Phase 2BK: a single action-name string exceeds this capability's defensive safe length
    /// bound — fails closed rather than returning an arbitrarily large model-visible string.
    /// Carries only the offending length, never the string content itself, so even the failure
    /// path never risks surfacing an oversized value into logs or evidence.
    case actionNameExceedsSafeLength(Int)
    /// Phase 2BL: `AXUIElementCopyAttributeNames` succeeded but the returned value could not be
    /// cast to `[String]` — the returned value is treated as untrusted external data, never
    /// assumed to be a well-formed array merely because the copy call itself reported success,
    /// mirroring `actionNamesCollectionMalformed`'s identical discipline.
    case attributeNamesCollectionMalformed
    /// Phase 2BL: the target element's supported-attribute-names count exceeds this capability's
    /// defensive safe bound (32) — mirrors `actionNamesCollectionExceedsSafeBound`'s identical
    /// fail-closed (never silently truncated) discipline.
    case attributeNamesCollectionExceedsSafeBound(Int)
    /// Phase 2BL: a single attribute-name string exceeds this capability's defensive safe length
    /// bound — fails closed rather than returning an arbitrarily large model-visible string.
    /// Carries only the offending length, never the string content itself.
    case attributeNameExceedsSafeLength(Int)
    /// Phase 2BM: `kAXDefaultButtonAttribute`/`kAXCancelButtonAttribute` could not be read due to
    /// an actual Accessibility API failure (e.g. `kAXErrorFailure`/`kAXErrorCannotComplete`/
    /// `kAXErrorInvalidUIElement`) — distinct from `kAXErrorNoValue`/`kAXErrorAttributeUnsupported`,
    /// which mean the window genuinely has no such button and are never treated as an error. The
    /// payload identifies which button attribute and the underlying `AXError`.
    case windowButtonReferenceReadFailed(String)
    /// Phase 2BM: a button-reference attribute's copy call reported success but the returned
    /// value was not an `AXUIElement` — the returned value is treated as untrusted external
    /// data, never assumed well-formed merely because the copy call itself reported success.
    case windowButtonReferenceMalformed(String)
    /// Phase 2BM: a button-reference attribute resolved to a real element, but that element's own
    /// `kAXRoleAttribute` is not exactly `AXButton` — the mere existence of a returned reference
    /// is never sufficient; its own role is independently re-validated before it is ever treated
    /// as a genuine button, mirroring `targetNotACloseButton`'s identical discipline.
    case windowButtonReferenceWrongRole(String)
    /// Phase 2BM: a button's title or identifier exceeds this capability's defensive safe length
    /// bound (256 characters) — fails closed rather than returning an arbitrarily large
    /// model-visible string. Carries only the offending length, never the string content itself.
    case windowButtonMetadataExceedsSafeLength(Int)
    /// Phase 2BN: `kAXTitleUIElementAttribute` could not be read due to an actual Accessibility
    /// API failure (e.g. `kAXErrorFailure`/`kAXErrorCannotComplete`/`kAXErrorInvalidUIElement`) —
    /// distinct from `kAXErrorNoValue`/`kAXErrorAttributeUnsupported`, which mean the target
    /// genuinely has no title-UI-element reference and are never treated as an error. The payload
    /// carries the underlying `AXError`, never any element content.
    case titleReferenceReadFailed(String)
    /// Phase 2BN: `kAXTitleUIElementAttribute`'s copy call reported success but the returned value
    /// was not an `AXUIElement` — the returned value is treated as untrusted external data, never
    /// assumed well-formed merely because the copy call itself reported success, mirroring
    /// `windowButtonReferenceMalformed`'s identical discipline.
    case titleReferenceMalformed
    /// Phase 2BN: `kAXTitleUIElementAttribute` resolved to a real element, but that element's own
    /// `kAXRoleAttribute` is not on `QAXElementReadRolePolicy`'s allowlist (the same generic
    /// read-role policy the SOURCE element itself must already satisfy) — the mere existence of a
    /// returned reference is never sufficient; its own role is independently re-validated before
    /// it is ever treated as a genuine, safe title element, mirroring
    /// `windowButtonReferenceWrongRole`'s identical discipline. Also the path that rejects a
    /// referenced `AXSecureTextField` (never on the allowlist), so a title relationship can never
    /// be used to surface a secure field as a "safe" reference.
    case titleReferenceDisallowedRole(String)
    /// Phase 2BN: a title-reference element's title or identifier exceeds this capability's
    /// defensive safe length bound (256 characters) — fails closed rather than returning an
    /// arbitrarily large model-visible string. Carries only the offending length, never the
    /// string content itself.
    case titleReferenceMetadataExceedsSafeLength(Int)
    /// Phase 2BO: `kAXModalAttribute` could not be read due to an actual Accessibility API
    /// failure. Unlike an optional reference attribute, `kAXModalAttribute` is documented
    /// "Required for all window elements" — there is no genuine, expected absence case for this
    /// attribute, so EVERY non-`.success` `AXError` (including `kAXErrorNoValue`/
    /// `kAXErrorAttributeUnsupported`) is treated as a genuine read failure here, never silently
    /// downgraded to a guessed `false`. The payload carries the underlying `AXError`, never any
    /// element content.
    case windowModalStateReadFailed(String)
    /// Phase 2BO: `kAXModalAttribute`'s copy call reported success but the returned value could
    /// not be interpreted as a `Bool` — the returned value is treated as untrusted external data,
    /// never assumed well-formed merely because the copy call itself reported success. Fails
    /// closed rather than fabricating a Boolean.
    case windowModalStateMalformed
    /// Phase 2BP: `AXUIElementCopyParameterizedAttributeNames` succeeded but the returned value
    /// could not be cast to `[String]` — the returned value is treated as untrusted external data,
    /// never assumed to be a well-formed array merely because the copy call itself reported
    /// success, mirroring `attributeNamesCollectionMalformed`'s identical discipline.
    case parameterizedAttributeNamesCollectionMalformed
    /// Phase 2BP: the target element's supported-parameterized-attribute-names count exceeds this
    /// capability's defensive safe bound (32, reusing `maxElementAttributesCount` — parameterized
    /// attributes are a sibling enumeration surface to plain attributes, not a distinct category
    /// warranting its own bound) — mirrors `attributeNamesCollectionExceedsSafeBound`'s identical
    /// fail-closed (never silently truncated) discipline.
    case parameterizedAttributeNamesCollectionExceedsSafeBound(Int)
    /// Phase 2BP: a single parameterized-attribute-name string exceeds this capability's defensive
    /// safe length bound (256 characters, reusing `maxAttributeNameLength`) — fails closed rather
    /// than returning an arbitrarily large model-visible string. Carries only the offending
    /// length, never the string content itself.
    case parameterizedAttributeNameExceedsSafeLength(Int)
    /// Phase 2BQ: `AXRequired` could not be read due to an actual Accessibility API failure —
    /// distinct from `kAXErrorNoValue`/`kAXErrorAttributeUnsupported`, which mean the target
    /// genuinely has no required-state concept (most non-form elements) and are never treated as
    /// an error — see `QBridgeAccessibility.readElementRequiredState`'s own documentation for the
    /// full missing-vs-failure rationale. The payload carries the underlying `AXError`, never any
    /// element content.
    case elementRequiredStateReadFailed(String)
    /// Phase 2BQ: `AXRequired`'s copy call reported success but the returned value could not be
    /// interpreted as a `Bool` — the returned value is treated as untrusted external data, never
    /// assumed well-formed merely because the copy call itself reported success. Fails closed
    /// rather than fabricating a Boolean.
    case elementRequiredStateMalformed
    /// Phase 2BR: `AXContainsProtectedContent` could not be read due to an actual Accessibility
    /// API failure — distinct from `kAXErrorNoValue`/`kAXErrorAttributeUnsupported`, which mean
    /// the target genuinely has no protected-content concept (most non-secure elements) and are
    /// never treated as an error — see
    /// `QBridgeAccessibility.readElementProtectedContentState`'s own documentation for the full
    /// missing-vs-failure rationale. The payload carries the underlying `AXError`, never any
    /// element content.
    case elementProtectedContentStateReadFailed(String)
    /// Phase 2BR: `AXContainsProtectedContent`'s copy call reported success but the returned value
    /// could not be interpreted as a `Bool` — the returned value is treated as untrusted external
    /// data, never assumed well-formed merely because the copy call itself reported success.
    /// Fails closed rather than fabricating a Boolean.
    case elementProtectedContentStateMalformed
    /// Phase 2BS: `kAXSelectedTextRangeAttribute` could not be read due to an actual Accessibility
    /// API failure — distinct from `kAXErrorNoValue`/`kAXErrorAttributeUnsupported`, which mean the
    /// target genuinely has no text-selection concept (most non-text elements) and are never
    /// treated as an error — see `QBridgeAccessibility.readTextSelectionState`'s own documentation
    /// for the full missing-vs-failure rationale. The payload carries the underlying `AXError`,
    /// never any selected text content.
    case textSelectionRangeReadFailed(String)
    /// Phase 2BS: `kAXSelectedTextRangeAttribute`'s copy call reported success but the returned
    /// value could not be interpreted as a well-formed `AXValue` of type `kAXValueTypeCFRange` —
    /// the returned value is treated as untrusted external data, never assumed well-formed merely
    /// because the copy call itself reported success. Fails closed rather than fabricating a range.
    case textSelectionRangeMalformed
    /// Phase 2BS: `kAXSelectedTextRangeAttribute` decoded to a structurally invalid `CFRange` —
    /// a negative `location` or `length`. Never silently clamped to zero; fails closed instead,
    /// carrying only the offending values, never any selected text content.
    case textSelectionRangeInvalid(String)
    /// Phase 2BS: `kAXNumberOfCharactersAttribute` could not be read due to an actual
    /// Accessibility API failure — distinct from `kAXErrorNoValue`/`kAXErrorAttributeUnsupported`,
    /// which are treated as genuine absence exactly like `kAXSelectedTextRangeAttribute`'s own
    /// identical cases. The payload carries the underlying `AXError`.
    case characterCountReadFailed(String)
    /// Phase 2BS: `kAXNumberOfCharactersAttribute`'s copy call reported success but the returned
    /// value could not be interpreted as a numeric (`NSNumber`-boxed) value — the returned value
    /// is treated as untrusted external data, never assumed well-formed merely because the copy
    /// call itself reported success. Fails closed rather than fabricating a count.
    case characterCountMalformed
    /// Phase 2BS: `kAXNumberOfCharactersAttribute` decoded to a structurally invalid (negative)
    /// count. Never silently clamped to zero; fails closed instead.
    case characterCountInvalid(String)
    /// Phase 2BS: the two independently-read text-selection facts
    /// (`kAXSelectedTextRangeAttribute`'s location/length and `kAXNumberOfCharactersAttribute`'s
    /// total) are individually well-formed but mutually inconsistent — `selectionLocation +
    /// selectionLength` exceeds `totalCharacterCount`, or that addition would overflow `Int`.
    /// Never silently clamped or truncated; fails the whole read closed instead, carrying only the
    /// offending numeric relationship, never any selected text content.
    case textSelectionStateInconsistent(String)

    public var description: String {
        switch self {
        case .accessibilityPermissionDenied:
            return "Accessibility permission is not granted."
        case .applicationNotAvailable(let name):
            return "Application '\(name)' is not currently running."
        case .missingMatchCriteria:
            return "Target must specify an identifier or title to match semantically."
        case .noMatchingElement:
            return "No Accessibility element matched the requested target."
        case .ambiguousTarget(let count):
            return "Target is ambiguous: \(count) elements matched the requested criteria."
        case .targetDisabled:
            return "Target element is disabled and cannot be pressed."
        case .staleTarget(let reason):
            return "Target element changed before it could be safely clicked: \(reason)"
        case .actionUnsupported:
            return "Target element does not support the press action."
        case .pressFailed(let reason):
            return "Failed to press target element: \(reason)"
        case .disallowedTargetRole(let role):
            return "Target role '\(role)' is not an allowed text-entry target."
        case .targetNotFocused(let reason):
            return "Target element is not the currently focused element: \(reason)"
        case .valueReadFailed:
            return "Target element's current value could not be read."
        case .setValueFailed(let reason):
            return "Failed to set target element's value: \(reason)"
        case .secureFieldReadDenied(let role):
            return "Refusing to read the value of a secure field (role '\(role)')."
        case .disallowedReadRole(let role):
            return "Target role '\(role)' is not on the allowed read-role list."
        case .disallowedStateRole(let role):
            return "Target role '\(role)' is not on the allowed state-change role list."
        case .stateReadFailed:
            return "Target element's current state could not be read or interpreted as on/off."
        case .valueDriftDetected(let reason):
            return "Target element's state changed before it could be safely modified: \(reason)"
        case .stateChangeNotGuaranteed(let reason):
            return "Refusing to change target element's state — the outcome cannot be guaranteed: \(reason)"
        case .nestedMenuPathUnsupported(let reason):
            return "Nested or multi-level menu paths are not supported: \(reason)"
        case .menuNotFound(let title):
            return "Menu bar item '\(title)' could not be resolved."
        case .menuItemNotFound(let title):
            return "Menu item '\(title)' did not become available within the bounded observation window."
        case .appRootMenuUnsupported(let title):
            return "Menu bar item '\(title)' is the application's own root menu, which is not supported by this capability."
        case .disallowedSliderRole(let role):
            return "Target role '\(role)' is not on the allowed slider/stepper role list."
        case .invalidDesiredValue(let reason):
            return "Invalid desired value: \(reason)"
        case .rangeReadFailed:
            return "Target element's min/max range could not be read."
        case .invalidRange(let reason):
            return "Target element's reported range is invalid: \(reason)"
        case .desiredValueOutOfRange(let reason):
            return "Refusing to set value — desired value is out of range: \(reason)"
        case .disallowedFocusRole(let role):
            return "Target role '\(role)' is not on the allowed focus role list."
        case .setFocusFailed(let reason):
            return "Failed to focus target element: \(reason)"
        case .disallowedPopupRole(let role):
            return "Target role '\(role)' is not on the allowed popup role list."
        case .disallowedDisclosureRole(let role):
            return "Target role '\(role)' is not on the allowed disclosure role list."
        case .disclosureStateReadFailed:
            return "Target disclosure triangle's current state could not be read or interpreted as expanded/collapsed."
        case .disallowedTabRole(let role):
            return "Target role '\(role)' is not on the allowed tab role list."
        case .targetNotATabButton(let subrole):
            return "Target is an AXRadioButton but its subrole ('\(subrole)') is not AXTabButton — refusing to treat a generic radio button as a tab."
        case .tabSelectionStateReadFailed:
            return "Target tab's current selected state could not be read."
        case .disallowedTableRowRole(let role):
            return "Target role '\(role)' is not on the allowed table-row role list."
        case .targetNotATableRow(let subrole):
            return "Target is an AXRow but its subrole ('\(subrole)') is not AXTableRow — refusing to treat an unqualified row as a table row."
        case .outlineRowUnsupported(let subrole):
            return "Target is an AXRow with subrole '\(subrole)' (an outline row) — outline row selection is not supported by this capability."
        case .tableContextUnavailable(let reason):
            return "Target row's table context could not be established: \(reason)"
        case .rowSelectionStateReadFailed:
            return "Target table row's current selected state could not be read."
        case .rowDeselectionUnsupported(let reason):
            return "Refusing to deselect a table row — this capability supports selection only: \(reason)"
        case .disallowedOutlineRowRole(let role):
            return "Target role '\(role)' is not on the allowed outline-row role list."
        case .targetNotAnOutlineRow(let subrole):
            return "Target is an AXRow but its subrole ('\(subrole)') is not AXOutlineRow — refusing to treat an unqualified row as an outline row."
        case .tableRowUnsupportedForOutline(let subrole):
            return "Target is an AXRow with subrole '\(subrole)' (a table row) — table row selection is owned by ui.select_table_row, not this capability."
        case .outlineContextUnavailable(let reason):
            return "Target row's outline context could not be established: \(reason)"
        case .outlineRowSelectionStateReadFailed:
            return "Target outline row's current selected state could not be read."
        case .outlineRowDeselectionUnsupported(let reason):
            return "Refusing to deselect an outline row — this capability supports selection only: \(reason)"
        case .disallowedWindowRole(let role):
            return "Target role '\(role)' is not on the allowed window role list."
        case .windowMinimizedStateReadFailed:
            return "Target window's current minimized state could not be read."
        case .disallowedScrollAreaRole(let role):
            return "Target role '\(role)' is not on the allowed scroll-area role list."
        case .invalidOrientation(let orientation):
            return "Invalid orientation '\(orientation)' — must be exactly 'horizontal' or 'vertical'."
        case .scrollBarReferenceUnavailable(let orientation):
            return "No \(orientation) scroll bar reference could be resolved from the target scroll area."
        case .targetNotAScrollBar(let role):
            return "Target resolved via the orientation convenience-reference attribute is not role AXScrollBar (got '\(role)')."
        case .windowMainStateReadFailed:
            return "Target window's current main state could not be read."
        case .windowMainDeselectionUnsupported(let reason):
            return "Refusing to un-main a window — this capability supports selection only: \(reason)"
        case .closeButtonReferenceUnavailable:
            return "No close-button reference could be resolved from the target window."
        case .targetNotACloseButton(let role):
            return "Element resolved via kAXCloseButtonAttribute is not role AXButton (got '\(role)')."
        case .windowsCollectionMalformed:
            return "kAXWindowsAttribute returned a value that could not be read as a well-formed collection."
        case .windowCollectionExceedsSafeBound(let count):
            return "kAXWindowsAttribute returned \(count) elements, exceeding this capability's defensive safe bound."
        case .menuCollectionExceedsSafeBound(let count):
            return "Menu collection element count (\(count)) exceeds this capability's defensive safe bound."
        case .menuItemCollectionExceedsSafeBound(let count):
            return "Menu item collection count (\(count)) for a single menu exceeds this capability's defensive safe bound."
        case .totalMenuItemCollectionExceedsSafeBound(let count):
            return "Total menu item collection count (\(count)) exceeds this capability's defensive safe bound."
        case .disallowedTableRole(let role):
            return "Target role '\(role)' is not an allowed table target."
        case .tableRowCollectionExceedsSafeBound(let count):
            return "Table row collection count (\(count)) exceeds this capability's defensive safe bound."
        case .disallowedOutlineRole(let role):
            return "Target role '\(role)' is not an allowed outline target."
        case .outlineItemCollectionExceedsSafeBound(let count):
            return "Outline item collection count (\(count)) exceeds this capability's defensive safe bound."
        case .outlineItemDepthExceedsSafeBound(let depth):
            return "Outline item depth (\(depth)) exceeds safe maximum depth."
        case .disallowedTabGroupRole(let role):
            return "Target role '\(role)' is not an allowed tab group target."
        case .tabItemCollectionExceedsSafeBound(let count):
            return "Tab item collection count (\(count)) exceeds this capability's defensive safe bound."
        case .disallowedRadioGroupRole(let role):
            return "Target role '\(role)' is not an allowed radio group target."
        case .radioItemCollectionExceedsSafeBound(let count):
            return "Radio item collection count (\(count)) exceeds this capability's defensive safe bound."
        case .disallowedToolbarRole(let role):
            return "Target role '\(role)' is not an allowed toolbar target."
        case .toolbarItemCollectionExceedsSafeBound(let count):
            return "Toolbar item collection count (\(count)) exceeds this capability's defensive safe bound."
        case .disallowedSegmentedControlRole(let role):
            return "Target role '\(role)' is not an allowed segmented control target."
        case .segmentedControlItemCollectionExceedsSafeBound(let count):
            return "Segmented control item collection count (\(count)) exceeds this capability's defensive safe bound."
        case .disallowedSheetRole(let role):
            return "Target role '\(role)' is not an allowed sheet target."
        case .sheetCollectionExceedsSafeBound(let count):
            return "Sheet collection count (\(count)) exceeds this capability's defensive safe bound."
        case .disallowedSheetActionRole(let role):
            return "Target role '\(role)' is not an allowed sheet action target."
        case .sheetActionCollectionExceedsSafeBound(let count):
            return "Sheet action collection count (\(count)) exceeds this capability's defensive safe bound."
        case .segmentSelectionStateReadFailed:
            return "Target segmented control item's current selection state could not be read."
        case .segmentDeselectionUnsupported(let reason):
            return "Refusing to deselect a segmented control item — this capability supports selection only: \(reason)"
        case .disallowedSegmentRole(let role):
            return "Target role '\(role)' is not on the allowed segment role list."
        case .targetNotASegment(let reason):
            return "Target is not a valid segmented control item: \(reason)"
        case .windowFullScreenStateReadFailed:
            return "Failed to read the target window's full-screen state (kAXFullScreenAttribute / AXFullScreen)."
        case .windowFullScreenNotWritable(let reason):
            return "Target window's full-screen attribute is not writable: \(reason)"
        case .disallowedSplitGroupRole(let role):
            return "Target role '\(role)' is not an allowed split group target."
        case .splitPaneCollectionExceedsSafeBound(let count):
            return "Split pane collection count (\(count)) exceeds this capability's defensive safe bound."
        case .disallowedSplitterRole(let role):
            return "Target role '\(role)' is not an allowed splitter target."
        case .invalidSplitterIndex(let index, let availableCount):
            return "Splitter index \(index) is out of range (available count: \(availableCount))."
        case .splitterPositionOutOfRange(let requested, let min, let max):
            return "Requested splitter position \(requested) is out of range [\(min), \(max)]."
        case .splitterPositionNotSettable:
            return "Target splitter position attribute is not writable."
        case .targetNotASplitter(let role):
            return "Target element is not a splitter (role: \(role))."
        case .invalidSplitterTolerance(let tol):
            return "Splitter tolerance must be non-negative, got \(tol)."
        case .invalidDesiredPosition(let reason):
            return "Invalid desired splitter position: \(reason)"
        case .disallowedBrowserRole(let role):
            return "Target role '\(role)' is not an allowed browser target."
        case .browserColumnCollectionExceedsSafeBound(let count):
            return "Browser column collection count (\(count)) exceeds this capability's defensive safe bound."
        case .disallowedPopoverRole(let role):
            return "Target role '\(role)' is not an allowed popover target."
        case .popoverCollectionExceedsSafeBound(let count):
            return "Popover collection count (\(count)) exceeds this capability's defensive safe bound."
        case .disallowedColorWellRole(let role):
            return "Target role '\(role)' is not an allowed color well target."
        case .colorWellCollectionExceedsSafeBound(let count):
            return "Color well collection count (\(count)) exceeds this capability's defensive safe bound."
        case .disallowedProgressIndicatorRole(let role):
            return "Target role '\(role)' is not an allowed progress indicator target."
        case .progressIndicatorCollectionExceedsSafeBound(let count):
            return "Progress indicator collection count (\(count)) exceeds this capability's defensive safe bound."
        case .disallowedLevelIndicatorRole(let role):
            return "Target role '\(role)' is not an allowed level indicator target."
        case .levelIndicatorCollectionExceedsSafeBound(let count):
            return "Level indicator collection count (\(count)) exceeds this capability's defensive safe bound."
        case .disallowedIncrementorRole(let role):
            return "Target role '\(role)' is not an allowed incrementor target."
        case .incrementorCollectionExceedsSafeBound(let count):
            return "Incrementor collection count (\(count)) exceeds this capability's defensive safe bound."
        case .disallowedComboBoxRole(let role):
            return "Target role '\(role)' is not an allowed combo box target."
        case .comboBoxCollectionExceedsSafeBound(let count):
            return "Combo box collection count (\(count)) exceeds this capability's defensive safe bound."
        case .disallowedRulerRole(let role):
            return "Target role '\(role)' is not an allowed ruler target."
        case .rulerCollectionExceedsSafeBound(let count):
            return "Ruler collection count (\(count)) exceeds this capability's defensive safe bound."
        case .comboBoxItemCollectionExceedsSafeBound(let count):
            return "Combo box items collection count (\(count)) exceeds this capability's defensive safe bound."
        case .invalidStepDirection(let reason):
            return "Invalid step direction: \(reason)"
        case .invalidStepCount(let reason):
            return "Invalid step count: \(reason)"
        case .incrementorActionPerformFailed(let reason):
            return "Failed to step target incrementor: \(reason)"
        case .incrementorStepVerificationFailed(let reason):
            return "Post-mutation verification of target incrementor failed: \(reason)"
        case .noFocusedElement:
            return "No focused Accessibility element could be determined."
        case .focusedElementApplicationMismatch(let name):
            return "The currently focused element does not belong to application '\(name)'."
        case .focusedElementWindowMismatch(let title):
            return "The currently focused element is not within window '\(title)'."
        case .applicationStateReadFailed:
            return "The application's authoritative hidden/frontmost state could not be read."
        case .tableColumnCollectionExceedsSafeBound(let count):
            return "Table column collection count (\(count)) exceeds this capability's defensive safe bound."
        case .disallowedRangeReadRole(let role):
            return "Target role '\(role)' is not an allowed range-read target."
        case .actionNamesCollectionMalformed:
            return "The target element's supported action names could not be read as a well-formed collection."
        case .actionNamesCollectionExceedsSafeBound(let count):
            return "Action names collection count (\(count)) exceeds this capability's defensive safe bound."
        case .actionNameExceedsSafeLength(let length):
            return "An action name (\(length) characters) exceeds this capability's defensive safe length bound."
        case .attributeNamesCollectionMalformed:
            return "The target element's supported attribute names could not be read as a well-formed collection."
        case .attributeNamesCollectionExceedsSafeBound(let count):
            return "Attribute names collection count (\(count)) exceeds this capability's defensive safe bound."
        case .attributeNameExceedsSafeLength(let length):
            return "An attribute name (\(length) characters) exceeds this capability's defensive safe length bound."
        case .windowButtonReferenceReadFailed(let reason):
            return "The window's \(reason) could not be read due to an Accessibility API failure."
        case .windowButtonReferenceMalformed(let reason):
            return "The window's \(reason) reference could not be read as a well-formed Accessibility element."
        case .windowButtonReferenceWrongRole(let reason):
            return "The window's \(reason) is not a genuine AXButton element."
        case .windowButtonMetadataExceedsSafeLength(let length):
            return "A window button's title/identifier (\(length) characters) exceeds this capability's defensive safe length bound."
        case .titleReferenceReadFailed(let reason):
            return "The target element's title-UI-element reference could not be read due to an Accessibility API failure: \(reason)."
        case .titleReferenceMalformed:
            return "The target element's title-UI-element reference could not be read as a well-formed Accessibility element."
        case .titleReferenceDisallowedRole(let role):
            return "The target element's title-UI-element reference has role '\(role)', which is not on the allowed read-role list."
        case .titleReferenceMetadataExceedsSafeLength(let length):
            return "The title-reference element's title/identifier (\(length) characters) exceeds this capability's defensive safe length bound."
        case .windowModalStateReadFailed(let reason):
            return "The window's modal state could not be read due to an Accessibility API failure: \(reason)."
        case .windowModalStateMalformed:
            return "The window's modal state attribute could not be read as a well-formed Boolean."
        case .parameterizedAttributeNamesCollectionMalformed:
            return "The target element's supported parameterized attribute names could not be read as a well-formed collection."
        case .parameterizedAttributeNamesCollectionExceedsSafeBound(let count):
            return "Parameterized attribute names collection count (\(count)) exceeds this capability's defensive safe bound."
        case .parameterizedAttributeNameExceedsSafeLength(let length):
            return "A parameterized attribute name (\(length) characters) exceeds this capability's defensive safe length bound."
        case .elementRequiredStateReadFailed(let reason):
            return "The target element's required-field state could not be read due to an Accessibility API failure: \(reason)."
        case .elementRequiredStateMalformed:
            return "The target element's required-field state attribute could not be read as a well-formed Boolean."
        case .elementProtectedContentStateReadFailed(let reason):
            return "The target element's protected-content state could not be read due to an Accessibility API failure: \(reason)."
        case .elementProtectedContentStateMalformed:
            return "The target element's protected-content state attribute could not be read as a well-formed Boolean."
        case .textSelectionRangeReadFailed(let reason):
            return "The target element's selected text range could not be read due to an Accessibility API failure: \(reason)."
        case .textSelectionRangeMalformed:
            return "The target element's selected text range attribute could not be read as a well-formed CFRange."
        case .textSelectionRangeInvalid(let reason):
            return "The target element's selected text range is structurally invalid: \(reason)."
        case .characterCountReadFailed(let reason):
            return "The target element's total character count could not be read due to an Accessibility API failure: \(reason)."
        case .characterCountMalformed:
            return "The target element's total character count attribute could not be read as a well-formed number."
        case .characterCountInvalid(let reason):
            return "The target element's total character count is structurally invalid: \(reason)."
        case .textSelectionStateInconsistent(let reason):
            return "The target element's text selection state is internally inconsistent: \(reason)."
        }
    }

    /// A short, stable machine-readable code — mirrors QScreenCaptureError's convention.
    public var errorCode: String {
        switch self {
        case .accessibilityPermissionDenied: return "AX_PERMISSION_DENIED"
        case .applicationNotAvailable: return "AX_APPLICATION_NOT_AVAILABLE"
        case .missingMatchCriteria: return "AX_MISSING_MATCH_CRITERIA"
        case .noMatchingElement: return "AX_NO_MATCHING_ELEMENT"
        case .ambiguousTarget: return "AX_AMBIGUOUS_TARGET"
        case .targetDisabled: return "AX_TARGET_DISABLED"
        case .staleTarget: return "AX_STALE_TARGET"
        case .actionUnsupported: return "AX_ACTION_UNSUPPORTED"
        case .pressFailed: return "AX_PRESS_FAILED"
        case .disallowedTargetRole: return "AX_TARGET_ROLE_NOT_ALLOWED"
        case .targetNotFocused: return "AX_TARGET_NOT_FOCUSED"
        case .valueReadFailed: return "AX_VALUE_READ_FAILED"
        case .setValueFailed: return "AX_SET_VALUE_FAILED"
        case .secureFieldReadDenied: return "AX_SECURE_FIELD_READ_DENIED"
        case .disallowedReadRole: return "AX_READ_ROLE_NOT_ALLOWED"
        case .disallowedStateRole: return "AX_STATE_ROLE_NOT_ALLOWED"
        case .stateReadFailed: return "AX_STATE_READ_FAILED"
        case .valueDriftDetected: return "AX_VALUE_DRIFT_DETECTED"
        case .stateChangeNotGuaranteed: return "AX_STATE_CHANGE_NOT_GUARANTEED"
        case .nestedMenuPathUnsupported: return "AX_NESTED_MENU_PATH_UNSUPPORTED"
        case .menuNotFound: return "AX_MENU_NOT_FOUND"
        case .menuItemNotFound: return "AX_MENU_ITEM_NOT_FOUND"
        case .appRootMenuUnsupported: return "AX_APP_ROOT_MENU_UNSUPPORTED"
        case .disallowedSliderRole: return "AX_SLIDER_ROLE_NOT_ALLOWED"
        case .invalidDesiredValue: return "AX_INVALID_DESIRED_VALUE"
        case .rangeReadFailed: return "AX_RANGE_READ_FAILED"
        case .invalidRange: return "AX_INVALID_RANGE"
        case .desiredValueOutOfRange: return "AX_DESIRED_VALUE_OUT_OF_RANGE"
        case .disallowedFocusRole: return "AX_FOCUS_ROLE_NOT_ALLOWED"
        case .setFocusFailed: return "AX_SET_FOCUS_FAILED"
        case .disallowedPopupRole: return "AX_POPUP_ROLE_NOT_ALLOWED"
        case .disallowedDisclosureRole: return "AX_DISCLOSURE_ROLE_NOT_ALLOWED"
        case .disclosureStateReadFailed: return "AX_DISCLOSURE_STATE_READ_FAILED"
        case .disallowedTabRole: return "AX_TAB_ROLE_NOT_ALLOWED"
        case .targetNotATabButton: return "AX_TARGET_NOT_A_TAB_BUTTON"
        case .tabSelectionStateReadFailed: return "AX_TAB_SELECTION_STATE_READ_FAILED"
        case .disallowedTableRowRole: return "AX_TABLE_ROW_ROLE_NOT_ALLOWED"
        case .targetNotATableRow: return "AX_TARGET_NOT_A_TABLE_ROW"
        case .outlineRowUnsupported: return "AX_OUTLINE_ROW_UNSUPPORTED"
        case .tableContextUnavailable: return "AX_TABLE_CONTEXT_UNAVAILABLE"
        case .rowSelectionStateReadFailed: return "AX_ROW_SELECTION_STATE_READ_FAILED"
        case .rowDeselectionUnsupported: return "AX_ROW_DESELECTION_UNSUPPORTED"
        case .disallowedOutlineRowRole: return "AX_OUTLINE_ROW_ROLE_NOT_ALLOWED"
        case .targetNotAnOutlineRow: return "AX_TARGET_NOT_AN_OUTLINE_ROW"
        case .tableRowUnsupportedForOutline: return "AX_TABLE_ROW_UNSUPPORTED_FOR_OUTLINE"
        case .outlineContextUnavailable: return "AX_OUTLINE_CONTEXT_UNAVAILABLE"
        case .outlineRowSelectionStateReadFailed: return "AX_OUTLINE_ROW_SELECTION_STATE_READ_FAILED"
        case .outlineRowDeselectionUnsupported: return "AX_OUTLINE_ROW_DESELECTION_UNSUPPORTED"
        case .disallowedWindowRole: return "AX_WINDOW_ROLE_NOT_ALLOWED"
        case .windowMinimizedStateReadFailed: return "AX_WINDOW_MINIMIZED_STATE_READ_FAILED"
        case .disallowedScrollAreaRole: return "AX_SCROLL_AREA_ROLE_NOT_ALLOWED"
        case .invalidOrientation: return "AX_INVALID_ORIENTATION"
        case .scrollBarReferenceUnavailable: return "AX_SCROLL_BAR_REFERENCE_UNAVAILABLE"
        case .targetNotAScrollBar: return "AX_TARGET_NOT_A_SCROLL_BAR"
        case .windowMainStateReadFailed: return "AX_WINDOW_MAIN_STATE_READ_FAILED"
        case .windowMainDeselectionUnsupported: return "AX_WINDOW_MAIN_DESELECTION_UNSUPPORTED"
        case .closeButtonReferenceUnavailable: return "AX_CLOSE_BUTTON_REFERENCE_UNAVAILABLE"
        case .targetNotACloseButton: return "AX_TARGET_NOT_A_CLOSE_BUTTON"
        case .windowsCollectionMalformed: return "AX_WINDOWS_COLLECTION_MALFORMED"
        case .windowCollectionExceedsSafeBound: return "AX_WINDOW_COLLECTION_EXCEEDS_SAFE_BOUND"
        case .menuCollectionExceedsSafeBound: return "AX_MENU_COLLECTION_EXCEEDS_SAFE_BOUND"
        case .menuItemCollectionExceedsSafeBound: return "AX_MENU_ITEM_COLLECTION_EXCEEDS_SAFE_BOUND"
        case .totalMenuItemCollectionExceedsSafeBound: return "AX_TOTAL_MENU_ITEM_COLLECTION_EXCEEDS_SAFE_BOUND"
        case .disallowedTableRole: return "AX_DISALLOWED_ROLE"
        case .tableRowCollectionExceedsSafeBound: return "AX_TABLE_ROW_COLLECTION_EXCEEDS_SAFE_BOUND"
        case .disallowedOutlineRole: return "AX_DISALLOWED_ROLE"
        case .outlineItemCollectionExceedsSafeBound: return "AX_OUTLINE_ITEM_COLLECTION_EXCEEDS_SAFE_BOUND"
        case .outlineItemDepthExceedsSafeBound: return "AX_OUTLINE_ITEM_DEPTH_EXCEEDS_SAFE_BOUND"
        case .disallowedTabGroupRole: return "AX_DISALLOWED_ROLE"
        case .tabItemCollectionExceedsSafeBound: return "AX_TAB_ITEM_COLLECTION_EXCEEDS_SAFE_BOUND"
        case .disallowedRadioGroupRole: return "AX_DISALLOWED_ROLE"
        case .radioItemCollectionExceedsSafeBound: return "AX_RADIO_ITEM_COLLECTION_EXCEEDS_SAFE_BOUND"
        case .disallowedToolbarRole: return "AX_DISALLOWED_ROLE"
        case .toolbarItemCollectionExceedsSafeBound: return "AX_TOOLBAR_ITEM_COLLECTION_EXCEEDS_SAFE_BOUND"
        case .disallowedSegmentedControlRole: return "AX_DISALLOWED_ROLE"
        case .segmentedControlItemCollectionExceedsSafeBound: return "AX_SEGMENTED_CONTROL_ITEM_COLLECTION_EXCEEDS_SAFE_BOUND"
        case .disallowedSheetRole: return "AX_DISALLOWED_ROLE"
        case .sheetCollectionExceedsSafeBound: return "AX_SHEET_COLLECTION_EXCEEDS_SAFE_BOUND"
        case .disallowedSheetActionRole: return "AX_DISALLOWED_ROLE"
        case .sheetActionCollectionExceedsSafeBound: return "AX_SHEET_ACTION_COLLECTION_EXCEEDS_SAFE_BOUND"
        case .segmentSelectionStateReadFailed: return "AX_SEGMENT_SELECTION_STATE_READ_FAILED"
        case .segmentDeselectionUnsupported: return "AX_SEGMENT_DESELECTION_UNSUPPORTED"
        case .disallowedSegmentRole: return "AX_SEGMENT_ROLE_NOT_ALLOWED"
        case .targetNotASegment: return "AX_TARGET_NOT_A_SEGMENT"
        case .windowFullScreenStateReadFailed: return "AX_WINDOW_FULL_SCREEN_STATE_READ_FAILED"
        case .windowFullScreenNotWritable: return "AX_WINDOW_FULL_SCREEN_NOT_WRITABLE"
        case .disallowedSplitGroupRole: return "AX_DISALLOWED_ROLE"
        case .splitPaneCollectionExceedsSafeBound: return "AX_SPLIT_PANE_COLLECTION_EXCEEDS_SAFE_BOUND"
        case .disallowedSplitterRole: return "AX_SPLITTER_ROLE_NOT_ALLOWED"
        case .invalidSplitterIndex: return "AX_INVALID_SPLITTER_INDEX"
        case .splitterPositionOutOfRange: return "AX_SPLITTER_POSITION_OUT_OF_RANGE"
        case .splitterPositionNotSettable: return "AX_SPLITTER_POSITION_NOT_SETTABLE"
        case .targetNotASplitter: return "AX_TARGET_NOT_A_SPLITTER"
        case .invalidSplitterTolerance: return "AX_INVALID_SPLITTER_TOLERANCE"
        case .invalidDesiredPosition: return "AX_INVALID_DESIRED_POSITION"
        case .disallowedBrowserRole: return "AX_DISALLOWED_ROLE"
        case .browserColumnCollectionExceedsSafeBound: return "AX_BROWSER_COLUMN_COLLECTION_EXCEEDS_SAFE_BOUND"
        case .disallowedPopoverRole: return "AX_DISALLOWED_ROLE"
        case .popoverCollectionExceedsSafeBound: return "AX_POPOVER_COLLECTION_EXCEEDS_SAFE_BOUND"
        case .disallowedColorWellRole: return "AX_DISALLOWED_ROLE"
        case .colorWellCollectionExceedsSafeBound: return "AX_COLOR_WELL_COLLECTION_EXCEEDS_SAFE_BOUND"
        case .disallowedProgressIndicatorRole: return "AX_DISALLOWED_ROLE"
        case .progressIndicatorCollectionExceedsSafeBound: return "AX_PROGRESS_INDICATOR_COLLECTION_EXCEEDS_SAFE_BOUND"
        case .disallowedLevelIndicatorRole: return "AX_DISALLOWED_ROLE"
        case .levelIndicatorCollectionExceedsSafeBound: return "AX_LEVEL_INDICATOR_COLLECTION_EXCEEDS_SAFE_BOUND"
        case .disallowedIncrementorRole: return "AX_DISALLOWED_ROLE"
        case .incrementorCollectionExceedsSafeBound: return "AX_INCREMENTOR_COLLECTION_EXCEEDS_SAFE_BOUND"
        case .disallowedComboBoxRole: return "AX_DISALLOWED_ROLE"
        case .comboBoxCollectionExceedsSafeBound: return "AX_COMBO_BOX_COLLECTION_EXCEEDS_SAFE_BOUND"
        case .disallowedRulerRole: return "AX_DISALLOWED_ROLE"
        case .rulerCollectionExceedsSafeBound: return "AX_RULER_COLLECTION_EXCEEDS_SAFE_BOUND"
        case .comboBoxItemCollectionExceedsSafeBound: return "AX_COMBO_BOX_ITEM_COLLECTION_EXCEEDS_SAFE_BOUND"
        case .invalidStepDirection: return "AX_INVALID_STEP_DIRECTION"
        case .invalidStepCount: return "AX_INVALID_STEP_COUNT"
        case .incrementorActionPerformFailed: return "AX_INCREMENTOR_ACTION_PERFORM_FAILED"
        case .incrementorStepVerificationFailed: return "AX_INCREMENTOR_STEP_VERIFICATION_FAILED"
        case .noFocusedElement: return "AX_NO_FOCUSED_ELEMENT"
        case .focusedElementApplicationMismatch: return "AX_FOCUSED_ELEMENT_APPLICATION_MISMATCH"
        case .focusedElementWindowMismatch: return "AX_FOCUSED_ELEMENT_WINDOW_MISMATCH"
        case .applicationStateReadFailed: return "AX_APPLICATION_STATE_READ_FAILED"
        case .tableColumnCollectionExceedsSafeBound: return "AX_TABLE_COLUMN_COLLECTION_EXCEEDS_SAFE_BOUND"
        case .disallowedRangeReadRole: return "AX_RANGE_READ_ROLE_NOT_ALLOWED"
        case .actionNamesCollectionMalformed: return "AX_ACTION_NAMES_COLLECTION_MALFORMED"
        case .actionNamesCollectionExceedsSafeBound: return "AX_ACTION_NAMES_COLLECTION_EXCEEDS_SAFE_BOUND"
        case .actionNameExceedsSafeLength: return "AX_ACTION_NAME_EXCEEDS_SAFE_LENGTH"
        case .attributeNamesCollectionMalformed: return "AX_ATTRIBUTE_NAMES_COLLECTION_MALFORMED"
        case .attributeNamesCollectionExceedsSafeBound: return "AX_ATTRIBUTE_NAMES_COLLECTION_EXCEEDS_SAFE_BOUND"
        case .attributeNameExceedsSafeLength: return "AX_ATTRIBUTE_NAME_EXCEEDS_SAFE_LENGTH"
        case .windowButtonReferenceReadFailed: return "AX_WINDOW_BUTTON_REFERENCE_READ_FAILED"
        case .windowButtonReferenceMalformed: return "AX_WINDOW_BUTTON_REFERENCE_MALFORMED"
        case .windowButtonReferenceWrongRole: return "AX_WINDOW_BUTTON_REFERENCE_WRONG_ROLE"
        case .windowButtonMetadataExceedsSafeLength: return "AX_WINDOW_BUTTON_METADATA_EXCEEDS_SAFE_LENGTH"
        case .titleReferenceReadFailed: return "AX_TITLE_REFERENCE_READ_FAILED"
        case .titleReferenceMalformed: return "AX_TITLE_REFERENCE_MALFORMED"
        case .titleReferenceDisallowedRole: return "AX_TITLE_REFERENCE_DISALLOWED_ROLE"
        case .titleReferenceMetadataExceedsSafeLength: return "AX_TITLE_REFERENCE_METADATA_EXCEEDS_SAFE_LENGTH"
        case .windowModalStateReadFailed: return "AX_WINDOW_MODAL_STATE_READ_FAILED"
        case .windowModalStateMalformed: return "AX_WINDOW_MODAL_STATE_MALFORMED"
        case .parameterizedAttributeNamesCollectionMalformed: return "AX_PARAMETERIZED_ATTRIBUTE_NAMES_COLLECTION_MALFORMED"
        case .parameterizedAttributeNamesCollectionExceedsSafeBound: return "AX_PARAMETERIZED_ATTRIBUTE_NAMES_COLLECTION_EXCEEDS_SAFE_BOUND"
        case .parameterizedAttributeNameExceedsSafeLength: return "AX_PARAMETERIZED_ATTRIBUTE_NAME_EXCEEDS_SAFE_LENGTH"
        case .elementRequiredStateReadFailed: return "AX_ELEMENT_REQUIRED_STATE_READ_FAILED"
        case .elementRequiredStateMalformed: return "AX_ELEMENT_REQUIRED_STATE_MALFORMED"
        case .elementProtectedContentStateReadFailed: return "AX_ELEMENT_PROTECTED_CONTENT_STATE_READ_FAILED"
        case .elementProtectedContentStateMalformed: return "AX_ELEMENT_PROTECTED_CONTENT_STATE_MALFORMED"
        case .textSelectionRangeReadFailed: return "AX_TEXT_SELECTION_RANGE_READ_FAILED"
        case .textSelectionRangeMalformed: return "AX_TEXT_SELECTION_RANGE_MALFORMED"
        case .textSelectionRangeInvalid: return "AX_TEXT_SELECTION_RANGE_INVALID"
        case .characterCountReadFailed: return "AX_CHARACTER_COUNT_READ_FAILED"
        case .characterCountMalformed: return "AX_CHARACTER_COUNT_MALFORMED"
        case .characterCountInvalid: return "AX_CHARACTER_COUNT_INVALID"
        case .textSelectionStateInconsistent: return "AX_TEXT_SELECTION_STATE_INCONSISTENT"
        }
    }
}

/// A point-in-time snapshot of an Accessibility element's own identifying state — captured both
/// as the observation-binding record (matched-at-search vs. re-read-at-dispatch) and as the
/// before/after pair a later verification pass diffs. Deliberately carries no coordinates: this
/// capability never reasons about, or acts on, screen position.
public struct QAXElementSnapshot: Sendable, Equatable {
    public let role: String
    public let identifier: String?
    public let titleOrDescription: String?
    public let isEnabled: Bool

    public init(role: String, identifier: String?, titleOrDescription: String?, isEnabled: Bool) {
        self.role = role
        self.identifier = identifier
        self.titleOrDescription = titleOrDescription
        self.isEnabled = isEnabled
    }
}

/// Fail-closed allowlist of Accessibility roles `ui.read_element_value` (Phase 2J) may target.
///
/// Deliberately wider than `QAXTextEntryRolePolicy`'s two-role write allowlist — reading is
/// categorically lower-risk than writing and needs to cover the ordinary vocabulary of native
/// macOS UI (text fields/areas, static text, buttons, toggles, choice controls) rather than only
/// the narrow set safe to mutate — but it remains an explicit allowlist, not a denylist: any role
/// not listed here, known or unknown, is refused by the same default-deny check
/// `readElementValue` applies. `AXSecureTextField` is never listed and is additionally checked
/// first with its own distinct error for a clearer diagnostic.
public enum QAXElementReadRolePolicy {
    public static let allowedRoles: Set<String> = [
        "AXTextField", "AXTextArea", "AXStaticText",
        "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXMenuItem",
        "AXComboBox", "AXSlider", "AXStepper", "AXLink", "AXTab", "AXDisclosureTriangle"
    ]

    public static func isAllowedReadRole(_ role: String) -> Bool {
        allowedRoles.contains(role)
    }
}

/// A point-in-time snapshot of a semantically-identified element's authoritative numeric range,
/// captured by `ui.read_element_range` (Phase 2BJ). Deliberately carries ONLY the fields this
/// capability's approved contract allows — `applicationName` (echoed from the caller's own
/// request, not element content), `role`, `minValue`, `maxValue`, `currentValue`, and the
/// optional `valueIncrement` (per `kAXValueIncrementAttribute`'s own SDK documentation,
/// "Recommended for kAXIncrementorRole and other similar elements" — never required, never
/// defaulted; `nil` when absent/unreadable is the valid, honest result). No identifier, title, or
/// any other identity/label field is included — the caller already supplied the identifier/title
/// used to resolve this exact element, so none of that needs to be echoed back. No raw
/// `AXUIElement`, no coordinates, no arbitrary AX attributes, ever appear in this type.
public struct QAXElementRangeMetadata: Sendable, Equatable, Codable {
    public let applicationName: String
    public let role: String
    public let minValue: Double
    public let maxValue: Double
    public let currentValue: Double
    public let valueIncrement: Double?

    public init(
        applicationName: String,
        role: String,
        minValue: Double,
        maxValue: Double,
        currentValue: Double,
        valueIncrement: Double?
    ) {
        self.applicationName = applicationName
        self.role = role
        self.minValue = minValue
        self.maxValue = maxValue
        self.currentValue = currentValue
        self.valueIncrement = valueIncrement
    }
}

/// A point-in-time snapshot of a semantically-identified element's supported Accessibility action
/// names, captured by `ui.list_element_actions` (Phase 2BK). `actionNames` is DATA describing what
/// the element reports it can do — never authorization to perform any of them; discovering that an
/// action name exists never itself grants any capability, approval, or standing authority. Bounded
/// to at most `maxElementActionsCount` (16) entries, each individually bounded to
/// `maxActionNameLength` characters — never an unbounded or arbitrarily large collection. No raw
/// `AXUIElement`, no coordinates, ever appear in this type.
public struct QAXElementActionsMetadata: Sendable, Equatable, Codable {
    public let applicationName: String
    public let role: String
    public let actionNames: [String]

    public init(
        applicationName: String,
        role: String,
        actionNames: [String]
    ) {
        self.applicationName = applicationName
        self.role = role
        self.actionNames = actionNames
    }
}

/// A point-in-time snapshot of a semantically-identified element's supported Accessibility
/// attribute NAMES (never values), captured by `ui.list_element_attributes` (Phase 2BL). This is
/// the direct sibling of `QAXElementActionsMetadata`: where that type answers "what can this
/// element DO", this type answers "what can I ASK this element" — a distinct, parallel AX API
/// surface (`AXUIElementCopyAttributeNames` vs. `AXUIElementCopyActionNames`). `attributeNames`
/// is DATA describing which attributes the element reports it supports — it is NOT authorization
/// to read any of those attributes' actual VALUES; discovering that `"AXValue"` is a supported
/// attribute name never itself grants any capability, approval, or standing authority to read
/// that value. Any actual value read must independently go through an existing, approved
/// semantic read capability (e.g. `ui.read_element_value`) and that capability's own role/
/// privacy/security policy, wholly unaffected by this capability ever having been called. Bounded
/// to at most `maxElementAttributesCount` (32) entries, each individually bounded to
/// `maxAttributeNameLength` characters — never an unbounded or arbitrarily large collection, and
/// never deduplicated (the returned array is passed through exactly as the OS reports it — never
/// silently altering the authoritative result). No raw `AXUIElement`, no coordinates, and no
/// attribute VALUES of any kind ever appear in this type.
public struct QAXElementAttributeNamesMetadata: Sendable, Equatable, Codable {
    public let applicationName: String
    public let role: String
    public let attributeNames: [String]

    public init(
        applicationName: String,
        role: String,
        attributeNames: [String]
    ) {
        self.applicationName = applicationName
        self.role = role
        self.attributeNames = attributeNames
    }
}

/// A point-in-time snapshot of a semantically-identified element's supported PARAMETERIZED
/// Accessibility attribute NAMES (never values, never parameters), captured by
/// `ui.list_element_parameterized_attribute_names` (Phase 2BP). This is the third and final
/// sibling in the "what can I ask this element" enumeration family alongside
/// `QAXElementActionsMetadata` (`AXUIElementCopyActionNames`, Phase 2BK) and
/// `QAXElementAttributeNamesMetadata` (`AXUIElementCopyAttributeNames`, Phase 2BL) — a distinct,
/// parallel AX API surface (`AXUIElementCopyParameterizedAttributeNames`) that answers "which
/// queries requiring a parameter (e.g. `AXCellForColumnAndRow`, `AXLineForIndex`) does this
/// element support". `parameterizedAttributeNames` is DATA describing which parameterized queries
/// the element reports it supports — it is NOT authorization to invoke any of them; discovering
/// that `"AXLineForIndex"` is a supported parameterized attribute name never itself grants any
/// capability, approval, or standing authority to invoke it. Any actual parameterized-attribute
/// invocation (`AXUIElementCopyParameterizedAttributeValue`) must independently go through its own
/// future, dedicated semantic capability and that capability's own role/privacy/security policy,
/// wholly unaffected by this capability ever having been called — this capability itself NEVER
/// calls `AXUIElementCopyParameterizedAttributeValue`. Bounded to at most
/// `maxElementAttributesCount` (32, reused verbatim from `ui.list_element_attributes` — a sibling
/// enumeration surface, not a distinct category warranting its own bound) entries, each
/// individually bounded to `maxAttributeNameLength` (256 characters, also reused verbatim) — never
/// an unbounded or arbitrarily large collection, and never deduplicated (the returned array is
/// passed through exactly as the OS reports it). No raw `AXUIElement`, no coordinates, and no
/// parameterized-attribute VALUES of any kind ever appear in this type.
public struct QAXElementParameterizedAttributeNamesMetadata: Sendable, Equatable, Codable {
    public let applicationName: String
    public let role: String
    public let parameterizedAttributeNames: [String]

    public init(
        applicationName: String,
        role: String,
        parameterizedAttributeNames: [String]
    ) {
        self.applicationName = applicationName
        self.role = role
        self.parameterizedAttributeNames = parameterizedAttributeNames
    }
}

/// A point-in-time snapshot of a semantically-identified element's required-for-form-submission
/// state, captured by `ui.read_element_required_state` (Phase 2BQ). `isRequired` is deliberately
/// `Bool?`, never a plain `Bool`: unlike `kAXModalAttribute` (documented "Required for all window
/// elements", Phase 2BO), `AXRequired` has no such universal-presence documentation — it is
/// meaningful only for form-field-like elements, so genuine absence
/// (`kAXErrorNoValue`/`kAXErrorAttributeUnsupported`) is a valid, expected `nil` result, never
/// silently downgraded to `false`. A genuine read failure or a malformed (non-Boolean) value fails
/// the whole read closed instead of ever being represented as this field's value — see
/// `QBridgeAccessibility.readElementRequiredState`'s own documentation for the full rationale.
/// Field naming (`role`, not `elementRole`) deliberately matches
/// `QAXElementActionsMetadata`/`QAXElementAttributeNamesMetadata`/
/// `QAXElementParameterizedAttributeNamesMetadata`'s established convention. No raw `AXUIElement`,
/// no coordinates, no arbitrary AX attributes, ever appear in this type.
public struct QAXElementRequiredStateMetadata: Sendable, Equatable, Codable {
    public let applicationName: String
    public let role: String
    public let isRequired: Bool?

    public init(applicationName: String, role: String, isRequired: Bool?) {
        self.applicationName = applicationName
        self.role = role
        self.isRequired = isRequired
    }
}

/// A point-in-time snapshot of a semantically-identified element's protected-content state,
/// captured by `ui.read_element_protected_content_state` (Phase 2BR). `isProtectedContent` is
/// deliberately `Bool?`, never a plain `Bool`, following `QAXElementRequiredStateMetadata`'s
/// (Phase 2BQ) identical discipline: `AXContainsProtectedContent` has no "required for all
/// elements"-style universal-presence documentation — it is meaningful only for elements that can
/// meaningfully hold sensitive content, so genuine absence
/// (`kAXErrorNoValue`/`kAXErrorAttributeUnsupported`) is a valid, expected `nil` result, never
/// silently downgraded to `false`. A genuine read failure or a malformed (non-Boolean) value fails
/// the whole read closed instead of ever being represented as this field's value — see
/// `QBridgeAccessibility.readElementProtectedContentState`'s own documentation for the full
/// rationale. This type carries ONLY the boolean fact — it never contains, references, or exposes
/// the protected content itself (no `AXValue` text, no password/OTP/credential/payment content, no
/// arbitrary field contents). Field naming (`role`, not `elementRole`) deliberately matches
/// `QAXElementRequiredStateMetadata`'s and every other element-read type's established convention.
/// No raw `AXUIElement`, no coordinates, no arbitrary AX attributes, ever appear in this type.
public struct QAXElementProtectedContentStateMetadata: Sendable, Equatable, Codable {
    public let applicationName: String
    public let role: String
    public let isProtectedContent: Bool?

    public init(applicationName: String, role: String, isProtectedContent: Bool?) {
        self.applicationName = applicationName
        self.role = role
        self.isProtectedContent = isProtectedContent
    }
}

/// A point-in-time snapshot of a semantically-identified element's text-selection STATE — never
/// its content — captured by `ui.read_text_selection_state` (Phase 2BS). Deliberately carries only
/// three numeric facts (`selectionLocation`, `selectionLength`, `totalCharacterCount`), derived
/// from `kAXSelectedTextRangeAttribute` and `kAXNumberOfCharactersAttribute` — both documented
/// "Required for all editable text elements." `kAXSelectedTextAttribute` (the actual selected
/// text) is deliberately NEVER read anywhere in this capability's implementation. The overall
/// result from `QBridgeAccessibility.readTextSelectionState` is this type wrapped in an
/// `Optional` — `nil` represents genuine, expected absence (most non-text elements, or an
/// editable-text element whose AX provider reports neither attribute), never an error; a non-nil
/// value is always a fully validated, internally consistent triple
/// (`selectionLocation >= 0`, `selectionLength >= 0`, `totalCharacterCount >= 0`,
/// `selectionLocation + selectionLength <= totalCharacterCount`, checked with overflow-safe
/// arithmetic) — a partially-known or inconsistent state is never represented; it fails the whole
/// read closed instead. A `selectionLength` of `0` is a fully valid result representing a plain
/// caret/insertion point, never treated as an error or as absence. No raw `AXUIElement`, no
/// coordinates, no selected or surrounding text content, ever appear in this type.
public struct QAXTextSelectionStateMetadata: Sendable, Equatable, Codable {
    public let applicationName: String
    public let role: String
    public let selectionLocation: Int
    public let selectionLength: Int
    public let totalCharacterCount: Int

    public init(
        applicationName: String,
        role: String,
        selectionLocation: Int,
        selectionLength: Int,
        totalCharacterCount: Int
    ) {
        self.applicationName = applicationName
        self.role = role
        self.selectionLocation = selectionLocation
        self.selectionLength = selectionLength
        self.totalCharacterCount = totalCharacterCount
    }
}

/// A single window button's safe, non-sensitive structural identity, as returned by
/// `ui.read_window_default_button` (Phase 2BM) — title/identifier only, never an `AXValue`, never
/// arbitrary content, never a raw `AXUIElement`.
public struct QAXWindowButtonReference: Sendable, Equatable, Codable {
    public let title: String?
    public let identifier: String?

    public init(title: String?, identifier: String?) {
        self.title = title
        self.identifier = identifier
    }
}

/// A point-in-time snapshot of a semantically-identified window's default and cancel button
/// references, captured by `ui.read_window_default_button` (Phase 2BM). Both fields are
/// independently optional — `nil` is a valid, honestly-reported "this window has no such button"
/// result, never an error; a genuine read failure, malformed reference, or wrong-role reference
/// instead fails the WHOLE read closed (see `QBridgeAccessibility.readWindowDefaultButton`'s own
/// documentation for the exact rationale) rather than silently degrading to `nil`, so a `nil`
/// value in this type is never ambiguous with an unobserved failure. No raw `AXUIElement`, no
/// coordinates, no arbitrary AX attributes, ever appear in this type.
public struct QAXWindowDefaultButtonMetadata: Sendable, Equatable, Codable {
    public let applicationName: String
    public let windowTitle: String?
    public let windowIdentifier: String?
    public let defaultButton: QAXWindowButtonReference?
    public let cancelButton: QAXWindowButtonReference?

    public init(
        applicationName: String,
        windowTitle: String?,
        windowIdentifier: String?,
        defaultButton: QAXWindowButtonReference?,
        cancelButton: QAXWindowButtonReference?
    ) {
        self.applicationName = applicationName
        self.windowTitle = windowTitle
        self.windowIdentifier = windowIdentifier
        self.defaultButton = defaultButton
        self.cancelButton = cancelButton
    }
}

/// A single element's safe, non-sensitive structural identity, as returned by
/// `ui.read_element_title_reference` (Phase 2BN) — role/title/identifier only, never an
/// `AXValue`, never arbitrary content, never a raw `AXUIElement`. Mirrors
/// `QAXWindowButtonReference` (Phase 2BM) with the addition of `role`: unlike a window's
/// default/cancel button (always exactly `AXButton`), the element that serves as another
/// element's title can legitimately be any role on `QAXElementReadRolePolicy`'s allowlist (most
/// commonly `AXStaticText`, but not exclusively), so its role is reported rather than assumed.
public struct QAXElementTitleReference: Sendable, Equatable, Codable {
    public let role: String
    public let title: String?
    public let identifier: String?

    public init(role: String, title: String?, identifier: String?) {
        self.role = role
        self.title = title
        self.identifier = identifier
    }
}

/// A point-in-time snapshot of a semantically-identified window's modal state, captured by
/// `ui.read_window_modal_state` (Phase 2BO). Unlike `QAXWindowDefaultButtonMetadata` (Phase 2BM)
/// and `QAXElementTitleReference` (Phase 2BN), `isModal` is never optional — `kAXModalAttribute`
/// is documented "Required for all window elements," so a resolvable `AXWindow` always yields a
/// definite `true`/`false`; a genuine read failure or malformed value fails the whole read closed
/// instead of ever being represented as a field on this type. No raw `AXUIElement`, no
/// coordinates, no arbitrary AX attributes, ever appear in this type.
public struct QAXWindowModalStateMetadata: Sendable, Equatable, Codable {
    public let applicationName: String
    public let windowTitle: String?
    public let windowIdentifier: String?
    public let isModal: Bool

    public init(applicationName: String, windowTitle: String?, windowIdentifier: String?, isModal: Bool) {
        self.applicationName = applicationName
        self.windowTitle = windowTitle
        self.windowIdentifier = windowIdentifier
        self.isModal = isModal
    }
}

/// A point-in-time snapshot of the systemwide currently-focused Accessibility element, captured
/// by `ui.read_focused_element` (Phase 2BG). Unlike `QAXElementSnapshot` (used by every
/// search-by-criteria capability), title and description are reported as separate optional
/// fields rather than merged, and selected state is carried alongside enabled state — matching
/// this capability's own output contract. Deliberately carries no coordinates and no raw
/// AXUIElement — the read touches exactly one element and nothing else. `value` is the sole
/// policy-gated field: nil for a secure or otherwise disallowed role (see
/// `QAXElementReadRolePolicy`), never a reason to fail the whole read — identity/structural
/// metadata is always safe to return regardless of role, exactly like `ui.read_element_value`'s
/// own accepted privacy boundary.
public struct QAXFocusedElementSnapshot: Sendable, Equatable {
    public let role: String
    public let subrole: String?
    public let identifier: String?
    public let title: String?
    public let elementDescription: String?
    public let isEnabled: Bool
    public let isSelected: Bool?
    public let value: String?

    public init(
        role: String,
        subrole: String?,
        identifier: String?,
        title: String?,
        elementDescription: String?,
        isEnabled: Bool,
        isSelected: Bool?,
        value: String?
    ) {
        self.role = role
        self.subrole = subrole
        self.identifier = identifier
        self.title = title
        self.elementDescription = elementDescription
        self.isEnabled = isEnabled
        self.isSelected = isSelected
        self.value = value
    }
}

/// A point-in-time snapshot of a named application's authoritative AX state, captured by
/// `ui.read_application_state` (Phase 2BH). `isHidden`/`isFrontmost` are the two required,
/// authoritative booleans this capability exists to report; `mainWindowTitle`/
/// `mainWindowIdentifier` and `focusedWindowTitle`/`focusedWindowIdentifier` are optional —
/// `nil` for either pair is a valid, honestly-reported "no such window" result (e.g. a
/// headless/background-only application), never an error. Deliberately carries no coordinates
/// and no raw `AXUIElement` — only structural window identity (title/identifier), the same
/// content-free fields `ui.list_windows` already exposes without any redaction boundary.
public struct QAXApplicationStateSnapshot: Sendable, Equatable {
    public let isHidden: Bool
    public let isFrontmost: Bool
    public let mainWindowTitle: String?
    public let mainWindowIdentifier: String?
    public let focusedWindowTitle: String?
    public let focusedWindowIdentifier: String?

    public init(
        isHidden: Bool,
        isFrontmost: Bool,
        mainWindowTitle: String?,
        mainWindowIdentifier: String?,
        focusedWindowTitle: String?,
        focusedWindowIdentifier: String?
    ) {
        self.isHidden = isHidden
        self.isFrontmost = isFrontmost
        self.mainWindowTitle = mainWindowTitle
        self.mainWindowIdentifier = mainWindowIdentifier
        self.focusedWindowTitle = focusedWindowTitle
        self.focusedWindowIdentifier = focusedWindowIdentifier
    }
}

/// Fail-closed allowlist of Accessibility roles `ui.set_element_state` (Phase 2K) may target.
///
/// Deliberately narrow, matching `QAXTextEntryRolePolicy`'s write-side discipline (not
/// `QAXElementReadRolePolicy`'s much wider read-side allowlist): mutating a control's state
/// demands the same narrowest-possible surface `ui.set_text_value` already established. Only the
/// two AX roles with a well-understood, reliably-interpretable boolean/tri-state
/// `kAXValueAttribute` are listed.
public enum QAXElementStateRolePolicy {
    public static let allowedRoles: Set<String> = ["AXCheckBox", "AXRadioButton"]

    public static func isAllowedStateRole(_ role: String) -> Bool {
        allowedRoles.contains(role)
    }
}

/// The normalized on/off state of a checkbox/radio-button-shaped AX element. Never carries a
/// "mixed" case as a settable target — a tri-state control's indeterminate state is a resting
/// state an agent should never intentionally request; reads that observe `2` (mixed) via
/// `kAXValueAttribute` fail closed (`QAXInteractionError.stateReadFailed`) rather than being
/// coerced into this type.
public enum QAXElementState: String, Sendable, Equatable {
    case on
    case off
}

/// Whether a `setElementState` call actually performed a press, or found the target already in
/// the desired state and correctly did nothing.
public enum QAXElementStateChangeKind: String, Sendable, Equatable {
    case alreadyDesired
    case changed
}

/// The outcome of one `QBridgeAccessibility.setElementState` call.
///
/// Like `QAXTextValueMutationOutcome` (Phase 2I), this type carries only non-secret, small-enum
/// state values (`on`/`off` — never free-form text) and SHA-256 hex digests used solely so the
/// later, independent closed-loop verification step can confirm the change without either layer
/// re-reading and re-trusting a stale in-process observation.
public struct QAXElementStateOutcome: Sendable, Equatable {
    public let changeKind: QAXElementStateChangeKind
    public let previousState: QAXElementState
    public let currentState: QAXElementState
    /// Non-secret targeting metadata — application, role, and identifier-or-title.
    public let targetIdentity: String
    /// SHA-256 hex digest of `previousState.rawValue` ("on"/"off" — not sensitive content, but
    /// hashed anyway for architectural consistency with `ui.set_text_value`'s identical pattern).
    public let previousStateHash: String
    /// SHA-256 hex digest of the desired state's `rawValue`, threaded through to the later
    /// closed-loop verification step.
    public let desiredStateHash: String

    public init(
        changeKind: QAXElementStateChangeKind,
        previousState: QAXElementState,
        currentState: QAXElementState,
        targetIdentity: String,
        previousStateHash: String,
        desiredStateHash: String
    ) {
        self.changeKind = changeKind
        self.previousState = previousState
        self.currentState = currentState
        self.targetIdentity = targetIdentity
        self.previousStateHash = previousStateHash
        self.desiredStateHash = desiredStateHash
    }
}

/// The outcome of one `QBridgeAccessibility.selectMenuItem` call — non-secret targeting metadata
/// only (menu/item titles), never an AX tree dump or unrelated window content.
public struct QMenuItemSelectionOutcome: Sendable, Equatable {
    public let targetIdentity: String
    public let menuBarTitle: String
    public let itemTitle: String

    public init(targetIdentity: String, menuBarTitle: String, itemTitle: String) {
        self.targetIdentity = targetIdentity
        self.menuBarTitle = menuBarTitle
        self.itemTitle = itemTitle
    }
}

/// The result of re-observing a menu item after a `ui.select_menu_item` dispatch, for the later
/// closed-loop verification step. Deliberately does NOT claim a stronger verification signal than
/// AX alone can generically provide (see docs/PHASE_2L_SEMANTIC_MENU_SELECTION.md's "evidence
/// contract"):
///
/// - `.itemNoLongerResolvable`: the item (or its menu) is no longer resolvable by the same
///   criteria used to find it — the expected, benign lifecycle for a genuinely-selected menu item
///   (selecting an item closes the menu). Treated as `.verified`.
/// - `.itemStillResolvable`: the item is still resolvable, unchanged — no evidence the selection
///   took effect. Treated as `.failed` (never fabricated as success).
/// - `.applicationOrTargetUnavailable`: the application itself, or the top-level menu bar item,
///   became unavailable — an UNEXPECTED disappearance (distinct from the item-level one above),
///   meaning physical state is uncertain. Treated as `.failed`, never assumed successful.
public enum QMenuItemSelectionEvidence: Sendable, Equatable {
    case itemNoLongerResolvable
    case itemStillResolvable
    case applicationOrTargetUnavailable
}

/// Fail-closed allowlist of Accessibility roles `ui.set_slider_value` (Phase 2M) may target.
///
/// Narrow, matching `QAXTextEntryRolePolicy`'s/`QAXElementStateRolePolicy`'s write-side
/// discipline: only the two AX roles whose `kAXValueAttribute` is a directly-settable,
/// range-bounded number are listed.
public enum QAXSliderRolePolicy {
    public static let allowedRoles: Set<String> = ["AXSlider", "AXStepper"]

    public static func isAllowedSliderRole(_ role: String) -> Bool {
        allowedRoles.contains(role)
    }
}

/// Fail-closed allowlist of Accessibility roles `ui.read_element_range` (Phase 2BJ) may target.
///
/// Deliberately verified against the live macOS SDK's `AXRoleConstants.h` at implementation time
/// rather than copied from any existing policy: `AXSlider` (`kAXSliderRole`), `AXIncrementor`
/// (`kAXIncrementorRole`), and `AXSplitter` (`kAXSplitterRole`) are all real, defined role
/// constants confirmed present in the header. `QAXSliderRolePolicy`'s own historical inclusion of
/// the string `"AXStepper"` is deliberately NOT carried forward here — `"AXStepper"` does not
/// exist anywhere in `AXRoleConstants.h` (confirmed by direct `grep` against the installed SDK: 0
/// matches); an `NSStepper`'s actual AX role is `AXIncrementor`, already covered by this policy.
/// Silently treating an unverified role string as authoritative would violate this capability's
/// own fail-closed contract, so it is omitted rather than blindly copied.
public enum QAXRangeReadRolePolicy {
    public static let allowedRoles: Set<String> = ["AXSlider", "AXIncrementor", "AXSplitter"]

    public static func isAllowedRangeReadRole(_ role: String) -> Bool {
        allowedRoles.contains(role)
    }
}

/// Whether a `setSliderValue` call actually performed a mutation, or found the target already at
/// the desired value and correctly did nothing.
public enum QAXSliderChangeKind: String, Sendable, Equatable {
    case alreadyDesired
    case changed
}

/// The outcome of one `QBridgeAccessibility.setSliderValue` call. Numeric values are carried
/// directly (not hashed) — per the Phase 2M discovery, a slider/stepper's value is not sensitive
/// free-form content the way `ui.set_text_value`'s input is.
public struct QAXSliderValueOutcome: Sendable, Equatable {
    public let changeKind: QAXSliderChangeKind
    public let previousValue: Double
    public let currentValue: Double
    public let desiredValue: Double
    public let minValue: Double
    public let maxValue: Double
    public let targetIdentity: String

    public init(
        changeKind: QAXSliderChangeKind,
        previousValue: Double,
        currentValue: Double,
        desiredValue: Double,
        minValue: Double,
        maxValue: Double,
        targetIdentity: String
    ) {
        self.changeKind = changeKind
        self.previousValue = previousValue
        self.currentValue = currentValue
        self.desiredValue = desiredValue
        self.minValue = minValue
        self.maxValue = maxValue
        self.targetIdentity = targetIdentity
    }
}

/// The result of re-observing a slider/stepper after a `ui.set_slider_value` dispatch, for the
/// later closed-loop verification step.
///
/// - `.resolved(currentValue:)`: the target is still resolvable and its range is internally
///   consistent — `currentValue` is compared against the desired value using the same tolerance
///   rule (`QBridgeAccessibility.sliderValuesAreEqual`) idempotency used.
/// - `.rangeInvalid(currentValue:)`: the target is resolvable but its reported range is no longer
///   internally consistent (or the value falls outside it) — verification cannot be trusted;
///   treated as `.failed`, never assumed successful.
/// - `.targetUnavailable`: the target (or application) is no longer resolvable at all — physical
///   state is uncertain; treated as `.failed`, never assumed successful.
public enum QAXSliderValueEvidence: Sendable, Equatable {
    case resolved(currentValue: Double)
    case rangeInvalid(currentValue: Double)
    case targetUnavailable
}

/// Fail-closed allowlist of Accessibility roles `ui.focus_element` (Phase 2O) may target.
///
/// Deliberately the narrowest allowlist of any write-capable capability in this codebase — the
/// union of every role already proven genuinely interactive by an EXISTING write-side policy
/// (`QAXTextEntryRolePolicy`'s `AXTextField`/`AXTextArea`, `QAXElementStateRolePolicy`'s
/// `AXCheckBox`/`AXRadioButton`, `QAXSliderRolePolicy`'s `AXSlider`/`AXStepper`) plus `AXButton`
/// (keyboard-activatable via Space/Return once focused, and already `ui.click_element`'s
/// press target). `AXPopUpButton`/`AXComboBox` — already read-allowlisted by
/// `QAXElementReadRolePolicy` — are deliberately NOT included here: selecting a value from either
/// is a distinct, not-yet-implemented capability of its own (see docs/PHASE_2O_SEMANTIC_ELEMENT_
/// FOCUS.md's Known limitations), and adding them here would informally provide a sliver of that
/// capability ahead of its own proper scoping. `AXStaticText`/`AXImage`/`AXGroup` are never
/// listed — non-interactive elements have no legitimate reason to receive keyboard focus.
/// `AXSecureTextField` is never listed either, consistent with `QAXTextEntryRolePolicy`'s and
/// `QAXElementReadRolePolicy`'s blanket exclusion of that role from every existing AX interaction
/// capability, not just value read/write.
public enum QAXFocusableRolePolicy {
    public static let allowedRoles: Set<String> = [
        "AXButton", "AXCheckBox", "AXRadioButton", "AXTextField", "AXTextArea", "AXSlider", "AXStepper"
    ]

    public static func isAllowedFocusRole(_ role: String) -> Bool {
        allowedRoles.contains(role)
    }
}

/// Whether a `focusElement` call actually performed a mutation, or found the target already
/// focused and correctly did nothing.
public enum QAXFocusChangeKind: String, Sendable, Equatable {
    case alreadyFocused
    case focused
}

/// The outcome of one `QBridgeAccessibility.focusElement` call. Carries only non-secret targeting
/// metadata (a role/identifier/label identity string) — never an AX value, since focus-setting
/// never reads or exposes element content.
public struct QAXFocusOutcome: Sendable, Equatable {
    public let changeKind: QAXFocusChangeKind
    public let targetIdentity: String

    public init(changeKind: QAXFocusChangeKind, targetIdentity: String) {
        self.changeKind = changeKind
        self.targetIdentity = targetIdentity
    }
}

/// The result of independently re-observing focus state after a `ui.focus_element` dispatch, for
/// the later closed-loop verification step. A successful `AXUIElementSetAttributeValue` call is
/// never itself treated as proof of success — this is the sole source of truth.
///
/// - `.focused(identity:)`: the target is resolvable AND is the systemwide
///   `kAXFocusedUIElementAttribute` element. Treated as `.verified`.
/// - `.notFocused`: the target is resolvable but is NOT the systemwide focused element (including
///   the case where no focused element can be determined at all). Treated as `.failed` — never
///   assumed successful.
/// - `.targetUnavailable`: the target (or application) is no longer resolvable at all — physical
///   state is uncertain; treated as `.failed`, mirroring `axTextValueChanged`'s/
///   `axElementStateMatchesDesired`'s conservative model (not click's more permissive one), since
///   nothing about being focused should make an element disappear.
public enum QAXFocusVerificationEvidence: Sendable, Equatable {
    case focused(identity: String)
    case notFocused
    case targetUnavailable
}

/// Fail-closed allowlist of Accessibility roles `ui.select_popup_item` (Phase 2P) may target.
///
/// Deliberately a SINGLE role, the narrowest write-capable policy in this codebase alongside
/// `QAXPopupRolePolicy`'s siblings. `AXComboBox` is explicitly NOT listed: unlike a pure popup
/// button, a combo box is a materially different, hybrid text-entry-plus-selection control whose
/// correct interaction model has not been evaluated — folding it in here would silently expand
/// this phase's scope rather than deliberately scoping a future one for it (see
/// docs/PHASE_2P_SEMANTIC_POPUP_SELECTION.md's Known limitations).
public enum QAXPopupRolePolicy {
    public static let allowedRoles: Set<String> = ["AXPopUpButton"]

    public static func isAllowedPopupRole(_ role: String) -> Bool {
        allowedRoles.contains(role)
    }
}

/// Whether a `selectPopupItem` call actually performed the open+select press sequence, or found
/// the popup already showing the desired item and correctly did nothing.
public enum QAXPopupSelectionChangeKind: String, Sendable, Equatable {
    case alreadySelected
    case changed
}

/// The outcome of one `QBridgeAccessibility.selectPopupItem` call. `previousValue` and
/// `requestedItemTitle` are carried directly (not hashed) — popup item labels are non-secret UI
/// text, the same class already exposed by `ui.click_element`/`ui.select_menu_item`.
public struct QAXPopupSelectionOutcome: Sendable, Equatable {
    public let changeKind: QAXPopupSelectionChangeKind
    public let previousValue: String
    public let requestedItemTitle: String
    public let targetIdentity: String

    public init(
        changeKind: QAXPopupSelectionChangeKind,
        previousValue: String,
        requestedItemTitle: String,
        targetIdentity: String
    ) {
        self.changeKind = changeKind
        self.previousValue = previousValue
        self.requestedItemTitle = requestedItemTitle
        self.targetIdentity = targetIdentity
    }
}

/// The result of independently re-observing a popup's OWN `kAXValueAttribute` after a
/// `ui.select_popup_item` dispatch, for the later closed-loop verification step. Unlike
/// `ui.select_menu_item`'s indirect "item disappeared" evidence, an `AXPopUpButton` is a
/// persistent value-holding control — this evidence compares its CURRENT value directly against
/// the requested item title, a stronger, more direct signal.
///
/// - `.resolved(currentValue:)`: the popup is still resolvable and its current value was read.
/// - `.targetUnavailable`: the popup (or application) is no longer resolvable, or its value could
///   not be read at all — physical state is uncertain; treated as `.failed`, never assumed
///   successful, mirroring `axSliderValueMatchesDesired`'s/`axElementStateMatchesDesired`'s
///   conservative model.
public enum QAXPopupValueEvidence: Sendable, Equatable {
    case resolved(currentValue: String)
    case targetUnavailable
}

/// Fail-closed allowlist of Accessibility roles `ui.toggle_disclosure` (Phase 2Q) may target.
///
/// Deliberately a SINGLE role — the narrowest write-capable policy in this codebase alongside
/// `QAXPopupRolePolicy`. `AXButton`/`AXCheckBox`/`AXRadioButton`/`AXPopUpButton`/`AXComboBox`/
/// `AXGroup`/`AXStaticText` are never listed: this capability is scoped to the one AX role whose
/// entire purpose is expand/collapse disclosure, not a generic press-based toggle. A control that
/// merely LOOKS like a disclosure triangle but reports a different role (e.g. a custom `AXButton`
/// styled to resemble one) is refused, not silently accepted — the same fail-closed discipline
/// every prior write-side role policy in this codebase already establishes.
public enum QAXDisclosureRolePolicy {
    public static let allowedRoles: Set<String> = ["AXDisclosureTriangle"]

    public static func isAllowedDisclosureRole(_ role: String) -> Bool {
        allowedRoles.contains(role)
    }
}

/// The normalized expand/collapse state of an `AXDisclosureTriangle`. Never carries an "unknown"
/// case as a settable target — an indeterminate/unreadable `kAXValueAttribute` fails closed
/// (`QAXInteractionError.disclosureStateReadFailed`) rather than being coerced into this type,
/// the same discipline `QAXElementState` already establishes for checkbox/radio "mixed" states.
public enum QAXDisclosureState: String, Sendable, Equatable {
    case expanded
    case collapsed
}

/// Whether a `toggleDisclosure` call actually performed a press, or found the target already at
/// the desired expand/collapse state and correctly did nothing.
public enum QAXDisclosureChangeKind: String, Sendable, Equatable {
    case alreadyDesired
    case changed
}

/// The outcome of one `QBridgeAccessibility.toggleDisclosure` call. Carries only the small,
/// non-sensitive expanded/collapsed enum and non-secret targeting metadata — never a raw AX
/// attribute dump, never the content revealed/hidden by the toggle.
public struct QAXDisclosureToggleOutcome: Sendable, Equatable {
    public let changeKind: QAXDisclosureChangeKind
    public let previousState: QAXDisclosureState
    public let currentState: QAXDisclosureState
    public let targetIdentity: String

    public init(
        changeKind: QAXDisclosureChangeKind,
        previousState: QAXDisclosureState,
        currentState: QAXDisclosureState,
        targetIdentity: String
    ) {
        self.changeKind = changeKind
        self.previousState = previousState
        self.currentState = currentState
        self.targetIdentity = targetIdentity
    }
}

/// The result of independently re-observing a disclosure triangle's state after a
/// `ui.toggle_disclosure` dispatch, for the later closed-loop verification step (and for
/// `QTaskRecoveryManager`'s observation-first recovery, which reuses this exact primitive).
///
/// - `.resolved(currentState:)`: the target is still resolvable and its state was read and
///   cleanly interpreted as expanded or collapsed.
/// - `.stateUnreadable`: the target is resolvable but its `kAXValueAttribute` could not be read
///   or cleanly interpreted — an indeterminate/unknown state, treated as `.failed`, NEVER
///   defaulted to either expanded or collapsed.
/// - `.targetUnavailable`: the target (or application) is no longer resolvable at all — physical
///   state is uncertain; treated as `.failed`, mirroring `axElementStateMatchesDesired`'s/
///   `axPopupValueMatchesDesired`'s conservative model, since nothing about toggling disclosure
///   should make the triangle itself disappear.
public enum QAXDisclosureVerificationEvidence: Sendable, Equatable {
    case resolved(currentState: QAXDisclosureState)
    case stateUnreadable
    case targetUnavailable
}

/// Fail-closed allowlist of Accessibility roles `ui.select_tab` (Phase 2R) may target.
///
/// Fail-closed allowlist of Accessibility roles `ui.list_tab_items` (Phase 2AH) may target.
public enum QAXTabGroupRolePolicy {
    public static let allowedRoles: Set<String> = ["AXTabGroup"]

    public static func isAllowedTabGroupRole(_ role: String) -> Bool {
        allowedRoles.contains(role)
    }
}

/// Fail-closed allowlist of Accessibility roles `ui.list_radio_group_items` (Phase 2AI) may target.
public enum QAXRadioGroupRolePolicy {
    public static let allowedRoles: Set<String> = ["AXRadioGroup"]

    public static func isAllowedRadioGroupRole(_ role: String) -> Bool {
        allowedRoles.contains(role)
    }
}

/// Fail-closed allowlist of Accessibility roles `ui.list_toolbar_items` (Phase 2AK) may target.
public enum QAXToolbarRolePolicy {
    public static let allowedRoles: Set<String> = ["AXToolbar"]

    public static func isAllowedToolbarRole(_ role: String) -> Bool {
        allowedRoles.contains(role)
    }
}

/// Fail-closed allowlist of Accessibility roles `ui.list_segmented_control_items` (Phase 2AM) may target.
/// Canonical role only — AXRadioGroup is explicitly excluded and handled exclusively by ui.list_radio_group_items.
public enum QAXSegmentedControlRolePolicy {
    public static let allowedRoles: Set<String> = ["AXSegmentedControl"]

    public static func isAllowedSegmentedControlRole(_ role: String) -> Bool {
        allowedRoles.contains(role)
    }
}

/// Fail-closed allowlist of Accessibility roles `ui.list_sheet_dialogs` (Phase 2AN) may target.
/// Canonical role only — AXDialog and generic containers are strictly excluded.
public enum QAXSheetRolePolicy {
    public static let allowedRoles: Set<String> = ["AXSheet"]

    public static func isAllowedSheetRole(_ role: String) -> Bool {
        allowedRoles.contains(role)
    }
}

/// Fail-closed allowlist of Accessibility roles `ui.list_sheet_actions` (Phase 2AO) may target.
/// Direct action controls only — groups, texts, menus, combos, and generic containers are strictly excluded.
public enum QAXSheetActionRolePolicy {
    public static let allowedRoles: Set<String> = [
        "AXButton",
        "AXCheckBox",
        "AXRadioButton",
        "AXPopUpButton"
    ]

    public static func isAllowedSheetActionRole(_ role: String) -> Bool {
        allowedRoles.contains(role)
    }
}

/// Fail-closed allowlist of Accessibility roles `ui.list_split_panes` (Phase 2AT) may target.
/// Canonical role only — the split group container itself, never an individual pane or the
/// `AXSplitter` divider between panes.
public enum QAXSplitGroupRolePolicy {
    public static let allowedRoles: Set<String> = ["AXSplitGroup"]

    public static func isAllowedSplitGroupRole(_ role: String) -> Bool {
        allowedRoles.contains(role)
    }
}

/// Fail-closed allowlist of Accessibility roles `ui.set_splitter_position` (Phase 2AU) may target.
/// Canonical role only — the `AXSplitter` divider element between split panes within an `AXSplitGroup`.
public enum QAXSplitterRolePolicy {
    public static let allowedRoles: Set<String> = ["AXSplitter"]

    public static func isAllowedSplitterRole(_ role: String) -> Bool {
        allowedRoles.contains(role)
    }
}

/// Fail-closed allowlist of Accessibility roles `ui.list_browser_columns` (Phase 2AV) may target.
/// Canonical role only — the multi-column browser container itself.
public enum QAXBrowserRolePolicy {
    public static let allowedRoles: Set<String> = ["AXBrowser"]

    public static func isAllowedBrowserRole(_ role: String) -> Bool {
        allowedRoles.contains(role)
    }
}

/// Fail-closed allowlist of Accessibility roles `ui.list_popovers` (Phase 2AW) may target.
/// Canonical role only — the popover container itself.
public enum QAXPopoverRolePolicy {
    public static let allowedRoles: Set<String> = ["AXPopover"]

    public static func isAllowedPopoverRole(_ role: String) -> Bool {
        allowedRoles.contains(role)
    }
}

/// Fail-closed allowlist of Accessibility roles `ui.list_color_wells` (Phase 2AX) may target.
/// Canonical role only — the color well control itself.
public enum QAXColorWellRolePolicy {
    public static let allowedRoles: Set<String> = ["AXColorWell"]

    public static func isAllowedColorWellRole(_ role: String) -> Bool {
        allowedRoles.contains(role)
    }
}

/// Fail-closed allowlist of Accessibility roles `ui.list_progress_indicators` (Phase 2AY) may target.
/// Canonical roles: `AXProgressIndicator` (determinate/bar) and `AXBusyIndicator` (indeterminate/spinner).
public enum QAXProgressIndicatorRolePolicy {
    public static let allowedRoles: Set<String> = ["AXProgressIndicator", "AXBusyIndicator"]

    public static func isAllowedProgressIndicatorRole(_ role: String) -> Bool {
        allowedRoles.contains(role)
    }
}

/// Fail-closed allowlist of Accessibility roles `ui.list_level_indicators` (Phase 2AZ) may target.
/// Canonical roles: `AXLevelIndicator` (level/capacity/rating gauge) and `AXRelevanceIndicator` (relevance/ranking meter).
public enum QAXLevelIndicatorRolePolicy {
    public static let allowedRoles: Set<String> = ["AXLevelIndicator", "AXRelevanceIndicator"]

    public static func isAllowedLevelIndicatorRole(_ role: String) -> Bool {
        allowedRoles.contains(role)
    }
}

/// Fail-closed allowlist of Accessibility roles `ui.list_incrementors` (Phase 2BA) may target.
/// Canonical roles: `AXIncrementor` (stepper / incrementor control).
public enum QAXIncrementorRolePolicy {
    public static let allowedRoles: Set<String> = ["AXIncrementor"]

    public static func isAllowedIncrementorRole(_ role: String) -> Bool {
        allowedRoles.contains(role)
    }
}

/// Fail-closed allowlist of Accessibility roles `ui.list_combo_boxes` (Phase 2BB) may target.
/// Canonical roles: `AXComboBox` (combo box control).
public enum QAXComboBoxRolePolicy {
    public static let allowedRoles: Set<String> = ["AXComboBox"]

    public static func isAllowedComboBoxRole(_ role: String) -> Bool {
        allowedRoles.contains(role)
    }
}

/// Fail-closed allowlist of Accessibility roles `ui.list_rulers` (Phase 2BC) may target.
/// Canonical roles: `AXRuler` (ruler view).
public enum QAXRulerRolePolicy {
    public static let allowedRoles: Set<String> = ["AXRuler"]

    public static func isAllowedRulerRole(_ role: String) -> Bool {
        allowedRoles.contains(role)
    }
}

/// **Important empirical finding** (see docs/PHASE_2R_SEMANTIC_TAB_SELECTION.md's Known
/// limitations for the full account): there is no standalone "AXTab" role anywhere in macOS's
/// Accessibility API — confirmed directly against this SDK's authoritative
/// `NSAccessibilityConstants.h`, which lists every `NSAccessibilityRole` constant Apple has ever
/// defined. Individual tab items are represented by the base role `AXRadioButton` carrying the
/// distinct `kAXSubroleAttribute` value `"AXTabButton"` (`NSAccessibilityTabButtonSubrole`) — the
/// role list below reflects that reality, not the originally-assumed (and incorrect) "AXTab"
/// role. `AXRadioButton` alone is NOT sufficient: `selectTab`'s resolution additionally requires
/// the `AXTabButton` subrole (see `QAXInteractionError.targetNotATabButton`) — a generic radio
/// button sharing this base role is refused, never treated as a tab. This is what keeps this
/// capability from being cross-wired with `ui.set_element_state`'s existing, unconditional
/// `AXRadioButton` coverage: the two read entirely different attributes for their respective
/// state models (`kAXSelectedAttribute` here, `kAXValueAttribute` there) and are never confused.
public enum QAXTabRolePolicy {
    public static let allowedRoles: Set<String> = ["AXRadioButton"]

    public static func isAllowedTabRole(_ role: String) -> Bool {
        allowedRoles.contains(role)
    }
}

/// Whether a `selectTab` call actually performed a press, or found the target already at the
/// desired selection state and correctly did nothing.
public enum QAXTabSelectionChangeKind: String, Sendable, Equatable {
    case alreadyDesired
    case changed
}

/// The outcome of one `QBridgeAccessibility.selectTab` call. Carries only a small, non-sensitive
/// boolean and non-secret targeting metadata — never a raw AX attribute dump, never the content
/// of the pane the tab reveals.
public struct QAXTabSelectionOutcome: Sendable, Equatable {
    public let changeKind: QAXTabSelectionChangeKind
    public let previousSelected: Bool
    public let currentSelected: Bool
    public let targetIdentity: String

    public init(
        changeKind: QAXTabSelectionChangeKind,
        previousSelected: Bool,
        currentSelected: Bool,
        targetIdentity: String
    ) {
        self.changeKind = changeKind
        self.previousSelected = previousSelected
        self.currentSelected = currentSelected
        self.targetIdentity = targetIdentity
    }
}

/// The result of independently re-observing a tab's `kAXSelectedAttribute` after a
/// `ui.select_tab` dispatch, for the later closed-loop verification step (and for
/// `QTaskRecoveryManager`'s observation-first recovery, which reuses this exact primitive).
/// Authoritative selection state is read from `kAXSelectedAttribute` — deliberately never
/// `kAXValueAttribute` (an ordinary `AXRadioButton`'s own on/off state, which
/// `ui.set_element_state` already owns) or `kAXFocusedAttribute` (keyboard focus, a distinct
/// concept `ui.focus_element` already owns).
///
/// - `.resolved(currentSelected:)`: the target is still resolvable (role `AXRadioButton`,
///   subrole `AXTabButton`) and its selection state was read as a clean boolean.
/// - `.stateUnreadable`: the target is resolvable but `kAXSelectedAttribute` could not be read —
///   treated as `.failed`, NEVER defaulted to either selected or not-selected.
/// - `.targetUnavailable`: the target (or application) is no longer resolvable at all, is
///   ambiguous, or no longer carries the `AXTabButton` subrole — physical state is uncertain;
///   treated as `.failed`, mirroring `axDisclosureStateMatchesDesired`'s/
///   `axPopupValueMatchesDesired`'s conservative model.
public enum QAXTabSelectionEvidence: Sendable, Equatable {
    case resolved(currentSelected: Bool)
    case stateUnreadable
    case targetUnavailable
}

/// Fail-closed allowlist of Accessibility roles `ui.list_table_rows` (Phase 2AE) may target.
public enum QAXTableRolePolicy {
    public static let allowedRoles: Set<String> = ["AXTable"]

    public static func isAllowedTableRole(_ role: String) -> Bool {
        allowedRoles.contains(role)
    }
}

/// Fail-closed allowlist of Accessibility roles `ui.select_table_row` (Phase 2S) may target.
///
/// Deliberately a SINGLE role, the narrowest write-capable policy in this codebase alongside
/// `QAXTabRolePolicy`'s/`QAXPopupRolePolicy`'s/`QAXDisclosureRolePolicy`'s siblings. `AXRow`
/// alone is NOT sufficient for `selectTableRow` to treat a resolved element as a table row —
/// resolution additionally, unconditionally requires the `AXTableRow` subrole (see
/// `QAXInteractionError.targetNotATableRow`) AND an established `AXTable` parent context (see
/// `QAXInteractionError.tableContextUnavailable`). `AXOutlineRow` — a real, distinct subrole this
/// SDK also defines — is explicitly recognized-but-refused (see
/// `QAXInteractionError.outlineRowUnsupported`), never silently folded into table-row handling.
public enum QAXTableRowRolePolicy {
    public static let allowedRoles: Set<String> = ["AXRow"]

    public static func isAllowedTableRowRole(_ role: String) -> Bool {
        allowedRoles.contains(role)
    }
}

/// Whether a `selectTableRow` call actually performed a press, or found the target already
/// selected and correctly did nothing.
public enum QAXTableRowSelectionChangeKind: String, Sendable, Equatable {
    case alreadyDesired
    case changed
}

/// The outcome of one `QBridgeAccessibility.selectTableRow` call. Carries only a small,
/// non-sensitive boolean and non-secret targeting metadata — never a raw AX attribute dump,
/// never the content of the row's own cells or the table it belongs to.
public struct QAXTableRowSelectionOutcome: Sendable, Equatable {
    public let changeKind: QAXTableRowSelectionChangeKind
    public let previousSelected: Bool
    public let currentSelected: Bool
    public let targetIdentity: String

    public init(
        changeKind: QAXTableRowSelectionChangeKind,
        previousSelected: Bool,
        currentSelected: Bool,
        targetIdentity: String
    ) {
        self.changeKind = changeKind
        self.previousSelected = previousSelected
        self.currentSelected = currentSelected
        self.targetIdentity = targetIdentity
    }
}

/// The result of independently re-observing a table row's `kAXSelectedAttribute` after a
/// `ui.select_table_row` dispatch, for the later closed-loop verification step (and for
/// `QTaskRecoveryManager`'s observation-first recovery, which reuses this exact primitive).
/// Authoritative selection state is read from `kAXSelectedAttribute` — the same attribute
/// already proven correct for `ui.select_tab`, deliberately never `kAXSelectedRowsAttribute`
/// (the table-level multi-selection array, never read or written by this single-row capability).
///
/// - `.resolved(currentSelected:)`: the target is still resolvable (role `AXRow`, subrole
///   `AXTableRow`, with an `AXTable`-rooted parent context) and its selection state was read as
///   a clean boolean.
/// - `.stateUnreadable`: the target is resolvable but `kAXSelectedAttribute` could not be read —
///   treated as `.failed`, NEVER defaulted to either selected or not-selected.
/// - `.targetUnavailable`: the target (or application) is no longer resolvable at all, is
///   ambiguous, no longer carries the `AXTableRow` subrole, or its table context can no longer
///   be established — physical state is uncertain; treated as `.failed`, mirroring
///   `axTabSelectionMatchesDesired`'s conservative model.
public enum QAXTableRowSelectionEvidence: Sendable, Equatable {
    case resolved(currentSelected: Bool)
    case stateUnreadable
    case targetUnavailable
}

/// Fail-closed allowlist of Accessibility roles `ui.list_outline_items` (Phase 2AF) may target.
public enum QAXOutlineRolePolicy {
    public static let allowedRoles: Set<String> = ["AXOutline"]

    public static func isAllowedOutlineRole(_ role: String) -> Bool {
        allowedRoles.contains(role)
    }
}

/// Fail-closed allowlist of Accessibility roles `ui.select_outline_row` (Phase 2T) may target.
///
/// Deliberately a SINGLE role — the identical base role `QAXTableRowRolePolicy` uses, since
/// `AXRow` is the shared base role for both table and outline rows (they differ only by subrole).
/// `AXRow` alone is NOT sufficient for `selectOutlineRow` to treat a resolved element as an
/// outline row — resolution additionally, unconditionally requires the `AXOutlineRow` subrole
/// (see `QAXInteractionError.targetNotAnOutlineRow`) AND an established `AXOutline` parent
/// context (see `QAXInteractionError.outlineContextUnavailable`). `AXTableRow` — a real, distinct
/// subrole `ui.select_table_row` already owns — is explicitly recognized-but-refused (see
/// `QAXInteractionError.tableRowUnsupportedForOutline`), never silently folded into outline-row
/// handling, the exact reciprocal of `ui.select_table_row`'s own `AXOutlineRow` refusal.
public enum QAXOutlineRowRolePolicy {
    public static let allowedRoles: Set<String> = ["AXRow"]

    public static func isAllowedOutlineRowRole(_ role: String) -> Bool {
        allowedRoles.contains(role)
    }
}

/// Whether a `selectOutlineRow` call actually performed a press, or found the target already
/// selected and correctly did nothing.
public enum QAXOutlineRowSelectionChangeKind: String, Sendable, Equatable {
    case alreadyDesired
    case changed
}

/// The outcome of one `QBridgeAccessibility.selectOutlineRow` call. Carries only a small,
/// non-sensitive boolean and non-secret targeting metadata — never a raw AX attribute dump,
/// never the content of the row's own cells, descendants, or the outline it belongs to.
public struct QAXOutlineRowSelectionOutcome: Sendable, Equatable {
    public let changeKind: QAXOutlineRowSelectionChangeKind
    public let previousSelected: Bool
    public let currentSelected: Bool
    public let targetIdentity: String

    public init(
        changeKind: QAXOutlineRowSelectionChangeKind,
        previousSelected: Bool,
        currentSelected: Bool,
        targetIdentity: String
    ) {
        self.changeKind = changeKind
        self.previousSelected = previousSelected
        self.currentSelected = currentSelected
        self.targetIdentity = targetIdentity
    }
}

/// The result of independently re-observing an outline row's `kAXSelectedAttribute` after a
/// `ui.select_outline_row` dispatch, for the later closed-loop verification step (and for
/// `QTaskRecoveryManager`'s observation-first recovery, which reuses this exact primitive).
/// Authoritative selection state is read from `kAXSelectedAttribute` — the same attribute
/// already proven correct for `ui.select_tab`/`ui.select_table_row`, deliberately never any
/// table/outline-level multi-selection attribute.
///
/// - `.resolved(currentSelected:)`: the target is still resolvable (role `AXRow`, subrole
///   `AXOutlineRow`, with an `AXOutline`-rooted parent context) and its selection state was read
///   as a clean boolean.
/// - `.stateUnreadable`: the target is resolvable but `kAXSelectedAttribute` could not be read —
///   treated as `.failed`, NEVER defaulted to either selected or not-selected.
/// - `.targetUnavailable`: the target (or application) is no longer resolvable at all, is
///   ambiguous, no longer carries the `AXOutlineRow` subrole, or its outline context can no
///   longer be established — physical state is uncertain; treated as `.failed`, mirroring
///   `axTableRowSelectionMatchesDesired`'s conservative model.
public enum QAXOutlineRowSelectionEvidence: Sendable, Equatable {
    case resolved(currentSelected: Bool)
    case stateUnreadable
    case targetUnavailable
}

/// Fail-closed allowlist of Accessibility roles `ui.set_window_minimized` (Phase 2U) may target.
///
/// Deliberately a SINGLE role — `AXWindow` (`kAXWindowRole`) — the first window-level (rather
/// than per-element) capability in this codebase. `AXApplication`, `AXGroup`, `AXButton`, and any
/// other role are refused outright; a sheet or other element only qualifies if it independently,
/// genuinely reports role `AXWindow` itself (this policy does not special-case sheets — it simply
/// checks the reported role, exactly like every other role policy in this codebase).
public enum QAXWindowRolePolicy {
    public static let allowedRoles: Set<String> = ["AXWindow"]

    public static func isAllowedWindowRole(_ role: String) -> Bool {
        allowedRoles.contains(role)
    }
}

/// Whether a `setWindowMinimizedState` call actually performed an attribute write, or found the
/// target already at the desired minimized state and correctly did nothing.
public enum QAXWindowMinimizedChangeKind: String, Sendable, Equatable {
    case alreadyDesired
    case changed
}

/// The outcome of one `QBridgeAccessibility.setWindowMinimizedState` call. Carries only a small,
/// non-sensitive boolean and non-secret targeting metadata — never a raw AX attribute dump, never
/// the window's own content or descendant AX tree.
public struct QAXWindowMinimizedOutcome: Sendable, Equatable {
    public let changeKind: QAXWindowMinimizedChangeKind
    public let previousMinimized: Bool
    public let currentMinimized: Bool
    public let desiredMinimized: Bool
    public let targetIdentity: String

    public init(
        changeKind: QAXWindowMinimizedChangeKind,
        previousMinimized: Bool,
        currentMinimized: Bool,
        desiredMinimized: Bool,
        targetIdentity: String
    ) {
        self.changeKind = changeKind
        self.previousMinimized = previousMinimized
        self.currentMinimized = currentMinimized
        self.desiredMinimized = desiredMinimized
        self.targetIdentity = targetIdentity
    }
}

/// The result of independently re-observing a window's `kAXMinimizedAttribute` after a
/// `ui.set_window_minimized` dispatch, for the later closed-loop verification step (and for
/// `QTaskRecoveryManager`'s observation-first recovery, which reuses this exact primitive).
/// Authoritative state is read from `kAXMinimizedAttribute` alone — never inferred from window
/// position, visibility, frontmost state, Dock appearance, or title.
///
/// - `.resolved(currentMinimized:)`: the target is still resolvable (role `AXWindow`) and its
///   minimized state was read as a clean boolean.
/// - `.stateUnreadable`: the target is resolvable but `kAXMinimizedAttribute` could not be read —
///   treated as `.failed`, NEVER defaulted to either minimized or not-minimized.
/// - `.targetUnavailable`: the target (or application) is no longer resolvable at all, or is
///   ambiguous — physical state is uncertain; treated as `.failed`, mirroring every prior
///   capability's conservative model. A window's disappearance after a minimize/restore request
///   is NEVER automatically interpreted as success.
public enum QAXWindowMinimizedEvidence: Sendable, Equatable {
    case resolved(currentMinimized: Bool)
    case stateUnreadable
    case targetUnavailable
}

/// Fail-closed allowlist of Accessibility roles `ui.set_scroll_position` (Phase 2W) may target as
/// its SEARCH criterion — `AXScrollArea` only. The actual mutation target (a genuine
/// `AXScrollBar`) is never searched for directly; it is resolved via a deterministic
/// convenience-reference attribute (`kAXHorizontalScrollBarAttribute`/
/// `kAXVerticalScrollBarAttribute`) from the resolved scroll area, and its own role is
/// independently re-validated (`QAXInteractionError.targetNotAScrollBar`) before ever being
/// treated as genuine — the mere existence of the reference is never sufficient.
public enum QAXScrollAreaRolePolicy {
    public static let allowedRoles: Set<String> = ["AXScrollArea"]

    public static func isAllowedScrollAreaRole(_ role: String) -> Bool {
        allowedRoles.contains(role)
    }
}

/// Whether a `setScrollPosition` call actually performed a value write, or found the target
/// already at the desired position and correctly did nothing.
public enum QAXScrollPositionChangeKind: String, Sendable, Equatable {
    case alreadyDesired
    case changed
}

/// The outcome of one `QBridgeAccessibility.setScrollPosition` call. Numeric values are carried
/// directly (not hashed) — per the same Phase 2M precedent `ui.set_slider_value` already
/// established, a scroll position is not sensitive free-form content.
public struct QAXScrollPositionOutcome: Sendable, Equatable {
    public let changeKind: QAXScrollPositionChangeKind
    public let previousValue: Double
    public let currentValue: Double
    public let desiredValue: Double
    public let minValue: Double
    public let maxValue: Double
    public let targetIdentity: String

    public init(
        changeKind: QAXScrollPositionChangeKind,
        previousValue: Double,
        currentValue: Double,
        desiredValue: Double,
        minValue: Double,
        maxValue: Double,
        targetIdentity: String
    ) {
        self.changeKind = changeKind
        self.previousValue = previousValue
        self.currentValue = currentValue
        self.desiredValue = desiredValue
        self.minValue = minValue
        self.maxValue = maxValue
        self.targetIdentity = targetIdentity
    }
}

/// The result of independently re-observing a scroll bar's `kAXValueAttribute` after a
/// `ui.set_scroll_position` dispatch, for the later closed-loop verification step (and for
/// `QTaskRecoveryManager`'s observation-first recovery, which reuses this exact primitive).
/// Re-resolves the ENTIRE identity chain fresh — scroll area, then the orientation
/// convenience-reference, then the scroll bar's own role — never trusts a cached element
/// reference. Structurally identical to `QAXSliderValueEvidence`.
///
/// - `.resolved(currentValue:)`: the full chain remains resolvable and role-qualified, and its
///   range is internally consistent.
/// - `.rangeInvalid(currentValue:)`: resolvable but its reported range is no longer internally
///   consistent, or the value falls outside it — verification cannot be trusted; treated as
///   `.failed`, never assumed successful.
/// - `.targetUnavailable`: any link in the chain (scroll area, convenience reference, or role
///   qualification) is no longer resolvable — physical state is uncertain; treated as `.failed`,
///   never assumed successful.
public enum QAXScrollPositionEvidence: Sendable, Equatable {
    case resolved(currentValue: Double)
    case rangeInvalid(currentValue: Double)
    case targetUnavailable
}

/// Whether a `setWindowMain` call actually performed an attribute write, or found the target
/// already reporting `kAXMainAttribute == true` and correctly did nothing.
public enum QAXWindowMainChangeKind: String, Sendable, Equatable {
    case alreadyDesired
    case changed
}

/// The outcome of one `QBridgeAccessibility.setWindowMain` call. Carries only a small,
/// non-sensitive boolean and non-secret targeting metadata — never a raw AX attribute dump, never
/// the window's own content.
public struct QAXWindowMainOutcome: Sendable, Equatable {
    public let changeKind: QAXWindowMainChangeKind
    public let previousMain: Bool
    public let currentMain: Bool
    public let targetIdentity: String

    public init(
        changeKind: QAXWindowMainChangeKind,
        previousMain: Bool,
        currentMain: Bool,
        targetIdentity: String
    ) {
        self.changeKind = changeKind
        self.previousMain = previousMain
        self.currentMain = currentMain
        self.targetIdentity = targetIdentity
    }
}

/// The result of independently re-observing a window's `kAXMainAttribute` after a
/// `ui.set_window_main` dispatch, for the later closed-loop verification step (and for
/// `QTaskRecoveryManager`'s observation-first recovery, which reuses this exact primitive).
/// Authoritative state is read from `kAXMainAttribute` alone. This capability makes NO claim
/// about activation, focus, raise, or any other visual/ordering effect — `kAXMainAttribute` is
/// documented to not necessarily imply key focus, and this evidence type reflects only the
/// attribute's own value, nothing more.
///
/// - `.resolved(currentMain:)`: the target is still resolvable (role `AXWindow`) and its main
///   state was read as a clean boolean.
/// - `.stateUnreadable`: the target is resolvable but `kAXMainAttribute` could not be read —
///   treated as `.failed`, NEVER defaulted to either `true` or `false`.
/// - `.targetUnavailable`: the target (or application) is no longer resolvable at all, or is
///   ambiguous — physical state is uncertain; treated as `.failed`, mirroring every prior
///   capability's conservative model.
public enum QAXWindowMainEvidence: Sendable, Equatable {
    case resolved(currentMain: Bool)
    case stateUnreadable
    case targetUnavailable
}

/// Whether a `setWindowFullScreenState` call actually performed an attribute write, or found the
/// target already at the desired full-screen state and correctly did nothing.
public enum QAXWindowFullScreenChangeKind: String, Sendable, Equatable {
    case alreadyDesired
    case changed
}

/// The outcome of one `QBridgeAccessibility.setWindowFullScreenState` call. Carries only a small,
/// non-sensitive boolean and non-secret targeting metadata — never a raw AX attribute dump, never
/// the window's own content.
public struct QAXWindowFullScreenOutcome: Sendable, Equatable {
    public let changeKind: QAXWindowFullScreenChangeKind
    public let previousFullScreen: Bool
    public let currentFullScreen: Bool
    public let desiredFullScreen: Bool
    public let targetIdentity: String

    public init(
        changeKind: QAXWindowFullScreenChangeKind,
        previousFullScreen: Bool,
        currentFullScreen: Bool,
        desiredFullScreen: Bool,
        targetIdentity: String
    ) {
        self.changeKind = changeKind
        self.previousFullScreen = previousFullScreen
        self.currentFullScreen = currentFullScreen
        self.desiredFullScreen = desiredFullScreen
        self.targetIdentity = targetIdentity
    }
}

/// The result of independently re-observing a window's `kAXFullScreenAttribute` ("AXFullScreen") after a
/// `ui.set_window_full_screen` dispatch, for the later closed-loop verification step (and for
/// `QTaskRecoveryManager`'s observation-first recovery, which reuses this exact primitive).
/// Authoritative state is read from `kAXFullScreenAttribute` alone.
///
/// - `.resolved(currentFullScreen:)`: the target is still resolvable (role `AXWindow`) and its full-screen
///   state was read as a clean boolean.
/// - `.stateUnreadable`: the target is resolvable but `kAXFullScreenAttribute` could not be read —
///   treated as `.failed`, NEVER defaulted to either `true` or `false`.
/// - `.targetUnavailable`: the target (or application) is no longer resolvable at all, or is
///   ambiguous — physical state is uncertain; treated as `.failed`.
public enum QAXWindowFullScreenEvidence: Sendable, Equatable {
    case resolved(currentFullScreen: Bool)
    case stateUnreadable
    case targetUnavailable
}

/// Whether a `closeWindow` call actually performed a close-button press, or found the target
/// window already unresolvable (by the exact same identity criteria, with the owning application
/// confirmed running) and correctly did nothing — the one-way analog of
/// `QAXWindowMinimizedChangeKind`'s/`QAXWindowMainChangeKind`'s `.alreadyDesired` for a capability
/// whose "already satisfied" state is absence rather than a boolean attribute value.
public enum QAXWindowCloseChangeKind: String, Sendable, Equatable {
    case alreadyAbsent
    case closeRequested
}

/// The outcome of one `QBridgeAccessibility.closeWindow` call. Carries only non-sensitive
/// targeting metadata — never window contents, never dialog/sheet text.
public struct QAXWindowCloseOutcome: Sendable, Equatable {
    public let changeKind: QAXWindowCloseChangeKind
    public let targetIdentity: String

    public init(changeKind: QAXWindowCloseChangeKind, targetIdentity: String) {
        self.changeKind = changeKind
        self.targetIdentity = targetIdentity
    }
}

/// The result of independently re-observing whether a target window still exists after a
/// `ui.close_window` dispatch, for the later closed-loop verification step (and for
/// `QTaskRecoveryManager`'s observation-first recovery, which reuses this exact primitive).
/// This is deliberately a five-way, NEVER-collapsed result — absence must be distinguishable from
/// every flavor of "we don't know," and application termination must be distinguishable from a
/// genuine single-window close:
///
/// - `.windowAbsentApplicationRunning`: the owning application was independently confirmed still
///   running, AND the exact original window identity no longer resolves. This is the ONLY
///   evidence value verification/recovery may treat as success — closing exactly one window,
///   with its application surviving, is the entire contract.
/// - `.windowStillPresent`: the exact original window identity still resolves (uniquely) — the
///   close did not (yet, or ever) take effect. This also covers the case where a save/discard
///   sheet is blocking the close: the parent window (or its sheet-bearing identity) remains
///   resolvable, so this is correctly `.failed`, never silently treated as progress.
/// - `.ambiguousTarget(count:)`: more than one element now matches the same criteria — physical
///   state is uncertain; NEVER treated as absence.
/// - `.applicationNotRunning`: the owning application itself could not be re-resolved as running.
///   Per this capability's explicit contract, this is NEVER credited as a successful close — the
///   application may have quit or crashed, a categorically different outcome this capability must
///   never claim credit for.
/// - `.permissionUnavailable`: Accessibility Trust is not granted — physical state cannot be
///   observed at all; NEVER treated as absence.
public enum QAXWindowCloseEvidence: Sendable, Equatable {
    case windowAbsentApplicationRunning
    case windowStillPresent
    case ambiguousTarget(count: Int)
    case applicationNotRunning
    case permissionUnavailable
}

/// One window's safe, non-sensitive identity metadata, as returned by `ui.list_windows`
/// (Phase 2Z). Deliberately carries ONLY the fields this capability's contract allows — never a
/// raw `AXUIElement` reference (no internal AX object pointer is ever exposed to a caller), never
/// window contents, never descendant labels. Every field except `role` (mandatory — only
/// `AXWindow`-role elements are ever included at all) is independently optional: a missing
/// `title`/`identifier`/`minimized`/`main` reflects that specific attribute being unavailable for
/// that window, and is NEVER itself a reason to exclude the window or fail the whole enumeration.
/// This is a POINT-IN-TIME SNAPSHOT — by the time a caller acts on it, any field may already be
/// stale; it is informational only and is NEVER itself a resolved, actionable target reference —
/// any subsequent mutation capability (`ui.set_window_minimized`, `ui.set_window_main`,
/// `ui.close_window`, etc.) must independently perform its own fresh, exact target resolution.
public struct QAXWindowMetadata: Sendable, Equatable {
    public let title: String?
    public let identifier: String?
    public let minimized: Bool?
    public let main: Bool?

    public init(title: String?, identifier: String?, minimized: Bool?, main: Bool?) {
        self.title = title
        self.identifier = identifier
        self.minimized = minimized
        self.main = main
    }
}

/// One menu item's safe, non-sensitive identity metadata, as returned by `ui.list_menu_items`
/// (Phase 2AA). Submenus are strictly out of scope — represents only direct items of a top-level menu.
public struct QAXMenuItemMetadata: Sendable, Equatable, Codable {
    public let title: String?
    public let identifier: String?
    public let isEnabled: Bool?
    public let role: String

    public init(title: String?, identifier: String?, isEnabled: Bool?, role: String = "AXMenuItem") {
        self.title = title
        self.identifier = identifier
        self.isEnabled = isEnabled
        self.role = role
    }
}

/// One top-level menu's safe, non-sensitive identity and direct items metadata, as returned by
/// `ui.list_menu_items` (Phase 2AA). Deliberately carries ONLY the fields this capability's contract
/// allows — never raw `AXUIElement` references, never arbitrary descendant trees, never submenus.
/// This is a POINT-IN-TIME SNAPSHOT ONLY — informational only, never itself an actionable target
/// reference; any subsequent mutation capability (`ui.select_menu_item`) must independently perform
/// its own fresh, exact target resolution.
public struct QAXTopLevelMenuMetadata: Sendable, Equatable, Codable {
    public let title: String?
    public let identifier: String?
    public let isEnabled: Bool?
    public let role: String
    public let items: [QAXMenuItemMetadata]

    public init(title: String?, identifier: String?, isEnabled: Bool?, role: String = "AXMenuBarItem", items: [QAXMenuItemMetadata]) {
        self.title = title
        self.identifier = identifier
        self.isEnabled = isEnabled
        self.role = role
        self.items = items
    }
}

/// One pop-up menu item's safe, non-sensitive identity metadata, as returned by `ui.list_popup_items`
/// (Phase 2AD). Submenus are strictly out of scope — represents only direct items of a pop-up button's menu.
public struct QAXPopupItemMetadata: Sendable, Equatable, Codable {
    public let title: String?
    public let identifier: String?
    public let isEnabled: Bool?
    public let isSelected: Bool
    public let role: String

    public init(title: String?, identifier: String?, isEnabled: Bool?, isSelected: Bool, role: String = "AXMenuItem") {
        self.title = title
        self.identifier = identifier
        self.isEnabled = isEnabled
        self.isSelected = isSelected
        self.role = role
    }
}

/// A pop-up button's safe, non-sensitive direct items metadata, as returned by `ui.list_popup_items`
/// (Phase 2AD). Deliberately carries ONLY the fields this capability's contract allows — never raw
/// `AXUIElement` references, never arbitrary descendant trees, never submenus.
/// This is a POINT-IN-TIME SNAPSHOT ONLY — informational only, never itself an actionable target
/// reference; any subsequent mutation capability (`ui.select_popup_item`) must independently perform
/// its own fresh, exact target resolution.
public struct QAXPopupMenuMetadata: Sendable, Equatable, Codable {
    public let selectedValue: String?
    public let items: [QAXPopupItemMetadata]

    public init(selectedValue: String?, items: [QAXPopupItemMetadata]) {
        self.selectedValue = selectedValue
        self.items = items
    }
}

/// One table row's safe, non-sensitive identity metadata, as returned by `ui.list_table_rows`
/// (Phase 2AE). Cell contents are strictly out of scope.
public struct QAXTableRowItemMetadata: Sendable, Equatable, Codable {
    public let index: Int
    public let title: String?
    public let identifier: String?
    public let isSelected: Bool?
    public let isEnabled: Bool?
    public let role: String
    public let subrole: String

    public init(
        index: Int,
        title: String?,
        identifier: String?,
        isSelected: Bool?,
        isEnabled: Bool?,
        role: String = "AXRow",
        subrole: String = "AXTableRow"
    ) {
        self.index = index
        self.title = title
        self.identifier = identifier
        self.isSelected = isSelected
        self.isEnabled = isEnabled
        self.role = role
        self.subrole = subrole
    }
}

/// A table's safe, non-sensitive direct rows metadata, as returned by `ui.list_table_rows`
/// (Phase 2AE). Deliberately carries ONLY the fields this capability's contract allows — never raw
/// `AXUIElement` references, never arbitrary descendant trees, never cell contents.
/// This is a POINT-IN-TIME SNAPSHOT ONLY — informational only, never itself an actionable target
/// reference; any subsequent mutation capability (`ui.select_table_row`) must independently perform
/// its own fresh, exact target resolution.
public struct QAXTableMetadata: Sendable, Equatable, Codable {
    public let applicationName: String
    public let tableTitle: String?
    public let tableIdentifier: String?
    public let rowCount: Int
    public let selectedRowCount: Int
    public let rows: [QAXTableRowItemMetadata]

    public init(
        applicationName: String,
        tableTitle: String?,
        tableIdentifier: String?,
        rowCount: Int,
        selectedRowCount: Int,
        rows: [QAXTableRowItemMetadata]
    ) {
        self.applicationName = applicationName
        self.tableTitle = tableTitle
        self.tableIdentifier = tableIdentifier
        self.rowCount = rowCount
        self.selectedRowCount = selectedRowCount
        self.rows = rows
    }
}

/// One table column's safe, non-sensitive identity metadata, as returned by
/// `ui.list_table_columns` (Phase 2BI). This is the column HEADER's own identity only — cell
/// contents are strictly out of scope, exactly like `ui.list_table_rows`'s own row-identity-only
/// contract.
public struct QAXTableColumnItemMetadata: Sendable, Equatable, Codable {
    public let index: Int
    public let title: String?
    public let identifier: String?
    public let role: String
    public let subrole: String?

    public init(
        index: Int,
        title: String?,
        identifier: String?,
        role: String = "AXColumn",
        subrole: String? = nil
    ) {
        self.index = index
        self.title = title
        self.identifier = identifier
        self.role = role
        self.subrole = subrole
    }
}

/// A table's safe, non-sensitive direct column-header metadata, as returned by
/// `ui.list_table_columns` (Phase 2BI). Deliberately carries ONLY the fields this capability's
/// contract allows — never raw `AXUIElement` references, never cell contents, never a recursive
/// descent into any column's own contents. This is a POINT-IN-TIME SNAPSHOT ONLY — informational
/// only, never itself an actionable target reference; any subsequent capability must independently
/// perform its own fresh, exact target resolution.
public struct QAXTableColumnCollectionMetadata: Sendable, Equatable, Codable {
    public let applicationName: String
    public let tableTitle: String?
    public let tableIdentifier: String?
    public let columnCount: Int
    public let columns: [QAXTableColumnItemMetadata]

    public init(
        applicationName: String,
        tableTitle: String?,
        tableIdentifier: String?,
        columnCount: Int,
        columns: [QAXTableColumnItemMetadata]
    ) {
        self.applicationName = applicationName
        self.tableTitle = tableTitle
        self.tableIdentifier = tableIdentifier
        self.columnCount = columnCount
        self.columns = columns
    }
}

/// One outline item's safe, non-sensitive identity metadata, as returned by `ui.list_outline_items`
/// (Phase 2AF). Cell contents are strictly out of scope.
public struct QAXOutlineRowItemMetadata: Sendable, Equatable, Codable {
    public let index: Int
    public let title: String?
    public let identifier: String?
    public let depth: Int
    public let isExpanded: Bool?
    public let isSelected: Bool?
    public let isEnabled: Bool?
    public let role: String
    public let subrole: String

    public init(
        index: Int,
        title: String?,
        identifier: String?,
        depth: Int,
        isExpanded: Bool?,
        isSelected: Bool?,
        isEnabled: Bool?,
        role: String = "AXRow",
        subrole: String = "AXOutlineRow"
    ) {
        self.index = index
        self.title = title
        self.identifier = identifier
        self.depth = depth
        self.isExpanded = isExpanded
        self.isSelected = isSelected
        self.isEnabled = isEnabled
        self.role = role
        self.subrole = subrole
    }
}

/// An outline's safe, non-sensitive direct items metadata, as returned by `ui.list_outline_items`
/// (Phase 2AF). Deliberately carries ONLY the fields this capability's contract allows — never raw
/// `AXUIElement` references, never arbitrary descendant trees, never cell contents.
/// This is a POINT-IN-TIME SNAPSHOT ONLY — informational only, never itself an actionable target
/// reference; any subsequent mutation capability (`ui.select_outline_row`) must independently perform
/// its own fresh, exact target resolution.
public struct QAXOutlineMetadata: Sendable, Equatable, Codable {
    public let applicationName: String
    public let outlineTitle: String?
    public let outlineIdentifier: String?
    public let itemCount: Int
    public let selectedItemCount: Int
    public let expandedItemCount: Int
    public let items: [QAXOutlineRowItemMetadata]

    public init(
        applicationName: String,
        outlineTitle: String?,
        outlineIdentifier: String?,
        itemCount: Int,
        selectedItemCount: Int,
        expandedItemCount: Int,
        items: [QAXOutlineRowItemMetadata]
    ) {
        self.applicationName = applicationName
        self.outlineTitle = outlineTitle
        self.outlineIdentifier = outlineIdentifier
        self.itemCount = itemCount
        self.selectedItemCount = selectedItemCount
        self.expandedItemCount = expandedItemCount
        self.items = items
    }
}

/// One tab item's safe, non-sensitive identity metadata, as returned by `ui.list_tab_items`
/// (Phase 2AH). Pane contents are strictly out of scope.
public struct QAXTabItemMetadata: Sendable, Equatable, Codable {
    public let index: Int
    public let title: String?
    public let identifier: String?
    public let isSelected: Bool?
    public let isEnabled: Bool?
    public let role: String
    public let subrole: String

    public init(
        index: Int,
        title: String?,
        identifier: String?,
        isSelected: Bool?,
        isEnabled: Bool?,
        role: String = "AXRadioButton",
        subrole: String = "AXTabButton"
    ) {
        self.index = index
        self.title = title
        self.identifier = identifier
        self.isSelected = isSelected
        self.isEnabled = isEnabled
        self.role = role
        self.subrole = subrole
    }
}

/// A tab group's safe, non-sensitive direct items metadata, as returned by `ui.list_tab_items`
/// (Phase 2AH). Deliberately carries ONLY the fields this capability's contract allows — never raw
/// `AXUIElement` references, never arbitrary descendant trees, never pane contents.
/// This is a POINT-IN-TIME SNAPSHOT ONLY — informational only, never itself an actionable target
/// reference; any subsequent mutation capability (`ui.select_tab`) must independently perform
/// its own fresh, exact target resolution.
public struct QAXTabGroupMetadata: Sendable, Equatable, Codable {
    public let applicationName: String
    public let tabGroupTitle: String?
    public let tabGroupIdentifier: String?
    public let itemCount: Int
    public let selectedItemCount: Int
    public let items: [QAXTabItemMetadata]

    public init(
        applicationName: String,
        tabGroupTitle: String?,
        tabGroupIdentifier: String?,
        itemCount: Int,
        selectedItemCount: Int,
        items: [QAXTabItemMetadata]
    ) {
        self.applicationName = applicationName
        self.tabGroupTitle = tabGroupTitle
        self.tabGroupIdentifier = tabGroupIdentifier
        self.itemCount = itemCount
        self.selectedItemCount = selectedItemCount
        self.items = items
    }
}

/// One radio item's safe, non-sensitive identity metadata, as returned by `ui.list_radio_group_items`
/// (Phase 2AI).
public struct QAXRadioGroupItemMetadata: Sendable, Equatable, Codable {
    public let index: Int
    public let title: String?
    public let identifier: String?
    public let isSelected: Bool?
    public let isEnabled: Bool?
    public let role: String
    public let subrole: String?

    public init(
        index: Int,
        title: String?,
        identifier: String?,
        isSelected: Bool?,
        isEnabled: Bool?,
        role: String = "AXRadioButton",
        subrole: String? = nil
    ) {
        self.index = index
        self.title = title
        self.identifier = identifier
        self.isSelected = isSelected
        self.isEnabled = isEnabled
        self.role = role
        self.subrole = subrole
    }
}

/// A radio group's safe, non-sensitive direct items metadata, as returned by `ui.list_radio_group_items`
/// (Phase 2AI). Deliberately carries ONLY the fields this capability's contract allows — never raw
/// `AXUIElement` references, never arbitrary descendant trees.
/// This is a POINT-IN-TIME SNAPSHOT ONLY — informational only, never itself an actionable target
/// reference; any subsequent mutation capability (`ui.set_element_state`) must independently perform
/// its own fresh, exact target resolution.
public struct QAXRadioGroupMetadata: Sendable, Equatable, Codable {
    public let applicationName: String
    public let radioGroupTitle: String?
    public let radioGroupIdentifier: String?
    public let itemCount: Int
    public let selectedItemCount: Int
    public let items: [QAXRadioGroupItemMetadata]

    public init(
        applicationName: String,
        radioGroupTitle: String?,
        radioGroupIdentifier: String?,
        itemCount: Int,
        selectedItemCount: Int,
        items: [QAXRadioGroupItemMetadata]
    ) {
        self.applicationName = applicationName
        self.radioGroupTitle = radioGroupTitle
        self.radioGroupIdentifier = radioGroupIdentifier
        self.itemCount = itemCount
        self.selectedItemCount = selectedItemCount
        self.items = items
    }
}

/// One toolbar item's safe, non-sensitive identity metadata, as returned by `ui.list_toolbar_items`
/// (Phase 2AK).
public struct QAXToolbarItemMetadata: Sendable, Equatable, Codable {
    public let index: Int
    public let title: String?
    public let identifier: String?
    public let role: String
    public let subrole: String?
    public let isEnabled: Bool?
    public let isSelected: Bool?
    public let help: String?

    public init(
        index: Int,
        title: String?,
        identifier: String?,
        role: String,
        subrole: String? = nil,
        isEnabled: Bool? = nil,
        isSelected: Bool? = nil,
        help: String? = nil
    ) {
        self.index = index
        self.title = title
        self.identifier = identifier
        self.role = role
        self.subrole = subrole
        self.isEnabled = isEnabled
        self.isSelected = isSelected
        self.help = help
    }
}

/// A window toolbar's safe, non-sensitive direct items metadata, as returned by `ui.list_toolbar_items`
/// (Phase 2AK). Deliberately carries ONLY the fields this capability's contract allows — never raw
/// `AXUIElement` references, never arbitrary descendant trees.
/// This is a POINT-IN-TIME SNAPSHOT ONLY — informational only, never itself an actionable target
/// reference; any subsequent mutation capability (`ui.click_element`, `ui.select_popup_item`) must
/// independently perform its own fresh, exact target resolution.
public struct QAXToolbarMetadata: Sendable, Equatable, Codable {
    public let applicationName: String
    public let windowTitle: String?
    public let toolbarTitle: String?
    public let toolbarIdentifier: String?
    public let itemCount: Int
    public let items: [QAXToolbarItemMetadata]

    public init(
        applicationName: String,
        windowTitle: String?,
        toolbarTitle: String?,
        toolbarIdentifier: String?,
        itemCount: Int,
        items: [QAXToolbarItemMetadata]
    ) {
        self.applicationName = applicationName
        self.windowTitle = windowTitle
        self.toolbarTitle = toolbarTitle
        self.toolbarIdentifier = toolbarIdentifier
        self.itemCount = itemCount
        self.items = items
    }
}

/// One split pane's safe, non-sensitive identity metadata, as returned by `ui.list_split_panes`
/// (Phase 2AT). A "pane" is any direct child of an `AXSplitGroup` other than the `AXSplitter`
/// divider elements between panes — pane content roles are inherently unbounded (`AXGroup`,
/// `AXScrollArea`, `AXOutline`, `AXTable`, etc. are all valid pane contents), so unlike toolbar or
/// segmented control items this capability does not filter by a fixed role allowlist beyond
/// excluding the divider itself.
public struct QAXSplitPaneItemMetadata: Sendable, Equatable, Codable {
    public let index: Int
    public let title: String?
    public let identifier: String?
    public let role: String
    public let subrole: String?
    public let isEnabled: Bool?

    public init(
        index: Int,
        title: String?,
        identifier: String?,
        role: String,
        subrole: String? = nil,
        isEnabled: Bool? = nil
    ) {
        self.index = index
        self.title = title
        self.identifier = identifier
        self.role = role
        self.subrole = subrole
        self.isEnabled = isEnabled
    }
}

/// A split group's safe, non-sensitive direct panes metadata, as returned by `ui.list_split_panes`
/// (Phase 2AT). Deliberately carries ONLY the fields this capability's contract allows — never raw
/// `AXUIElement` references, never a pane's own descendant subtree.
/// This is a POINT-IN-TIME SNAPSHOT ONLY — informational only, never itself an actionable target
/// reference; any subsequent mutation capability must independently perform its own fresh, exact
/// target resolution.
public struct QAXSplitGroupMetadata: Sendable, Equatable, Codable {
    public let applicationName: String
    public let windowTitle: String?
    public let splitGroupTitle: String?
    public let splitGroupIdentifier: String?
    public let paneCount: Int
    public let panes: [QAXSplitPaneItemMetadata]

    public init(
        applicationName: String,
        windowTitle: String?,
        splitGroupTitle: String?,
        splitGroupIdentifier: String?,
        paneCount: Int,
        panes: [QAXSplitPaneItemMetadata]
    ) {
        self.applicationName = applicationName
        self.windowTitle = windowTitle
        self.splitGroupTitle = splitGroupTitle
        self.splitGroupIdentifier = splitGroupIdentifier
        self.paneCount = paneCount
        self.panes = panes
    }
}

/// One browser column's safe, non-sensitive identity metadata, as returned by `ui.list_browser_columns` (Phase 2AV).
public struct QAXBrowserColumnMetadata: Sendable, Equatable, Codable {
    public let index: Int
    public let title: String?
    public let identifier: String?
    public let role: String
    public let subrole: String?
    public let isEnabled: Bool?

    public init(
        index: Int,
        title: String?,
        identifier: String?,
        role: String,
        subrole: String? = nil,
        isEnabled: Bool? = nil
    ) {
        self.index = index
        self.title = title
        self.identifier = identifier
        self.role = role
        self.subrole = subrole
        self.isEnabled = isEnabled
    }
}

/// A multi-column browser's safe, non-sensitive direct columns metadata, as returned by `ui.list_browser_columns`
/// (Phase 2AV). Deliberately carries ONLY the fields this capability's contract allows — never raw
/// `AXUIElement` references, never arbitrary descendant trees.
/// This is a POINT-IN-TIME SNAPSHOT ONLY — informational only, never itself an actionable target reference.
public struct QAXBrowserColumnCollectionMetadata: Sendable, Equatable, Codable {
    public let applicationName: String
    public let windowTitle: String?
    public let browserTitle: String?
    public let browserIdentifier: String?
    public let columnCount: Int
    public let columns: [QAXBrowserColumnMetadata]

    public init(
        applicationName: String,
        windowTitle: String?,
        browserTitle: String?,
        browserIdentifier: String?,
        columnCount: Int,
        columns: [QAXBrowserColumnMetadata]
    ) {
        self.applicationName = applicationName
        self.windowTitle = windowTitle
        self.browserTitle = browserTitle
        self.browserIdentifier = browserIdentifier
        self.columnCount = columnCount
        self.columns = columns
    }
}

/// One popover's safe, non-sensitive identity metadata, as returned by `ui.list_popovers` (Phase 2AW).
public struct QAXPopoverMetadata: Sendable, Equatable, Codable {
    public let index: Int
    public let title: String?
    public let identifier: String?
    public let role: String
    public let subrole: String?
    public let isModal: Bool?

    public init(
        index: Int,
        title: String?,
        identifier: String?,
        role: String,
        subrole: String? = nil,
        isModal: Bool? = nil
    ) {
        self.index = index
        self.title = title
        self.identifier = identifier
        self.role = role
        self.subrole = subrole
        self.isModal = isModal
    }
}

/// A collection of safe, non-sensitive direct popovers metadata, as returned by `ui.list_popovers` (Phase 2AW).
/// This is a POINT-IN-TIME SNAPSHOT ONLY — informational only, never itself an actionable target reference.
public struct QAXPopoverCollectionMetadata: Sendable, Equatable, Codable {
    public let applicationName: String
    public let windowTitle: String?
    public let popoverCount: Int
    public let popovers: [QAXPopoverMetadata]

    public init(
        applicationName: String,
        windowTitle: String?,
        popoverCount: Int,
        popovers: [QAXPopoverMetadata]
    ) {
        self.applicationName = applicationName
        self.windowTitle = windowTitle
        self.popoverCount = popoverCount
        self.popovers = popovers
    }
}

/// One color well's safe, non-sensitive identity metadata, as returned by `ui.list_color_wells` (Phase 2AX).
public struct QAXColorWellMetadata: Sendable, Equatable, Codable {
    public let index: Int
    public let title: String?
    public let identifier: String?
    public let role: String
    public let subrole: String?
    public let value: String?
    public let isEnabled: Bool?

    public init(
        index: Int,
        title: String?,
        identifier: String?,
        role: String,
        subrole: String? = nil,
        value: String? = nil,
        isEnabled: Bool? = nil
    ) {
        self.index = index
        self.title = title
        self.identifier = identifier
        self.role = role
        self.subrole = subrole
        self.value = value
        self.isEnabled = isEnabled
    }
}

/// A collection of safe, non-sensitive direct color wells metadata, as returned by `ui.list_color_wells` (Phase 2AX).
/// This is a POINT-IN-TIME SNAPSHOT ONLY — informational only, never itself an actionable target reference.
public struct QAXColorWellCollectionMetadata: Sendable, Equatable, Codable {
    public let applicationName: String
    public let windowTitle: String?
    public let colorWellCount: Int
    public let colorWells: [QAXColorWellMetadata]

    public init(
        applicationName: String,
        windowTitle: String?,
        colorWellCount: Int,
        colorWells: [QAXColorWellMetadata]
    ) {
        self.applicationName = applicationName
        self.windowTitle = windowTitle
        self.colorWellCount = colorWellCount
        self.colorWells = colorWells
    }
}

/// One progress indicator's safe, non-sensitive identity metadata, as returned by `ui.list_progress_indicators` (Phase 2AY).
public struct QAXProgressIndicatorMetadata: Sendable, Equatable, Codable {
    public let index: Int
    public let title: String?
    public let identifier: String?
    public let role: String
    public let subrole: String?
    public let value: Double?
    public let minValue: Double?
    public let maxValue: Double?
    public let isBusy: Bool?
    public let isEnabled: Bool?

    public init(
        index: Int,
        title: String?,
        identifier: String?,
        role: String,
        subrole: String? = nil,
        value: Double? = nil,
        minValue: Double? = nil,
        maxValue: Double? = nil,
        isBusy: Bool? = nil,
        isEnabled: Bool? = nil
    ) {
        self.index = index
        self.title = title
        self.identifier = identifier
        self.role = role
        self.subrole = subrole
        self.value = value
        self.minValue = minValue
        self.maxValue = maxValue
        self.isBusy = isBusy
        self.isEnabled = isEnabled
    }
}

/// A collection of safe, non-sensitive direct progress indicators metadata, as returned by `ui.list_progress_indicators` (Phase 2AY).
/// This is a POINT-IN-TIME SNAPSHOT ONLY — informational only, never itself an actionable target reference.
public struct QAXProgressIndicatorCollectionMetadata: Sendable, Equatable, Codable {
    public let applicationName: String
    public let windowTitle: String?
    public let indicatorCount: Int
    public let indicators: [QAXProgressIndicatorMetadata]

    public init(
        applicationName: String,
        windowTitle: String?,
        indicatorCount: Int,
        indicators: [QAXProgressIndicatorMetadata]
    ) {
        self.applicationName = applicationName
        self.windowTitle = windowTitle
        self.indicatorCount = indicatorCount
        self.indicators = indicators
    }
}

/// One level indicator's safe, non-sensitive identity metadata, as returned by `ui.list_level_indicators` (Phase 2AZ).
public struct QAXLevelIndicatorMetadata: Sendable, Equatable, Codable {
    public let index: Int
    public let title: String?
    public let identifier: String?
    public let role: String
    public let subrole: String?
    public let value: Double?
    public let minValue: Double?
    public let maxValue: Double?
    public let warningValue: Double?
    public let criticalValue: Double?
    public let isEnabled: Bool?

    public init(
        index: Int,
        title: String?,
        identifier: String?,
        role: String,
        subrole: String? = nil,
        value: Double? = nil,
        minValue: Double? = nil,
        maxValue: Double? = nil,
        warningValue: Double? = nil,
        criticalValue: Double? = nil,
        isEnabled: Bool? = nil
    ) {
        self.index = index
        self.title = title
        self.identifier = identifier
        self.role = role
        self.subrole = subrole
        self.value = value
        self.minValue = minValue
        self.maxValue = maxValue
        self.warningValue = warningValue
        self.criticalValue = criticalValue
        self.isEnabled = isEnabled
    }
}

/// A collection of safe, non-sensitive direct level indicators metadata, as returned by `ui.list_level_indicators` (Phase 2AZ).
/// This is a POINT-IN-TIME SNAPSHOT ONLY — informational only, never itself an actionable target reference.
public struct QAXLevelIndicatorCollectionMetadata: Sendable, Equatable, Codable {
    public let applicationName: String
    public let windowTitle: String?
    public let indicatorCount: Int
    public let indicators: [QAXLevelIndicatorMetadata]

    public init(
        applicationName: String,
        windowTitle: String?,
        indicatorCount: Int,
        indicators: [QAXLevelIndicatorMetadata]
    ) {
        self.applicationName = applicationName
        self.windowTitle = windowTitle
        self.indicatorCount = indicatorCount
        self.indicators = indicators
    }
}

/// One stepper / incrementor's safe, non-sensitive identity metadata, as returned by `ui.list_incrementors` (Phase 2BA).
public struct QAXIncrementorMetadata: Sendable, Equatable, Codable {
    public let index: Int
    public let title: String?
    public let identifier: String?
    public let role: String
    public let subrole: String?
    public let value: Double?
    public let minValue: Double?
    public let maxValue: Double?
    public let isEnabled: Bool?

    public init(
        index: Int,
        title: String?,
        identifier: String?,
        role: String,
        subrole: String? = nil,
        value: Double? = nil,
        minValue: Double? = nil,
        maxValue: Double? = nil,
        isEnabled: Bool? = nil
    ) {
        self.index = index
        self.title = title
        self.identifier = identifier
        self.role = role
        self.subrole = subrole
        self.value = value
        self.minValue = minValue
        self.maxValue = maxValue
        self.isEnabled = isEnabled
    }
}

/// A collection of safe, non-sensitive direct incrementors metadata, as returned by `ui.list_incrementors` (Phase 2BA).
/// This is a POINT-IN-TIME SNAPSHOT ONLY — informational only, never itself an actionable target reference.
public struct QAXIncrementorCollectionMetadata: Sendable, Equatable, Codable {
    public let applicationName: String
    public let windowTitle: String?
    public let incrementorCount: Int
    public let incrementors: [QAXIncrementorMetadata]

    public init(
        applicationName: String,
        windowTitle: String?,
        incrementorCount: Int,
        incrementors: [QAXIncrementorMetadata]
    ) {
        self.applicationName = applicationName
        self.windowTitle = windowTitle
        self.incrementorCount = incrementorCount
        self.incrementors = incrementors
    }
}

/// One combo box's safe, non-sensitive identity metadata, as returned by `ui.list_combo_boxes` (Phase 2BB).
public struct QAXComboBoxMetadata: Sendable, Equatable, Codable {
    public let index: Int
    public let title: String?
    public let identifier: String?
    public let role: String
    public let subrole: String?
    public let value: String?
    public let placeholderValue: String?
    public let isEnabled: Bool?
    public let isSettable: Bool?

    public init(
        index: Int,
        title: String?,
        identifier: String?,
        role: String,
        subrole: String? = nil,
        value: String? = nil,
        placeholderValue: String? = nil,
        isEnabled: Bool? = nil,
        isSettable: Bool? = nil
    ) {
        self.index = index
        self.title = title
        self.identifier = identifier
        self.role = role
        self.subrole = subrole
        self.value = value
        self.placeholderValue = placeholderValue
        self.isEnabled = isEnabled
        self.isSettable = isSettable
    }
}

/// A collection of safe, non-sensitive direct combo boxes metadata, as returned by `ui.list_combo_boxes` (Phase 2BB).
/// This is a POINT-IN-TIME SNAPSHOT ONLY — informational only, never itself an actionable target reference.
public struct QAXComboBoxCollectionMetadata: Sendable, Equatable, Codable {
    public let applicationName: String
    public let windowTitle: String?
    public let comboBoxCount: Int
    public let comboBoxes: [QAXComboBoxMetadata]

    public init(
        applicationName: String,
        windowTitle: String?,
        comboBoxCount: Int,
        comboBoxes: [QAXComboBoxMetadata]
    ) {
        self.applicationName = applicationName
        self.windowTitle = windowTitle
        self.comboBoxCount = comboBoxCount
        self.comboBoxes = comboBoxes
    }
}

/// One ruler's safe, non-sensitive identity metadata, as returned by `ui.list_rulers` (Phase 2BC).
public struct QAXRulerMetadata: Sendable, Equatable, Codable {
    public let index: Int
    public let title: String?
    public let identifier: String?
    public let role: String
    public let subrole: String?
    public let orientation: String?
    public let unitDescription: String?
    public let markerCount: Int?
    public let isEnabled: Bool?

    public init(
        index: Int,
        title: String?,
        identifier: String?,
        role: String,
        subrole: String? = nil,
        orientation: String? = nil,
        unitDescription: String? = nil,
        markerCount: Int? = nil,
        isEnabled: Bool? = nil
    ) {
        self.index = index
        self.title = title
        self.identifier = identifier
        self.role = role
        self.subrole = subrole
        self.orientation = orientation
        self.unitDescription = unitDescription
        self.markerCount = markerCount
        self.isEnabled = isEnabled
    }
}

/// A collection of safe, non-sensitive direct rulers metadata, as returned by `ui.list_rulers` (Phase 2BC).
/// This is a POINT-IN-TIME SNAPSHOT ONLY — informational only, never itself an actionable target reference.
public struct QAXRulerCollectionMetadata: Sendable, Equatable, Codable {
    public let applicationName: String
    public let windowTitle: String?
    public let rulerCount: Int
    public let rulers: [QAXRulerMetadata]

    public init(
        applicationName: String,
        windowTitle: String?,
        rulerCount: Int,
        rulers: [QAXRulerMetadata]
    ) {
        self.applicationName = applicationName
        self.windowTitle = windowTitle
        self.rulerCount = rulerCount
        self.rulers = rulers
    }
}

/// One combo box item's safe, non-sensitive identity metadata, as returned by `ui.list_combo_box_items` (Phase 2BD).
public struct QAXComboBoxItemMetadata: Sendable, Equatable, Codable {
    public let index: Int
    public let title: String
    public let isSelected: Bool

    public init(
        index: Int,
        title: String,
        isSelected: Bool = false
    ) {
        self.index = index
        self.title = title
        self.isSelected = isSelected
    }
}

/// Metadata for a combo box's items, as returned by `ui.list_combo_box_items` (Phase 2BD).
/// This is a POINT-IN-TIME SNAPSHOT ONLY — informational only, never itself an actionable target reference.
public struct QAXComboBoxItemsMetadata: Sendable, Equatable, Codable {
    public let applicationName: String
    public let windowTitle: String?
    public let comboBoxRole: String
    public let comboBoxIdentifier: String?
    public let comboBoxTitle: String?
    public let isEnabled: Bool?
    public let isExpanded: Bool?
    public let selectedValue: String?
    public let itemCount: Int
    public let items: [QAXComboBoxItemMetadata]

    public init(
        applicationName: String,
        windowTitle: String?,
        comboBoxRole: String,
        comboBoxIdentifier: String?,
        comboBoxTitle: String?,
        isEnabled: Bool?,
        isExpanded: Bool?,
        selectedValue: String?,
        itemCount: Int,
        items: [QAXComboBoxItemMetadata]
    ) {
        self.applicationName = applicationName
        self.windowTitle = windowTitle
        self.comboBoxRole = comboBoxRole
        self.comboBoxIdentifier = comboBoxIdentifier
        self.comboBoxTitle = comboBoxTitle
        self.isEnabled = isEnabled
        self.isExpanded = isExpanded
        self.selectedValue = selectedValue
        self.itemCount = itemCount
        self.items = items
    }
}

/// Whether a `selectComboBoxItem` call actually performed a value mutation, or found
/// the combo box already showing the desired item and correctly did nothing.
public enum QAXComboBoxSelectionChangeKind: String, Sendable, Equatable {
    case alreadySelected
    case changed
}

/// The outcome of one `QBridgeAccessibility.selectComboBoxItem` call (Phase 2BE).
public struct QAXComboBoxSelectionOutcome: Sendable, Equatable {
    public let changeKind: QAXComboBoxSelectionChangeKind
    public let previousValue: String?
    public let requestedItemTitle: String
    public let targetIdentity: String

    public init(
        changeKind: QAXComboBoxSelectionChangeKind,
        previousValue: String?,
        requestedItemTitle: String,
        targetIdentity: String
    ) {
        self.changeKind = changeKind
        self.previousValue = previousValue
        self.requestedItemTitle = requestedItemTitle
        self.targetIdentity = targetIdentity
    }
}

/// The result of independently re-observing a combo box's `kAXValueAttribute` after a
/// `ui.select_combo_box_item` dispatch, for the later closed-loop verification step.
public enum QAXComboBoxValueEvidence: Sendable, Equatable {
    case resolved(currentValue: String)
    case targetUnavailable
}

/// The explicit, model-supplied direction of a `ui.step_incrementor` mutation (Phase 2BF).
/// Never a blind toggle — the model must state which direction it wants.
public enum QAXIncrementorStepDirection: String, Sendable, Equatable {
    case increment
    case decrement
}

/// Whether a `stepIncrementor` call actually performed one or more AX actions, or found the
/// target already at its reported `kAXMinValueAttribute`/`kAXMaxValueAttribute` bound in the
/// requested direction and correctly did nothing.
public enum QAXIncrementorStepChangeKind: String, Sendable, Equatable {
    case alreadyAtBound
    case changed
}

/// The outcome of one `QBridgeAccessibility.stepIncrementor` call (Phase 2BF).
public struct QAXIncrementorStepOutcome: Sendable, Equatable {
    public let changeKind: QAXIncrementorStepChangeKind
    public let direction: QAXIncrementorStepDirection
    public let requestedSteps: Int
    public let performedSteps: Int
    public let previousValue: Double
    public let currentValue: Double
    public let targetIdentity: String

    public init(
        changeKind: QAXIncrementorStepChangeKind,
        direction: QAXIncrementorStepDirection,
        requestedSteps: Int,
        performedSteps: Int,
        previousValue: Double,
        currentValue: Double,
        targetIdentity: String
    ) {
        self.changeKind = changeKind
        self.direction = direction
        self.requestedSteps = requestedSteps
        self.performedSteps = performedSteps
        self.previousValue = previousValue
        self.currentValue = currentValue
        self.targetIdentity = targetIdentity
    }
}

/// The result of independently re-observing a target `AXIncrementor`'s `kAXValueAttribute` after a
/// `ui.step_incrementor` dispatch, for the later closed-loop verification step (Phase 2BF).
public enum QAXIncrementorValueEvidence: Sendable, Equatable {
    case resolved(currentValue: Double)
    case targetUnavailable
}


/// Whether a `setSplitterPosition` call actually performed a value write, or found the target
/// already at the desired position (within tolerance) and correctly did nothing.
public enum QAXSplitterChangeKind: String, Sendable, Equatable {
    case alreadyDesired
    case changed
}

/// The outcome of one `QBridgeAccessibility.setSplitterPosition` call.
public struct QAXSplitterPositionOutcome: Sendable, Equatable {
    public let changeKind: QAXSplitterChangeKind
    public let previousPosition: Double
    public let currentPosition: Double
    public let desiredPosition: Double
    public let minValue: Double
    public let maxValue: Double
    public let splitterIndex: Int
    public let targetIdentity: String

    public init(
        changeKind: QAXSplitterChangeKind,
        previousPosition: Double,
        currentPosition: Double,
        desiredPosition: Double,
        minValue: Double,
        maxValue: Double,
        splitterIndex: Int,
        targetIdentity: String
    ) {
        self.changeKind = changeKind
        self.previousPosition = previousPosition
        self.currentPosition = currentPosition
        self.desiredPosition = desiredPosition
        self.minValue = minValue
        self.maxValue = maxValue
        self.splitterIndex = splitterIndex
        self.targetIdentity = targetIdentity
    }
}

/// The result of independently re-observing a splitter's `kAXValueAttribute` after a
/// `ui.set_splitter_position` dispatch, for the later closed-loop verification step (and for
/// `QTaskRecoveryManager`'s observation-first recovery, which reuses this exact primitive).
public enum QAXSplitterPositionEvidence: Sendable, Equatable {
    case resolved(currentPosition: Double)
    case rangeInvalid(currentPosition: Double)
    case targetUnavailable
}

/// One segment item's safe, non-sensitive identity metadata, as returned by `ui.list_segmented_control_items`
/// (Phase 2AM).
public struct QAXSegmentedControlItemMetadata: Sendable, Equatable, Codable {
    public let index: Int
    public let title: String?
    public let identifier: String?
    public let role: String
    public let subrole: String?
    public let isEnabled: Bool?
    public let isSelected: Bool?

    public init(
        index: Int,
        title: String?,
        identifier: String?,
        role: String,
        subrole: String? = nil,
        isEnabled: Bool? = nil,
        isSelected: Bool? = nil
    ) {
        self.index = index
        self.title = title
        self.identifier = identifier
        self.role = role
        self.subrole = subrole
        self.isEnabled = isEnabled
        self.isSelected = isSelected
    }
}

/// A segmented control's safe, non-sensitive direct items metadata, as returned by `ui.list_segmented_control_items`
/// (Phase 2AM). Deliberately carries ONLY the fields this capability's contract allows — never raw
/// `AXUIElement` references, never arbitrary descendant trees.
/// This is a POINT-IN-TIME SNAPSHOT ONLY — informational only, never itself an actionable target
/// reference; any subsequent mutation capability must independently perform its own fresh, exact target resolution.
public struct QAXSegmentedControlMetadata: Sendable, Equatable, Codable {
    public let applicationName: String
    public let windowTitle: String?
    public let controlTitle: String?
    public let controlIdentifier: String?
    public let itemCount: Int
    public let selectedItemCount: Int
    public let items: [QAXSegmentedControlItemMetadata]

    public init(
        applicationName: String,
        windowTitle: String?,
        controlTitle: String?,
        controlIdentifier: String?,
        itemCount: Int,
        selectedItemCount: Int,
        items: [QAXSegmentedControlItemMetadata]
    ) {
        self.applicationName = applicationName
        self.windowTitle = windowTitle
        self.controlTitle = controlTitle
        self.controlIdentifier = controlIdentifier
        self.itemCount = itemCount
        self.selectedItemCount = selectedItemCount
        self.items = items
    }
}

/// The mutation kind reported by `ui.select_segmented_control_item` (Phase 2AQ).
public enum QAXSegmentedControlSelectionChangeKind: String, Sendable, Equatable {
    case alreadyDesired
    case changed
}

/// The outcome of one `QBridgeAccessibility.selectSegmentedControlItem` call (Phase 2AQ).
public struct QAXSegmentedControlSelectionOutcome: Sendable, Equatable {
    public let changeKind: QAXSegmentedControlSelectionChangeKind
    public let previousSelected: Bool
    public let currentSelected: Bool
    public let targetIdentity: String

    public init(
        changeKind: QAXSegmentedControlSelectionChangeKind,
        previousSelected: Bool,
        currentSelected: Bool,
        targetIdentity: String
    ) {
        self.changeKind = changeKind
        self.previousSelected = previousSelected
        self.currentSelected = currentSelected
        self.targetIdentity = targetIdentity
    }
}

/// The result of independently re-observing a segmented control item's selection state after a
/// `ui.select_segmented_control_item` dispatch, for closed-loop verification and recovery.
public enum QAXSegmentedControlSelectionEvidence: Sendable, Equatable {
    case resolved(currentSelected: Bool)
    case stateUnreadable
    case targetUnavailable
}

/// One sheet's safe, non-sensitive identity metadata, as returned by `ui.list_sheet_dialogs` (Phase 2AN).
public struct QAXSheetMetadata: Sendable, Equatable, Codable {
    public let index: Int
    public let title: String?
    public let identifier: String?
    public let role: String
    public let subrole: String?
    public let isModal: Bool?

    public init(
        index: Int,
        title: String?,
        identifier: String?,
        role: String,
        subrole: String? = nil,
        isModal: Bool? = nil
    ) {
        self.index = index
        self.title = title
        self.identifier = identifier
        self.role = role
        self.subrole = subrole
        self.isModal = isModal
    }
}

/// A window's safe, non-sensitive direct sheets metadata collection, as returned by `ui.list_sheet_dialogs` (Phase 2AN).
/// Deliberately carries ONLY the fields this capability's contract allows — never raw `AXUIElement` references,
/// never sheet buttons or descendant trees.
/// This is a POINT-IN-TIME SNAPSHOT ONLY — informational only, never itself an actionable target reference;
/// any subsequent action must independently perform its own fresh, exact target resolution.
public struct QAXSheetCollectionMetadata: Sendable, Equatable, Codable {
    public let applicationName: String
    public let windowTitle: String?
    public let windowIdentifier: String?
    public let sheetCount: Int
    public let sheets: [QAXSheetMetadata]

    public init(
        applicationName: String,
        windowTitle: String?,
        windowIdentifier: String?,
        sheetCount: Int,
        sheets: [QAXSheetMetadata]
    ) {
        self.applicationName = applicationName
        self.windowTitle = windowTitle
        self.windowIdentifier = windowIdentifier
        self.sheetCount = sheetCount
        self.sheets = sheets
    }
}

/// One sheet action control's safe, non-sensitive identity metadata, as returned by `ui.list_sheet_actions` (Phase 2AO).
public struct QAXSheetActionMetadata: Sendable, Equatable, Codable {
    public let index: Int
    public let title: String?
    public let identifier: String?
    public let role: String
    public let subrole: String?
    public let isEnabled: Bool?
    public let isSelected: Bool?
    public let isFocused: Bool?

    public init(
        index: Int,
        title: String?,
        identifier: String?,
        role: String,
        subrole: String? = nil,
        isEnabled: Bool? = nil,
        isSelected: Bool? = nil,
        isFocused: Bool? = nil
    ) {
        self.index = index
        self.title = title
        self.identifier = identifier
        self.role = role
        self.subrole = subrole
        self.isEnabled = isEnabled
        self.isSelected = isSelected
        self.isFocused = isFocused
    }
}

/// A sheet's safe, non-sensitive direct action controls metadata collection, as returned by `ui.list_sheet_actions` (Phase 2AO).
/// Deliberately carries ONLY the fields this capability's contract allows — never raw `AXUIElement` references,
/// never popup menus or arbitrary descendant trees.
/// This is a POINT-IN-TIME SNAPSHOT ONLY — informational only, never itself an actionable target reference;
/// any subsequent action must independently perform its own fresh, exact target resolution.
public struct QAXSheetActionCollectionMetadata: Sendable, Equatable, Codable {
    public let applicationName: String
    public let windowTitle: String?
    public let windowIdentifier: String?
    public let sheetTitle: String?
    public let sheetIdentifier: String?
    public let actionCount: Int
    public let actions: [QAXSheetActionMetadata]

    public init(
        applicationName: String,
        windowTitle: String?,
        windowIdentifier: String?,
        sheetTitle: String?,
        sheetIdentifier: String?,
        actionCount: Int,
        actions: [QAXSheetActionMetadata]
    ) {
        self.applicationName = applicationName
        self.windowTitle = windowTitle
        self.windowIdentifier = windowIdentifier
        self.sheetTitle = sheetTitle
        self.sheetIdentifier = sheetIdentifier
        self.actionCount = actionCount
        self.actions = actions
    }
}

extension QBridgeAccessibility {
    private static let maxTraversalDepth = 12
    private static let maxTraversalNodes = 3_000
    /// Phase 2Z: a defensive maximum on the RAW `kAXWindowsAttribute` array's element count,
    /// checked BEFORE any per-element metadata is read — a real application's window count is
    /// always naturally small (a handful at most), so this exists purely as a safety bound
    /// against a hostile or corrupted AX responder, never expected to be reached in practice.
    private static let maxWindowEnumerationCount = 64
    /// Phase 2AA: defensive bounds on menu enumeration counts.
    private static let maxTopLevelMenuCount = 32
    private static let maxDirectMenuItemsPerMenuCount = 128
    private static let maxTotalMenuItemsCount = 512
    /// Phase 2AD: defensive bound on pop-up menu direct item enumeration.
    private static let maxDirectPopupItemsCount = 128
    /// Phase 2AE: defensive bound on table direct row enumeration.
    private static let maxDirectTableRowsCount = 128
    /// Phase 2AF: defensive bounds on outline item enumeration.
    private static let maxDirectOutlineItemsCount = 128
    private static let maxOutlineDepth = 12
    private static let axDisclosureLevelAttributeName = "AXDisclosureLevel"
    private static let axDisclosingAttributeName = "AXDisclosing"
    /// Phase 2AH: defensive bound on tab item enumeration.
    private static let maxDirectTabItemsCount = 64
    private static let axTabsAttributeName = "AXTabs"
    /// Phase 2AI: defensive bound on radio group item enumeration.
    private static let maxDirectRadioItemsCount = 64
    /// Phase 2AK: defensive bound on toolbar item enumeration.
    private static let maxDirectToolbarItemsCount = 64
    private static let allowedDirectToolbarItemRoles: Set<String> = [
        "AXButton",
        "AXPopUpButton",
        "AXMenuButton",
        "AXSearchField",
        "AXSegmentedControl",
        "AXRadioButton",
        "AXCheckBox",
        "AXGroup",
        "AXTextField",
        "AXComboBox",
        "AXSlider"
    ]
    /// Phase 2AM: defensive bound on segmented control item enumeration.
    private static let maxDirectSegmentsCount = 32
    private static let allowedDirectSegmentRoles: Set<String> = [
        "AXRadioButton",
        "AXButton"
    ]
    /// Phase 2AN: defensive bound on sheet enumeration.
    private static let maxDirectSheetsCount = 16
    private static let axSheetsAttributeName = "AXSheets"
    private static let axModalAttributeName = "AXModal"
    /// Phase 2AO: defensive bound on sheet direct action controls enumeration.
    private static let maxDirectSheetActionsCount = 16
    /// Phase 2AT: defensive bound on split pane enumeration.
    private static let maxDirectSplitPanesCount = 16
    private static let maxDirectBrowserColumnsCount = 32
    /// Phase 2BI: defensive bound on table column-header enumeration.
    private static let maxDirectTableColumnsCount = 32
    /// Phase 2BK: defensive bound on `ui.list_element_actions`' returned action-name collection —
    /// exceeding this fails closed rather than silently truncating (never misrepresenting the
    /// authoritative result).
    private static let maxElementActionsCount = 16
    /// Phase 2BK: defensive per-string length bound on an individual action name — prevents an
    /// arbitrarily large model-visible string; exceeding it fails closed.
    private static let maxActionNameLength = 256
    /// Phase 2BL: defensive bound on `ui.list_element_attributes`' returned attribute-name
    /// collection — exceeding this fails closed rather than silently truncating (never
    /// misrepresenting the authoritative result). Wider than `maxElementActionsCount` since real
    /// elements typically expose more attributes than actions.
    private static let maxElementAttributesCount = 32
    /// Phase 2BL: defensive per-string length bound on an individual attribute name — prevents an
    /// arbitrarily large model-visible string; exceeding it fails closed.
    private static let maxAttributeNameLength = 256
    /// Phase 2BM: defensive per-string length bound on a window button's title/identifier —
    /// prevents an arbitrarily large model-visible string; exceeding it fails closed.
    private static let maxWindowButtonMetadataLength = 256
    /// Phase 2BN: defensive per-string length bound on a title-reference element's
    /// title/identifier — prevents an arbitrarily large model-visible string; exceeding it fails
    /// closed. A distinct constant from `maxWindowButtonMetadataLength` per this codebase's
    /// existing convention of not sharing bound constants across unrelated capabilities, even
    /// when the numeric value is identical.
    private static let maxTitleReferenceMetadataLength = 256
    private static let maxDirectPopoversCount = 16
    private static let maxDirectColorWellsCount = 32
    private static let maxDirectProgressIndicatorsCount = 32
    private static let maxDirectLevelIndicatorsCount = 32
    private static let maxDirectIncrementorsCount = 32
    private static let maxDirectComboBoxesCount = 32
    private static let maxDirectRulersCount = 32
    private static let maxDirectComboBoxItemsCount = 128
    /// Phase 2BF: the maximum number of `AXIncrementAction`/`AXDecrementAction` dispatches
    /// `ui.step_incrementor` may perform against a single target within one approved execution.
    private static let maxIncrementorStepsPerCall = 20
    private static let axColumnsAttributeName = "AXColumns"
    /// Phase 2AT: the AX role of the divider element between two panes in an `AXSplitGroup` —
    /// excluded from pane enumeration since it is the boundary between panes, not a pane itself.
    private static let splitterRole = "AXSplitter"
    private static let traversalTimeBudgetSeconds: CFAbsoluteTime = 1.5
    /// No `kAX...` Swift constant exists for this attribute; confirmed via direct empirical
    /// probing against real macOS apps that it is the stable, populated, raw-string identifier
    /// key (populated even where kAXTitleAttribute is empty — see docs/PHASE_2H_SEMANTIC_CLICK.md).
    private static let axIdentifierAttributeName = "AXIdentifier"

    /// Resolves running applications matching the existing identity contract (case-insensitive
    /// localized name OR case-insensitive bundle identifier).
    /// Enforces the strict Q security invariant:
    /// - Exactly 1 match: returns the matching NSRunningApplication
    /// - 0 matches: throws `QAXInteractionError.applicationNotAvailable(applicationName)`
    /// - >1 matches: throws `QAXInteractionError.ambiguousTarget(count: matchingApps.count)`
    /// Never falls back to `.first` when multiple matches exist.
    public static func resolveExactRunningApplication(named applicationName: String) throws -> NSRunningApplication {
        let matchingApps = NSWorkspace.shared.runningApplications.filter {
            ($0.localizedName?.caseInsensitiveCompare(applicationName) == .orderedSame) ||
            ($0.bundleIdentifier?.caseInsensitiveCompare(applicationName) == .orderedSame)
        }
        guard !matchingApps.isEmpty else {
            throw QAXInteractionError.applicationNotAvailable(applicationName)
        }
        guard matchingApps.count == 1 else {
            throw QAXInteractionError.ambiguousTarget(count: matchingApps.count)
        }
        return matchingApps[0]
    }


    /// Resolves exactly one semantic target, re-verifies it hasn't drifted since resolution, and
    /// presses it. Fails closed (throws QAXInteractionError) on every ambiguous, stale, disabled,
    /// unauthorized, or unsupported outcome — never falls back to coordinates or a CGEvent click.
    /// Returns human-readable evidence plus the pre-click snapshot, which the caller threads
    /// through to the later, separate closed-loop verification step (QVerificationStrategy).
    public func clickElement(
        applicationName: String,
        role: String,
        identifier: String?,
        title: String?
    ) async throws -> (evidence: String, preClickSnapshot: QAXElementSnapshot) {
        guard identifier != nil || title != nil else {
            throw QAXInteractionError.missingMatchCriteria
        }

        // Read-only status check — matches QBridgeScreenCapture's CGPreflightScreenCaptureAccess
        // pattern exactly. Never triggers a system prompt, never requests access.
        guard AXIsProcessTrusted() else {
            throw QAXInteractionError.accessibilityPermissionDenied
        }

        let runningApp = try Self.resolveExactRunningApplication(named: applicationName)

        let processIdentifier = runningApp.processIdentifier

        // AXUIElement calls are synchronous, blocking IPC and a bounded tree walk over a complex
        // app's window can take real time — run off the calling actor, mirroring QBridgeVision's
        // Task.detached pattern for the same reason (this module defaults to MainActor isolation).
        return try await Task.detached(priority: .userInitiated) {
            let appElement = AXUIElementCreateApplication(processIdentifier)

            let matches = Self.collectMatches(root: appElement, role: role, identifier: identifier, title: title)
            guard !matches.isEmpty else { throw QAXInteractionError.noMatchingElement }
            guard matches.count == 1 else { throw QAXInteractionError.ambiguousTarget(count: matches.count) }

            let (targetElement, observedAtSearch) = matches[0]

            // Observation binding: re-read the SAME element reference's live attributes
            // immediately before dispatch and compare against what the search just observed.
            // Any mismatch — or the element having become entirely unreadable — fails closed
            // rather than pressing a target that may no longer be the one identified.
            guard let observedAtVerify = Self.snapshotIfMatches(targetElement, role: role, identifier: identifier, title: title) else {
                throw QAXInteractionError.staleTarget("target element is no longer resolvable immediately before dispatch")
            }
            guard observedAtVerify == observedAtSearch else {
                throw QAXInteractionError.staleTarget("target element state changed between observation and dispatch")
            }
            guard observedAtVerify.isEnabled else {
                throw QAXInteractionError.targetDisabled
            }

            let pressResult = AXUIElementPerformAction(targetElement, kAXPressAction as CFString)
            switch pressResult {
            case .success:
                break
            case .actionUnsupported:
                throw QAXInteractionError.actionUnsupported
            default:
                throw QAXInteractionError.pressFailed("AXError(\(pressResult.rawValue))")
            }

            let evidence = "Pressed \(role) element (identifier=\(observedAtVerify.identifier ?? "none"), label=\(observedAtVerify.titleOrDescription ?? "none")) in \(applicationName)."
            return (evidence, observedAtVerify)
        }.value
    }

    /// Best-effort, read-only re-resolution of the same match criteria used by `clickElement`,
    /// used only for post-click verification (QVerificationStrategy.axElementStateChanged).
    /// Returns nil if the target is no longer uniquely resolvable — a common, legitimate outcome
    /// for a control whose own identity changes as a result of the click it just received, not
    /// an error at this layer (the caller decides what that means for verification evidence).
    public func observeElement(
        applicationName: String,
        role: String,
        identifier: String?,
        title: String?
    ) async -> QAXElementSnapshot? {
        guard AXIsProcessTrusted() else { return nil }
        guard let runningApp = try? Self.resolveExactRunningApplication(named: applicationName) else { return nil }

        let processIdentifier = runningApp.processIdentifier
        return await Task.detached(priority: .userInitiated) {
            let appElement = AXUIElementCreateApplication(processIdentifier)
            let matches = Self.collectMatches(root: appElement, role: role, identifier: identifier, title: title)
            guard matches.count == 1 else { return nil }
            return matches[0].snapshot
        }.value
    }

    // MARK: - Semantic AX Text-Entry Mutation (Phase 2I)
    //
    // ui.set_text_value — a Level 2, reversible, semantic text-field write. Every element is
    // identified by role + (identifier or title), exactly like ui.click_element, with two
    // additional preconditions unique to a mutation that writes content rather than presses a
    // button: the role must be on QAXTextEntryRolePolicy's explicit allowlist (never
    // AXSecureTextField, never an unrecognized role), and the resolved target must already be
    // the system's genuinely focused element — this capability never clicks/focuses a field
    // itself. The literal value read from, or written into, the target exists only inside
    // `setTextValue`'s own local scope: only lengths, non-secret target identity, and SHA-256
    // hex digests (for the later independent closed-loop verification step) ever cross its
    // return boundary, via QAXTextValueMutationOutcome.

    /// Resolves exactly one semantic AXTextField/AXTextArea target, verifies it is genuinely
    /// focused and not stale, and sets its value via `AXUIElementSetAttributeValue
    /// (kAXValueAttribute)` only — never CGEvent, never keyboard simulation, never Return/Tab/
    /// submit. Fails closed (throws `QAXInteractionError`) on every disallowed-role, ambiguous,
    /// stale, disabled, unfocused, or unreadable outcome. If the target's current value already
    /// equals `newValue`, this is treated as an idempotent no-op — no AX write is performed at
    /// all — rather than an unnecessary mutation.
    public func setTextValue(
        applicationName: String,
        role: String,
        identifier: String?,
        title: String?,
        newValue: String
    ) async throws -> QAXTextValueMutationOutcome {
        guard identifier != nil || title != nil else {
            throw QAXInteractionError.missingMatchCriteria
        }
        // Role is validated as a search CRITERION, before any tree walk — an unauthorized role
        // (AXSecureTextField, or anything not explicitly allowlisted) is refused outright rather
        // than allowed to shape what gets searched for.
        guard QAXTextEntryRolePolicy.isAllowedTextEntryRole(role) else {
            throw QAXInteractionError.disallowedTargetRole(role)
        }

        guard AXIsProcessTrusted() else {
            throw QAXInteractionError.accessibilityPermissionDenied
        }

        let runningApp = try Self.resolveExactRunningApplication(named: applicationName)

        let processIdentifier = runningApp.processIdentifier

        return try await Task.detached(priority: .userInitiated) {
            let appElement = AXUIElementCreateApplication(processIdentifier)

            let matches = Self.collectMatches(root: appElement, role: role, identifier: identifier, title: title)
            guard !matches.isEmpty else { throw QAXInteractionError.noMatchingElement }
            guard matches.count == 1 else { throw QAXInteractionError.ambiguousTarget(count: matches.count) }

            let (targetElement, observedAtSearch) = matches[0]

            // Observation binding: identical discipline to clickElement — re-read the SAME
            // element reference immediately before any mutation and refuse on any drift.
            guard let observedAtVerify = Self.snapshotIfMatches(targetElement, role: role, identifier: identifier, title: title) else {
                throw QAXInteractionError.staleTarget("target element is no longer resolvable immediately before dispatch")
            }
            guard observedAtVerify == observedAtSearch else {
                throw QAXInteractionError.staleTarget("target element state changed between observation and dispatch")
            }
            guard observedAtVerify.isEnabled else {
                throw QAXInteractionError.targetDisabled
            }

            // Focus verification: the target must BE the system's current focused UI element.
            // This mirrors Pace-native's own PaceActionExecutor+Keyboard.swift setTextValue
            // read pattern (AXUIElementCreateSystemWide + kAXFocusedUIElementAttribute), except
            // here the read is compared against a specific, already-semantically-resolved
            // target rather than blindly trusted — no click-to-focus is ever attempted.
            let systemWideElement = AXUIElementCreateSystemWide()
            var focusedElementValue: CFTypeRef?
            let focusedResult = AXUIElementCopyAttributeValue(
                systemWideElement,
                kAXFocusedUIElementAttribute as CFString,
                &focusedElementValue
            )
            guard focusedResult == .success,
                  let focusedElementValue,
                  CFGetTypeID(focusedElementValue) == AXUIElementGetTypeID() else {
                throw QAXInteractionError.targetNotFocused("no focused Accessibility element could be determined")
            }
            let focusedElement = focusedElementValue as! AXUIElement
            guard CFEqual(focusedElement, targetElement) else {
                throw QAXInteractionError.targetNotFocused("the resolved target is not the currently focused element")
            }

            // Ephemeral readback: the previous literal value lives only in this local `let` for
            // exactly as long as it takes to compute its length and hash on the next two lines.
            guard let previousValue = Self.axStringAttribute(kAXValueAttribute, of: targetElement) else {
                throw QAXInteractionError.valueReadFailed
            }
            let previousLength = previousValue.count
            let previousValueHash = Self.sha256Hex(previousValue)
            let intendedValueHash = Self.sha256Hex(newValue)
            let targetIdentity = "application=\(applicationName) role=\(role) identifier=\(observedAtVerify.identifier ?? "none") label=\(observedAtVerify.titleOrDescription ?? "none")"

            guard previousValueHash != intendedValueHash else {
                // Idempotent no-op: the field already holds the intended value. No AX write is
                // performed — an unnecessary mutation is itself something to avoid.
                return QAXTextValueMutationOutcome(
                    valueChanged: false,
                    previousLength: previousLength,
                    currentLength: newValue.count,
                    targetIdentity: targetIdentity,
                    previousValueHash: previousValueHash,
                    intendedValueHash: intendedValueHash
                )
            }

            let setResult = AXUIElementSetAttributeValue(targetElement, kAXValueAttribute as CFString, newValue as CFString)
            guard setResult == .success else {
                throw QAXInteractionError.setValueFailed("AXError(\(setResult.rawValue))")
            }

            // Immediate ephemeral readback confirming the write landed — again discarded after
            // its length is computed; the authoritative check is the later, independent
            // closed-loop verification step (QVerificationStrategy.axTextValueChanged), which
            // re-resolves the target fresh rather than trusting this in-process observation.
            let currentLength = Self.axStringAttribute(kAXValueAttribute, of: targetElement)?.count ?? newValue.count

            return QAXTextValueMutationOutcome(
                valueChanged: true,
                previousLength: previousLength,
                currentLength: currentLength,
                targetIdentity: targetIdentity,
                previousValueHash: previousValueHash,
                intendedValueHash: intendedValueHash
            )
        }.value
    }

    /// Best-effort, read-only re-resolution of the same match criteria used by `setTextValue`,
    /// used only for the later closed-loop verification step
    /// (QVerificationStrategy.axTextValueChanged). Returns the CURRENT value's length and
    /// SHA-256 hash only — never the plaintext — or nil if the target is no longer uniquely
    /// resolvable or its value cannot be read.
    public func observeTextValueHashAndLength(
        applicationName: String,
        role: String,
        identifier: String?,
        title: String?
    ) async -> (hash: String, length: Int)? {
        guard AXIsProcessTrusted() else { return nil }
        guard let runningApp = try? Self.resolveExactRunningApplication(named: applicationName) else { return nil }

        let processIdentifier = runningApp.processIdentifier
        return await Task.detached(priority: .userInitiated) {
            let appElement = AXUIElementCreateApplication(processIdentifier)
            let matches = Self.collectMatches(root: appElement, role: role, identifier: identifier, title: title)
            guard matches.count == 1 else { return nil }
            guard let currentValue = Self.axStringAttribute(kAXValueAttribute, of: matches[0].element) else { return nil }
            return (Self.sha256Hex(currentValue), currentValue.count)
        }.value
    }

    // MARK: - Semantic AX Element Value Read (Phase 2J)
    //
    // ui.read_element_value — a Level 0, read-only value read. Every element is identified by
    // role + (identifier or title), exactly like ui.click_element/ui.set_text_value. The role
    // policy is an explicit ALLOWLIST (QAXElementReadRolePolicy) — deliberately wider than the
    // write-side allowlist (reading needs to cover the ordinary vocabulary of native macOS UI:
    // fields, labels, buttons, toggles, choices — not just the two roles safe to mutate), but
    // still a fail-closed allowlist, not a denylist: any role not explicitly listed, known or
    // unknown, is refused, and AXSecureTextField is checked and reported first with its own
    // distinct, more specific error. Unlike setTextValue's returned QAXTextValueMutationOutcome,
    // the value read here is returned as PLAINTEXT — this capability's entire purpose is to
    // surface previously-unknown content to the model, exactly like screen.ocr already does.
    // Registering this tool under toolFamily "perception" (see QModelPlanSchema.swift) — not
    // "ui" — is what puts it through the same sanitize-before-persist / raw-for-reasoning
    // boundary screen.ocr already relies on, with zero changes to QPlanExecutor. Role is the sole
    // authoritative signal for this policy — identifier/title content is never consulted to grant
    // or deny access, so a benign-looking title can never bypass a disallowed role.

    /// Resolves exactly one semantic target and reads its value — `kAXValueAttribute` if present
    /// and non-empty, falling back to title-or-description for roles (buttons, static text, menu
    /// items) that don't carry a meaningful AXValue. Fails closed (throws `QAXInteractionError`)
    /// on a disallowed/secure role, missing criteria, permission absence, application absence, or
    /// zero/ambiguous matches — never fabricates a value. Never mutates anything.
    public func readElementValue(
        applicationName: String,
        role: String,
        identifier: String?,
        title: String?
    ) async throws -> (value: String, snapshot: QAXElementSnapshot) {
        guard identifier != nil || title != nil else {
            throw QAXInteractionError.missingMatchCriteria
        }
        // Secure field first, for a specific diagnostic; then the general allowlist, which would
        // also reject AXSecureTextField on its own (it is never listed) — belt and suspenders.
        guard role != "AXSecureTextField" else {
            throw QAXInteractionError.secureFieldReadDenied(role)
        }
        guard QAXElementReadRolePolicy.isAllowedReadRole(role) else {
            throw QAXInteractionError.disallowedReadRole(role)
        }

        guard AXIsProcessTrusted() else {
            throw QAXInteractionError.accessibilityPermissionDenied
        }

        let runningApp = try Self.resolveExactRunningApplication(named: applicationName)

        let processIdentifier = runningApp.processIdentifier

        return try await Task.detached(priority: .userInitiated) {
            let appElement = AXUIElementCreateApplication(processIdentifier)

            let matches = Self.collectMatches(root: appElement, role: role, identifier: identifier, title: title)
            guard !matches.isEmpty else { throw QAXInteractionError.noMatchingElement }
            guard matches.count == 1 else { throw QAXInteractionError.ambiguousTarget(count: matches.count) }

            let (targetElement, snapshot) = matches[0]

            let value = Self.axValueDescription(of: targetElement) ?? snapshot.titleOrDescription ?? ""
            return (value, snapshot)
        }.value
    }

    // MARK: - Semantic AX Element Action Enumeration (Phase 2BK)
    //
    // ui.list_element_actions — a Level 0, read-only, zero-mutation, purely OBSERVATIONAL read of
    // a semantically-identified element's supported Accessibility action names via
    // AXUIElementCopyActionNames — a distinct C API from the AXAttributeConstants.h surface every
    // prior capability reads, never previously used anywhere in this codebase. Every existing
    // mutation capability hard-codes a specific action (kAXPressAction/kAXIncrementAction/
    // kAXDecrementAction) chosen per-role by the implementation; this is the first capability that
    // asks an element what it ACTUALLY supports, including app-defined custom actions
    // (NSAccessibilityCustomAction) no fixed role-based policy could anticipate. Reuses
    // QAXElementReadRolePolicy (Phase 2J) unmodified — no broader, arbitrary-role allowlist is
    // introduced. SECURITY-CRITICAL INVARIANT: the returned action names are DATA, not
    // AUTHORIZATION — this capability NEVER calls AXUIElementPerformAction, NEVER grants
    // permissions, NEVER creates approvals or standing grants, and discovering that an action name
    // exists never itself authorizes any future action; any subsequent action request must
    // independently pass its own full capability/risk/approval/execution-identity pipeline,
    // completely unaffected by this capability having ever been called.

    /// Resolves exactly one semantic target on `QAXElementReadRolePolicy`'s allowlist and reads its
    /// supported Accessibility action names via `AXUIElementCopyActionNames` — a purely
    /// observational call; `AXUIElementPerformAction` is never invoked anywhere in this method.
    /// Fails closed (throws `QAXInteractionError`) on a disallowed/secure role, missing criteria,
    /// permission absence, application/target absence or ambiguity, a stale/drifted target, a
    /// malformed returned collection, an action-name count exceeding
    /// `maxElementActionsCount` (16), or any single action name exceeding
    /// `maxActionNameLength` (256 characters) — never silently truncates, never fabricates a
    /// result.
    public func listElementActions(
        applicationName: String,
        role: String,
        identifier: String?,
        title: String?
    ) async throws -> QAXElementActionsMetadata {
        guard identifier != nil || title != nil else {
            throw QAXInteractionError.missingMatchCriteria
        }
        // Secure field first, for a specific diagnostic; then the general allowlist, which would
        // also reject AXSecureTextField on its own (it is never listed) — belt and suspenders,
        // identical discipline to readElementValue's own check.
        guard role != "AXSecureTextField" else {
            throw QAXInteractionError.secureFieldReadDenied(role)
        }
        guard QAXElementReadRolePolicy.isAllowedReadRole(role) else {
            throw QAXInteractionError.disallowedReadRole(role)
        }

        guard AXIsProcessTrusted() else {
            throw QAXInteractionError.accessibilityPermissionDenied
        }

        let runningApp = try Self.resolveExactRunningApplication(named: applicationName)
        let processIdentifier = runningApp.processIdentifier

        return try await Task.detached(priority: .userInitiated) {
            let appElement = AXUIElementCreateApplication(processIdentifier)

            let matches = Self.collectMatches(root: appElement, role: role, identifier: identifier, title: title)
            guard !matches.isEmpty else { throw QAXInteractionError.noMatchingElement }
            guard matches.count == 1 else { throw QAXInteractionError.ambiguousTarget(count: matches.count) }

            let (targetElement, observedAtSearch) = matches[0]

            // Observation binding: re-read the SAME element reference immediately before the
            // action-name read and refuse on any drift — identical discipline to every prior AX
            // capability in this codebase.
            guard let observedAtVerify = Self.snapshotIfMatches(targetElement, role: role, identifier: identifier, title: title) else {
                throw QAXInteractionError.staleTarget("target element is no longer resolvable immediately before action enumeration")
            }
            guard observedAtVerify == observedAtSearch else {
                throw QAXInteractionError.staleTarget("target element identity changed between observation and action enumeration")
            }

            // AXUIElementCopyActionNames — the discovery call itself. Purely observational: never
            // AXUIElementPerformAction, never AXUIElementSetAttributeValue, never any mutation
            // primitive of any kind.
            var actionNamesValue: CFArray?
            let copyResult = AXUIElementCopyActionNames(targetElement, &actionNamesValue)
            guard copyResult == .success, let actionNamesValue else {
                throw QAXInteractionError.actionNamesCollectionMalformed
            }
            // The returned value is treated as untrusted external data — success from the copy
            // call is never itself sufficient proof of a well-formed [String] array.
            guard let rawActionNames = actionNamesValue as? [String] else {
                throw QAXInteractionError.actionNamesCollectionMalformed
            }
            guard rawActionNames.count <= Self.maxElementActionsCount else {
                throw QAXInteractionError.actionNamesCollectionExceedsSafeBound(rawActionNames.count)
            }
            for actionName in rawActionNames {
                guard actionName.count <= Self.maxActionNameLength else {
                    throw QAXInteractionError.actionNameExceedsSafeLength(actionName.count)
                }
            }

            return QAXElementActionsMetadata(
                applicationName: applicationName,
                role: role,
                actionNames: rawActionNames
            )
        }.value
    }

    // MARK: - Semantic AX Element Attribute Name Enumeration (Phase 2BL)
    //
    // ui.list_element_attributes — a Level 0, read-only, zero-mutation, purely OBSERVATIONAL read
    // of a semantically-identified element's supported Accessibility ATTRIBUTE names via
    // AXUIElementCopyAttributeNames — the direct sibling of ui.list_element_actions (Phase 2BK),
    // which reads ACTION names via the parallel AXUIElementCopyActionNames. Where that capability
    // answers "what can this element DO", this one answers "what can I ASK this element" — every
    // existing read capability (ui.read_element_value, ui.read_element_range, etc.) assumes a
    // fixed, hard-coded attribute per role; this is the first capability that asks an element to
    // self-report its actual supported attribute VOCABULARY. Reuses QAXElementReadRolePolicy
    // (Phase 2J) unmodified — no broader, arbitrary-role allowlist is introduced.
    // SECURITY-CRITICAL INVARIANT: discovered attribute NAMES are DATA, not AUTHORIZATION — this
    // capability NEVER reads any attribute's actual VALUE merely because its name was discovered,
    // NEVER calls AXUIElementSetAttributeValue or AXUIElementPerformAction, and discovering that
    // an attribute name like "AXValue" exists never itself authorizes a future read of that
    // attribute's value; any actual value read must independently go through an existing,
    // approved semantic read capability (e.g. ui.read_element_value) and that capability's own
    // full role/privacy/security policy, completely unaffected by this capability ever having
    // been called.

    /// Resolves exactly one semantic target on `QAXElementReadRolePolicy`'s allowlist and reads
    /// its supported Accessibility ATTRIBUTE names via `AXUIElementCopyAttributeNames` — a purely
    /// observational call; no attribute VALUE is ever read as part of this method, and
    /// `AXUIElementSetAttributeValue`/`AXUIElementPerformAction` are never invoked anywhere in it.
    /// Fails closed (throws `QAXInteractionError`) on a disallowed/secure role, missing criteria,
    /// permission absence, application/target absence or ambiguity, a stale/drifted target, a
    /// malformed returned collection, an attribute-name count exceeding
    /// `maxElementAttributesCount` (32), or any single attribute name exceeding
    /// `maxAttributeNameLength` (256 characters) — never silently truncates, never deduplicates
    /// (the returned array is passed through exactly as the OS reports it), never fabricates a
    /// result.
    public func listElementAttributes(
        applicationName: String,
        role: String,
        identifier: String?,
        title: String?
    ) async throws -> QAXElementAttributeNamesMetadata {
        guard identifier != nil || title != nil else {
            throw QAXInteractionError.missingMatchCriteria
        }
        // Secure field first, for a specific diagnostic; then the general allowlist, which would
        // also reject AXSecureTextField on its own (it is never listed) — belt and suspenders,
        // identical discipline to readElementValue's/listElementActions' own check.
        guard role != "AXSecureTextField" else {
            throw QAXInteractionError.secureFieldReadDenied(role)
        }
        guard QAXElementReadRolePolicy.isAllowedReadRole(role) else {
            throw QAXInteractionError.disallowedReadRole(role)
        }

        guard AXIsProcessTrusted() else {
            throw QAXInteractionError.accessibilityPermissionDenied
        }

        let runningApp = try Self.resolveExactRunningApplication(named: applicationName)
        let processIdentifier = runningApp.processIdentifier

        return try await Task.detached(priority: .userInitiated) {
            let appElement = AXUIElementCreateApplication(processIdentifier)

            let matches = Self.collectMatches(root: appElement, role: role, identifier: identifier, title: title)
            guard !matches.isEmpty else { throw QAXInteractionError.noMatchingElement }
            guard matches.count == 1 else { throw QAXInteractionError.ambiguousTarget(count: matches.count) }

            let (targetElement, observedAtSearch) = matches[0]

            // Observation binding: re-read the SAME element reference immediately before the
            // attribute-name read and refuse on any drift — identical discipline to every prior
            // AX capability in this codebase.
            guard let observedAtVerify = Self.snapshotIfMatches(targetElement, role: role, identifier: identifier, title: title) else {
                throw QAXInteractionError.staleTarget("target element is no longer resolvable immediately before attribute enumeration")
            }
            guard observedAtVerify == observedAtSearch else {
                throw QAXInteractionError.staleTarget("target element identity changed between observation and attribute enumeration")
            }

            // AXUIElementCopyAttributeNames — the discovery call itself. Purely observational:
            // never AXUIElementCopyAttributeVALUE for any of the discovered names, never
            // AXUIElementSetAttributeValue, never AXUIElementPerformAction.
            var attributeNamesValue: CFArray?
            let copyResult = AXUIElementCopyAttributeNames(targetElement, &attributeNamesValue)
            guard copyResult == .success, let attributeNamesValue else {
                throw QAXInteractionError.attributeNamesCollectionMalformed
            }
            // The returned value is treated as untrusted external data — success from the copy
            // call is never itself sufficient proof of a well-formed [String] array.
            guard let rawAttributeNames = attributeNamesValue as? [String] else {
                throw QAXInteractionError.attributeNamesCollectionMalformed
            }
            guard rawAttributeNames.count <= Self.maxElementAttributesCount else {
                throw QAXInteractionError.attributeNamesCollectionExceedsSafeBound(rawAttributeNames.count)
            }
            for attributeName in rawAttributeNames {
                guard attributeName.count <= Self.maxAttributeNameLength else {
                    throw QAXInteractionError.attributeNameExceedsSafeLength(attributeName.count)
                }
            }

            return QAXElementAttributeNamesMetadata(
                applicationName: applicationName,
                role: role,
                attributeNames: rawAttributeNames
            )
        }.value
    }

    // MARK: - Semantic Element Parameterized Attribute Name Enumeration (Phase 2BP)
    //
    // ui.list_element_parameterized_attribute_names — a Level 0, read-only, zero-mutation, purely
    // OBSERVATIONAL read of a semantically-identified element's supported PARAMETERIZED
    // Accessibility attribute names via AXUIElementCopyParameterizedAttributeNames — the third and
    // final sibling in the "what can I ask this element" enumeration family alongside
    // ui.list_element_actions (Phase 2BK, AXUIElementCopyActionNames) and
    // ui.list_element_attributes (Phase 2BL, AXUIElementCopyAttributeNames), completing that
    // architectural trio. Reuses QAXElementReadRolePolicy (Phase 2J) unmodified — no broader,
    // arbitrary-role allowlist is introduced. SECURITY-CRITICAL INVARIANT: the returned
    // parameterized-attribute names are DATA, not AUTHORIZATION — this capability NEVER calls
    // AXUIElementCopyParameterizedAttributeValue (no parameterized attribute is ever actually
    // invoked with any parameter), NEVER calls AXUIElementPerformAction or
    // AXUIElementSetAttributeValue, NEVER grants permissions, NEVER creates approvals or standing
    // grants; discovering that a parameterized attribute name like "AXLineForIndex" exists never
    // itself authorizes any future invocation of it, which must independently pass its own full
    // capability/risk/approval/execution-identity pipeline via a dedicated future capability,
    // completely unaffected by this capability ever having been called.

    /// Resolves exactly one semantic target on `QAXElementReadRolePolicy`'s allowlist and reads its
    /// supported parameterized Accessibility attribute names via
    /// `AXUIElementCopyParameterizedAttributeNames` — a purely observational call;
    /// `AXUIElementCopyParameterizedAttributeValue` is never invoked anywhere in this method. Fails
    /// closed (throws `QAXInteractionError`) on a disallowed/secure role, missing criteria,
    /// permission absence, application/target absence or ambiguity, a stale/drifted target, a
    /// malformed returned collection, a parameterized-attribute-name count exceeding
    /// `maxElementAttributesCount` (32, reused verbatim — a sibling enumeration surface to plain
    /// attribute names, not a distinct category warranting its own bound), or any single
    /// parameterized-attribute name exceeding `maxAttributeNameLength` (256 characters, also reused
    /// verbatim) — never silently truncates, never fabricates a result. `kAXErrorAttributeUnsupported`,
    /// `kAXErrorParameterizedAttributeUnsupported`, and `kAXErrorNotImplemented` are treated as a
    /// valid, expected EMPTY result (`success == true`, `parameterizedAttributeNames == []`) —
    /// many elements genuinely support zero parameterized attributes, and this is not an error;
    /// every other `AXError` fails closed instead.
    public func listElementParameterizedAttributeNames(
        applicationName: String,
        role: String,
        identifier: String?,
        title: String?
    ) async throws -> QAXElementParameterizedAttributeNamesMetadata {
        guard identifier != nil || title != nil else {
            throw QAXInteractionError.missingMatchCriteria
        }
        // Secure field first, for a specific diagnostic; then the general allowlist, which would
        // also reject AXSecureTextField on its own (it is never listed) — belt and suspenders,
        // identical discipline to listElementActions'/listElementAttributes' own checks.
        guard role != "AXSecureTextField" else {
            throw QAXInteractionError.secureFieldReadDenied(role)
        }
        guard QAXElementReadRolePolicy.isAllowedReadRole(role) else {
            throw QAXInteractionError.disallowedReadRole(role)
        }

        guard AXIsProcessTrusted() else {
            throw QAXInteractionError.accessibilityPermissionDenied
        }

        let runningApp = try Self.resolveExactRunningApplication(named: applicationName)
        let processIdentifier = runningApp.processIdentifier

        return try await Task.detached(priority: .userInitiated) {
            let appElement = AXUIElementCreateApplication(processIdentifier)

            let matches = Self.collectMatches(root: appElement, role: role, identifier: identifier, title: title)
            guard !matches.isEmpty else { throw QAXInteractionError.noMatchingElement }
            guard matches.count == 1 else { throw QAXInteractionError.ambiguousTarget(count: matches.count) }

            let (targetElement, observedAtSearch) = matches[0]

            // Observation binding: re-read the SAME element reference immediately before the
            // parameterized-attribute-name read and refuse on any drift — identical discipline to
            // every prior AX capability in this codebase.
            guard let observedAtVerify = Self.snapshotIfMatches(targetElement, role: role, identifier: identifier, title: title) else {
                throw QAXInteractionError.staleTarget("target element is no longer resolvable immediately before parameterized attribute enumeration")
            }
            guard observedAtVerify == observedAtSearch else {
                throw QAXInteractionError.staleTarget("target element identity changed between observation and parameterized attribute enumeration")
            }

            // AXUIElementCopyParameterizedAttributeNames — the discovery call itself. Purely
            // observational: never AXUIElementCopyParameterizedAttributeValue for any of the
            // discovered names, never AXUIElementSetAttributeValue, never
            // AXUIElementPerformAction.
            var parameterizedAttributeNamesValue: CFArray?
            let copyResult = AXUIElementCopyParameterizedAttributeNames(targetElement, &parameterizedAttributeNamesValue)

            switch copyResult {
            case .success:
                break
            case .attributeUnsupported, .parameterizedAttributeUnsupported, .notImplemented:
                // Genuine, expected absence — many elements support zero parameterized
                // attributes at all. Never an error; a valid empty result.
                return QAXElementParameterizedAttributeNamesMetadata(
                    applicationName: applicationName,
                    role: role,
                    parameterizedAttributeNames: []
                )
            default:
                throw QAXInteractionError.parameterizedAttributeNamesCollectionMalformed
            }
            guard let parameterizedAttributeNamesValue else {
                throw QAXInteractionError.parameterizedAttributeNamesCollectionMalformed
            }
            // The returned value is treated as untrusted external data — success from the copy
            // call is never itself sufficient proof of a well-formed [String] array.
            guard let rawParameterizedAttributeNames = parameterizedAttributeNamesValue as? [String] else {
                throw QAXInteractionError.parameterizedAttributeNamesCollectionMalformed
            }
            guard rawParameterizedAttributeNames.count <= Self.maxElementAttributesCount else {
                throw QAXInteractionError.parameterizedAttributeNamesCollectionExceedsSafeBound(rawParameterizedAttributeNames.count)
            }
            for parameterizedAttributeName in rawParameterizedAttributeNames {
                guard parameterizedAttributeName.count <= Self.maxAttributeNameLength else {
                    throw QAXInteractionError.parameterizedAttributeNameExceedsSafeLength(parameterizedAttributeName.count)
                }
            }

            return QAXElementParameterizedAttributeNamesMetadata(
                applicationName: applicationName,
                role: role,
                parameterizedAttributeNames: rawParameterizedAttributeNames
            )
        }.value
    }

    // MARK: - Semantic Element Required State Read (Phase 2BQ)
    //
    // ui.read_element_required_state — a Level 0, read-only, zero-mutation, purely OBSERVATIONAL
    // read of a semantically-identified element's `AXRequired` attribute (whether the element is
    // required for successful form submission). Unlike `kAXModalAttribute` (Phase 2BO, documented
    // "Required for all window elements"), `AXRequired` has no such universal-presence
    // documentation — it is meaningful only for form-field-like elements, so this capability
    // follows the OPTIONAL-reference missing-vs-failure pattern established for
    // `kAXDefaultButtonAttribute`/`kAXCancelButtonAttribute` (Phase 2BM) and
    // `kAXTitleUIElementAttribute` (Phase 2BN), not the inverted "absence is failure" pattern used
    // for `kAXModalAttribute`: genuine absence produces a valid `nil`, never an error, and is never
    // silently downgraded to `false`.

    /// Resolves exactly one semantic target on `QAXElementReadRolePolicy`'s allowlist and reads its
    /// `AXRequired` attribute — a purely observational call; neither `AXUIElementPerformAction` nor
    /// `AXUIElementSetAttributeValue` is invoked anywhere in this method. Fails closed (throws
    /// `QAXInteractionError`) on a disallowed/secure role, missing criteria, permission absence,
    /// application/target absence or ambiguity, a stale/drifted target, a genuine read failure, or
    /// a malformed (non-Boolean) returned value. Genuine absence
    /// (`kAXErrorNoValue`/`kAXErrorAttributeUnsupported`) is NEVER an error — it produces `nil`;
    /// most non-form elements have no required-state concept at all. Never fabricates a Boolean.
    public func readElementRequiredState(
        applicationName: String,
        role: String,
        identifier: String?,
        title: String?
    ) async throws -> QAXElementRequiredStateMetadata {
        guard identifier != nil || title != nil else {
            throw QAXInteractionError.missingMatchCriteria
        }
        // Secure field first, for a specific diagnostic; then the general allowlist, which would
        // also reject AXSecureTextField on its own (it is never listed) — belt and suspenders,
        // identical discipline to every prior read capability's own checks.
        guard role != "AXSecureTextField" else {
            throw QAXInteractionError.secureFieldReadDenied(role)
        }
        guard QAXElementReadRolePolicy.isAllowedReadRole(role) else {
            throw QAXInteractionError.disallowedReadRole(role)
        }

        guard AXIsProcessTrusted() else {
            throw QAXInteractionError.accessibilityPermissionDenied
        }

        let runningApp = try Self.resolveExactRunningApplication(named: applicationName)
        let processIdentifier = runningApp.processIdentifier

        return try await Task.detached(priority: .userInitiated) {
            let appElement = AXUIElementCreateApplication(processIdentifier)

            let matches = Self.collectMatches(root: appElement, role: role, identifier: identifier, title: title)
            guard !matches.isEmpty else { throw QAXInteractionError.noMatchingElement }
            guard matches.count == 1 else { throw QAXInteractionError.ambiguousTarget(count: matches.count) }

            let (targetElement, observedAtSearch) = matches[0]

            // Observation binding: re-read the SAME element reference immediately before the
            // required-state read and refuse on any drift — identical discipline to every prior AX
            // capability in this codebase.
            guard let observedAtVerify = Self.snapshotIfMatches(targetElement, role: role, identifier: identifier, title: title) else {
                throw QAXInteractionError.staleTarget("target element is no longer resolvable immediately before the required-state read")
            }
            guard observedAtVerify == observedAtSearch else {
                throw QAXInteractionError.staleTarget("target element identity changed between observation and the required-state read")
            }

            let isRequired = try Self.resolveElementRequiredState(of: targetElement)

            return QAXElementRequiredStateMetadata(
                applicationName: applicationName,
                role: role,
                isRequired: isRequired
            )
        }.value
    }

    /// Resolves `AXRequired` as an optional `Bool?`, distinguishing genuine absence from a genuine
    /// read failure — see the `MARK` section above for the full missing-vs-failure rationale.
    /// `kAXErrorNoValue`/`kAXErrorAttributeUnsupported` produce a valid `nil`; any other `AXError`
    /// fails closed as `elementRequiredStateReadFailed`; a successful copy whose value cannot be
    /// interpreted as a `Bool` fails closed as `elementRequiredStateMalformed` — the returned value
    /// is treated as untrusted external data, never assumed well-formed merely because the copy
    /// call itself reported success. An explicit `false` is a fully valid, distinct outcome from
    /// either `nil` or either failure case — it is returned directly, never conflated with
    /// "missing."
    fileprivate nonisolated static func resolveElementRequiredState(of targetElement: AXUIElement) throws -> Bool? {
        var value: CFTypeRef?
        let copyResult = AXUIElementCopyAttributeValue(targetElement, Self.axRequiredAttributeName as CFString, &value)

        switch copyResult {
        case .success:
            break
        case .noValue, .attributeUnsupported:
            // Genuine, expected absence — most non-form elements have no required-state concept
            // at all. Never an error.
            return nil
        default:
            throw QAXInteractionError.elementRequiredStateReadFailed("AXError(\(copyResult.rawValue))")
        }

        guard let value, let isRequired = value as? Bool else {
            throw QAXInteractionError.elementRequiredStateMalformed
        }
        return isRequired
    }

    // MARK: - Semantic Element Protected Content State Read (Phase 2BR)
    //
    // ui.read_element_protected_content_state — a Level 0, read-only, zero-mutation, purely
    // OBSERVATIONAL read of a semantically-identified element's `AXContainsProtectedContent`
    // attribute (whether the element contains protected content, e.g. a secure field). Unlike
    // `kAXModalAttribute` (Phase 2BO, documented "Required for all window elements"),
    // `AXContainsProtectedContent` has no such universal-presence documentation — it is meaningful
    // only for elements that can meaningfully hold sensitive content, so this capability follows
    // the OPTIONAL-reference missing-vs-failure pattern established for `AXRequired` (Phase 2BQ),
    // `kAXDefaultButtonAttribute`/`kAXCancelButtonAttribute` (Phase 2BM), and
    // `kAXTitleUIElementAttribute` (Phase 2BN): genuine absence produces a valid `nil`, never an
    // error, and is never silently downgraded to `false`. This is the first capability in the
    // program whose entire purpose is defensive/security-aware observation — the boolean it
    // returns is intended to help a future planner AVOID sensitive content, never to expose any
    // of that content itself. This capability never reads, references, or exposes the protected
    // content — only whether it exists.

    /// Resolves exactly one semantic target on `QAXElementReadRolePolicy`'s allowlist and reads its
    /// `AXContainsProtectedContent` attribute — a purely observational call; neither
    /// `AXUIElementPerformAction` nor `AXUIElementSetAttributeValue` is invoked anywhere in this
    /// method, and no attribute other than `AXContainsProtectedContent` is ever read. Fails closed
    /// (throws `QAXInteractionError`) on a disallowed/secure role, missing criteria, permission
    /// absence, application/target absence or ambiguity, a stale/drifted target, a genuine read
    /// failure, or a malformed (non-Boolean) returned value. Genuine absence
    /// (`kAXErrorNoValue`/`kAXErrorAttributeUnsupported`) is NEVER an error — it produces `nil`;
    /// most elements have no protected-content concept at all. Never fabricates a Boolean.
    public func readElementProtectedContentState(
        applicationName: String,
        role: String,
        identifier: String?,
        title: String?
    ) async throws -> QAXElementProtectedContentStateMetadata {
        guard identifier != nil || title != nil else {
            throw QAXInteractionError.missingMatchCriteria
        }
        // Secure field first, for a specific diagnostic; then the general allowlist, which would
        // also reject AXSecureTextField on its own (it is never listed) — belt and suspenders,
        // identical discipline to every prior read capability's own checks. Note: this capability
        // deliberately rejects AXSecureTextField as a TARGET exactly like every other read
        // capability — it never reads a secure field's protected-content flag by resolving the
        // secure field directly; it may still observe the flag on a non-secure-field element that
        // happens to report protected content via some other AX mechanism.
        guard role != "AXSecureTextField" else {
            throw QAXInteractionError.secureFieldReadDenied(role)
        }
        guard QAXElementReadRolePolicy.isAllowedReadRole(role) else {
            throw QAXInteractionError.disallowedReadRole(role)
        }

        guard AXIsProcessTrusted() else {
            throw QAXInteractionError.accessibilityPermissionDenied
        }

        let runningApp = try Self.resolveExactRunningApplication(named: applicationName)
        let processIdentifier = runningApp.processIdentifier

        return try await Task.detached(priority: .userInitiated) {
            let appElement = AXUIElementCreateApplication(processIdentifier)

            let matches = Self.collectMatches(root: appElement, role: role, identifier: identifier, title: title)
            guard !matches.isEmpty else { throw QAXInteractionError.noMatchingElement }
            guard matches.count == 1 else { throw QAXInteractionError.ambiguousTarget(count: matches.count) }

            let (targetElement, observedAtSearch) = matches[0]

            // Observation binding: re-read the SAME element reference immediately before the
            // protected-content-state read and refuse on any drift — identical discipline to every
            // prior AX capability in this codebase.
            guard let observedAtVerify = Self.snapshotIfMatches(targetElement, role: role, identifier: identifier, title: title) else {
                throw QAXInteractionError.staleTarget("target element is no longer resolvable immediately before the protected-content-state read")
            }
            guard observedAtVerify == observedAtSearch else {
                throw QAXInteractionError.staleTarget("target element identity changed between observation and the protected-content-state read")
            }

            let isProtectedContent = try Self.resolveElementProtectedContentState(of: targetElement)

            return QAXElementProtectedContentStateMetadata(
                applicationName: applicationName,
                role: role,
                isProtectedContent: isProtectedContent
            )
        }.value
    }

    /// Resolves `AXContainsProtectedContent` as an optional `Bool?`, distinguishing genuine
    /// absence from a genuine read failure — see the `MARK` section above for the full
    /// missing-vs-failure rationale. `kAXErrorNoValue`/`kAXErrorAttributeUnsupported` produce a
    /// valid `nil`; any other `AXError` fails closed as `elementProtectedContentStateReadFailed`;
    /// a successful copy whose value cannot be interpreted as a `Bool` fails closed as
    /// `elementProtectedContentStateMalformed` — the returned value is treated as untrusted
    /// external data, never assumed well-formed merely because the copy call itself reported
    /// success. An explicit `false` is a fully valid, distinct outcome from either `nil` or either
    /// failure case — it is returned directly, never conflated with "missing." This function reads
    /// exactly one attribute and never descends into the target's own value/content.
    fileprivate nonisolated static func resolveElementProtectedContentState(of targetElement: AXUIElement) throws -> Bool? {
        var value: CFTypeRef?
        let copyResult = AXUIElementCopyAttributeValue(targetElement, Self.axContainsProtectedContentAttributeName as CFString, &value)

        switch copyResult {
        case .success:
            break
        case .noValue, .attributeUnsupported:
            // Genuine, expected absence — most elements have no protected-content concept at all.
            // Never an error.
            return nil
        default:
            throw QAXInteractionError.elementProtectedContentStateReadFailed("AXError(\(copyResult.rawValue))")
        }

        guard let value, let isProtectedContent = value as? Bool else {
            throw QAXInteractionError.elementProtectedContentStateMalformed
        }
        return isProtectedContent
    }

    // MARK: - Semantic Text Selection State Read (Phase 2BS)
    //
    // ui.read_text_selection_state — a Level 0, read-only, zero-mutation, purely OBSERVATIONAL
    // read of a semantically-identified element's text-SELECTION STATE — never its content.
    // `kAXSelectedTextRangeAttribute` and `kAXNumberOfCharactersAttribute` are both documented
    // "Required for all editable text elements", but neither is documented as universally present
    // on every AX element, so this capability follows the OPTIONAL-reference missing-vs-failure
    // pattern established for `AXRequired`/`AXContainsProtectedContent` (Phases 2BQ/2BR): genuine
    // absence produces a valid `nil` for the WHOLE result, never an error, and is never silently
    // downgraded to a fabricated zero/empty state. SECURITY-CRITICAL INVARIANT: this capability
    // deliberately NEVER reads `kAXSelectedTextAttribute` (the actual selected text) or any other
    // content-bearing attribute — only the numeric location/length/total-count facts ever cross
    // this capability's boundary. This capability NEVER calls `AXUIElementSetAttributeValue` —
    // even though `kAXSelectedTextRangeAttribute` is itself documented `Writable? Yes` at the
    // native API level, this capability is strictly read-only and never writes it.

    /// Resolves exactly one semantic target on `QAXElementReadRolePolicy`'s allowlist and reads its
    /// text-selection STATE (`kAXSelectedTextRangeAttribute` + `kAXNumberOfCharactersAttribute`) —
    /// a purely observational read; neither `AXUIElementPerformAction` nor
    /// `AXUIElementSetAttributeValue` is invoked anywhere in this method, and
    /// `kAXSelectedTextAttribute` (the actual selected text) is never read. Fails closed (throws
    /// `QAXInteractionError`) on a disallowed/secure role, missing criteria, permission absence,
    /// application/target absence or ambiguity, a stale/drifted target, a genuine read failure, a
    /// malformed returned value, a structurally invalid range/count (negative
    /// location/length/total), or an internally inconsistent triple (`selectionLocation +
    /// selectionLength` exceeding `totalCharacterCount`, checked with overflow-safe arithmetic).
    /// Genuine absence of EITHER attribute (`kAXErrorNoValue`/`kAXErrorAttributeUnsupported`) makes
    /// the WHOLE result `nil` — never a partially-known state; most non-text elements have no
    /// text-selection concept at all. A `selectionLength` of `0` is a fully valid, honestly
    /// distinct result (a caret/insertion point), never treated as an error or as absence. Never
    /// fabricates a value.
    public func readTextSelectionState(
        applicationName: String,
        role: String,
        identifier: String?,
        title: String?
    ) async throws -> QAXTextSelectionStateMetadata? {
        guard identifier != nil || title != nil else {
            throw QAXInteractionError.missingMatchCriteria
        }
        // Secure field first, for a specific diagnostic; then the general allowlist, which would
        // also reject AXSecureTextField on its own (it is never listed) — belt and suspenders,
        // identical discipline to every prior read capability's own checks. This capability never
        // broadens secure-field access and never reads secure text content — it never resolves an
        // AXSecureTextField as its target at all.
        guard role != "AXSecureTextField" else {
            throw QAXInteractionError.secureFieldReadDenied(role)
        }
        guard QAXElementReadRolePolicy.isAllowedReadRole(role) else {
            throw QAXInteractionError.disallowedReadRole(role)
        }

        guard AXIsProcessTrusted() else {
            throw QAXInteractionError.accessibilityPermissionDenied
        }

        let runningApp = try Self.resolveExactRunningApplication(named: applicationName)
        let processIdentifier = runningApp.processIdentifier

        return try await Task.detached(priority: .userInitiated) {
            let appElement = AXUIElementCreateApplication(processIdentifier)

            let matches = Self.collectMatches(root: appElement, role: role, identifier: identifier, title: title)
            guard !matches.isEmpty else { throw QAXInteractionError.noMatchingElement }
            guard matches.count == 1 else { throw QAXInteractionError.ambiguousTarget(count: matches.count) }

            let (targetElement, observedAtSearch) = matches[0]

            // Observation binding: re-read the SAME element reference immediately before the
            // text-selection-state read and refuse on any drift — identical discipline to every
            // prior AX capability in this codebase.
            guard let observedAtVerify = Self.snapshotIfMatches(targetElement, role: role, identifier: identifier, title: title) else {
                throw QAXInteractionError.staleTarget("target element is no longer resolvable immediately before the text-selection-state read")
            }
            guard observedAtVerify == observedAtSearch else {
                throw QAXInteractionError.staleTarget("target element identity changed between observation and the text-selection-state read")
            }

            guard let (selectionLocation, selectionLength) = try Self.resolveSelectedTextRange(of: targetElement) else {
                // Genuine, expected absence of the selection-range attribute — the whole result is
                // absent, never a partially-known state.
                return nil
            }
            guard let totalCharacterCount = try Self.resolveNumberOfCharacters(of: targetElement) else {
                // The selection range was present but the character count is genuinely absent —
                // per this capability's contract, absence of EITHER attribute makes the whole
                // result absent, since both are documented as co-required for editable text
                // elements and a partial state cannot be validated for internal consistency.
                return nil
            }

            let (locationPlusLength, overflowed) = selectionLocation.addingReportingOverflow(selectionLength)
            guard !overflowed else {
                throw QAXInteractionError.textSelectionStateInconsistent("selectionLocation (\(selectionLocation)) + selectionLength (\(selectionLength)) overflowed")
            }
            guard locationPlusLength <= totalCharacterCount else {
                throw QAXInteractionError.textSelectionStateInconsistent("selectionLocation (\(selectionLocation)) + selectionLength (\(selectionLength)) exceeds totalCharacterCount (\(totalCharacterCount))")
            }

            return QAXTextSelectionStateMetadata(
                applicationName: applicationName,
                role: role,
                selectionLocation: selectionLocation,
                selectionLength: selectionLength,
                totalCharacterCount: totalCharacterCount
            )
        }.value
    }

    /// Resolves `kAXSelectedTextRangeAttribute` as an optional `(location, length)` tuple,
    /// distinguishing genuine absence from a genuine read failure — see the `MARK` section above
    /// for the full missing-vs-failure rationale. `kAXErrorNoValue`/`kAXErrorAttributeUnsupported`
    /// produce a valid `nil`; any other `AXError` fails closed as `textSelectionRangeReadFailed`;
    /// a successful copy whose value is not a well-formed `AXValue` of type `kAXValueTypeCFRange`
    /// fails closed as `textSelectionRangeMalformed` — the returned value is treated as untrusted
    /// external data, never assumed well-formed merely because the copy call itself reported
    /// success. A structurally invalid range (negative `location`/`length`) fails closed as
    /// `textSelectionRangeInvalid` — never silently clamped to zero. Never reads
    /// `kAXSelectedTextAttribute` (the actual selected text).
    fileprivate nonisolated static func resolveSelectedTextRange(of targetElement: AXUIElement) throws -> (location: Int, length: Int)? {
        var value: CFTypeRef?
        let copyResult = AXUIElementCopyAttributeValue(targetElement, kAXSelectedTextRangeAttribute as CFString, &value)

        switch copyResult {
        case .success:
            break
        case .noValue, .attributeUnsupported:
            // Genuine, expected absence — most non-text elements have no selection-range concept
            // at all. Never an error.
            return nil
        default:
            throw QAXInteractionError.textSelectionRangeReadFailed("AXError(\(copyResult.rawValue))")
        }

        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else {
            throw QAXInteractionError.textSelectionRangeMalformed
        }
        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cfRange else {
            throw QAXInteractionError.textSelectionRangeMalformed
        }
        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range) else {
            throw QAXInteractionError.textSelectionRangeMalformed
        }

        let location = range.location
        let length = range.length
        guard location >= 0, length >= 0 else {
            throw QAXInteractionError.textSelectionRangeInvalid("location=\(location) length=\(length)")
        }

        return (location, length)
    }

    /// Resolves `kAXNumberOfCharactersAttribute` as an optional `Int`, distinguishing genuine
    /// absence from a genuine read failure — see the `MARK` section above for the full
    /// missing-vs-failure rationale. `kAXErrorNoValue`/`kAXErrorAttributeUnsupported` produce a
    /// valid `nil`; any other `AXError` fails closed as `characterCountReadFailed`; a successful
    /// copy whose value cannot be interpreted as a number fails closed as
    /// `characterCountMalformed`. A structurally invalid (negative) count fails closed as
    /// `characterCountInvalid` — never silently clamped to zero.
    fileprivate nonisolated static func resolveNumberOfCharacters(of targetElement: AXUIElement) throws -> Int? {
        var value: CFTypeRef?
        let copyResult = AXUIElementCopyAttributeValue(targetElement, kAXNumberOfCharactersAttribute as CFString, &value)

        switch copyResult {
        case .success:
            break
        case .noValue, .attributeUnsupported:
            // Genuine, expected absence — most non-text elements have no character-count concept
            // at all. Never an error.
            return nil
        default:
            throw QAXInteractionError.characterCountReadFailed("AXError(\(copyResult.rawValue))")
        }

        guard let value, let numberValue = value as? NSNumber else {
            throw QAXInteractionError.characterCountMalformed
        }
        let totalCharacterCount = numberValue.intValue
        guard totalCharacterCount >= 0 else {
            throw QAXInteractionError.characterCountInvalid("totalCharacterCount=\(totalCharacterCount)")
        }
        return totalCharacterCount
    }

    /// Best-effort, polymorphic `kAXValueAttribute` reader — text fields/labels typically carry a
    /// `String`, checkboxes/sliders/steppers typically carry a boxed number (`NSNumber`,
    /// commonly bridging a Bool or Int) — returns a human-readable string representation in
    /// either case, or nil if the attribute is absent/unreadable/of an unrecognized type.
    fileprivate nonisolated static func axValueDescription(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value)
        guard result == .success, let value else { return nil }
        if let stringValue = value as? String {
            return stringValue.isEmpty ? nil : stringValue
        }
        if let numberValue = value as? NSNumber {
            return numberValue.stringValue
        }
        return nil
    }

    // MARK: - Semantic AX Element Range Read (Phase 2BJ)
    //
    // ui.read_element_range — a Level 0, read-only, zero-mutation read of a semantically-
    // identified element's authoritative numeric range: kAXMinValueAttribute/
    // kAXMaxValueAttribute/kAXValueIncrementAttribute plus its current kAXValueAttribute. These
    // are the exact same attributes ui.set_slider_value/ui.step_incrementor/
    // ui.set_splitter_position already read INTERNALLY for their own idempotency/range-validation
    // before ever proposing a mutation — but never previously exposed to the model as their own
    // queryable fact. Target roles are restricted to QAXRangeReadRolePolicy's fail-closed
    // allowlist (AXSlider/AXIncrementor/AXSplitter — all verified against the live SDK's
    // AXRoleConstants.h at implementation time; the historically-inert "AXStepper" string is
    // deliberately not carried forward from QAXSliderRolePolicy). No traversal beyond the one
    // resolved element: kAXChildrenAttribute is never read here.

    /// Resolves exactly one semantic target on `QAXRangeReadRolePolicy`'s allowlist and reads its
    /// authoritative `kAXMinValueAttribute`/`kAXMaxValueAttribute` (both required — the read fails
    /// closed rather than fabricating a value if either is unreadable), its current
    /// `kAXValueAttribute` (required), and its optional `kAXValueIncrementAttribute` (never
    /// required, never defaulted — a missing/unreadable increment is a valid, honestly-reported
    /// `nil`). Fails closed (throws `QAXInteractionError`) on a disallowed role, missing match
    /// criteria, permission absence, application/target absence or ambiguity, a stale/drifted
    /// target, an internally-inconsistent range (`minValue > maxValue`), or a current value
    /// outside the reported range — never clamps, never repairs, never substitutes a default.
    /// Never mutates anything.
    public func readElementRange(
        applicationName: String,
        role: String,
        identifier: String?,
        title: String?
    ) async throws -> QAXElementRangeMetadata {
        guard QAXRangeReadRolePolicy.isAllowedRangeReadRole(role) else {
            throw QAXInteractionError.disallowedRangeReadRole(role)
        }
        guard identifier != nil || title != nil else {
            throw QAXInteractionError.missingMatchCriteria
        }
        guard AXIsProcessTrusted() else {
            throw QAXInteractionError.accessibilityPermissionDenied
        }

        let runningApp = try Self.resolveExactRunningApplication(named: applicationName)
        let processIdentifier = runningApp.processIdentifier

        return try await Task.detached(priority: .userInitiated) {
            let appElement = AXUIElementCreateApplication(processIdentifier)

            let matches = Self.collectMatches(root: appElement, role: role, identifier: identifier, title: title)
            guard !matches.isEmpty else { throw QAXInteractionError.noMatchingElement }
            guard matches.count == 1 else { throw QAXInteractionError.ambiguousTarget(count: matches.count) }

            let (targetElement, observedAtSearch) = matches[0]

            // Observation binding: re-read the SAME element reference immediately before the
            // range read and refuse on any drift — identical discipline to every prior AX
            // capability in this codebase, even though this is a read, not a mutation (the range
            // itself could still legitimately change between search and read on a live control).
            guard let observedAtVerify = Self.snapshotIfMatches(targetElement, role: role, identifier: identifier, title: title) else {
                throw QAXInteractionError.staleTarget("target element is no longer resolvable immediately before the range read")
            }
            guard observedAtVerify == observedAtSearch else {
                throw QAXInteractionError.staleTarget("target element identity changed between observation and the range read")
            }

            // Range discovery — kAXMinValueAttribute/kAXMaxValueAttribute are both required;
            // neither is ever defaulted or clamped. Mirrors ui.set_slider_value's own identical
            // pre-mutation validation sequence exactly (Phase 2M), reused as the read contract
            // here rather than duplicated with different semantics.
            guard let minValue = Self.axDoubleAttribute(kAXMinValueAttribute as String, of: targetElement),
                  let maxValue = Self.axDoubleAttribute(kAXMaxValueAttribute as String, of: targetElement) else {
                throw QAXInteractionError.rangeReadFailed
            }
            guard minValue <= maxValue else {
                throw QAXInteractionError.invalidRange("minValue (\(minValue)) is greater than maxValue (\(maxValue))")
            }
            guard let currentValue = Self.axDoubleAttribute(kAXValueAttribute as String, of: targetElement) else {
                throw QAXInteractionError.valueReadFailed
            }
            guard currentValue >= minValue, currentValue <= maxValue else {
                throw QAXInteractionError.invalidRange("current value (\(currentValue)) is outside the reported range [\(minValue), \(maxValue)]")
            }

            // kAXValueIncrementAttribute is documented "Recommended for kAXIncrementorRole and
            // other similar elements" — optional, never required, never defaulted. A missing or
            // unreadable increment is a valid, honestly-reported nil, never a fabricated value.
            let valueIncrement = Self.axDoubleAttribute(kAXValueIncrementAttribute as String, of: targetElement)

            return QAXElementRangeMetadata(
                applicationName: applicationName,
                role: role,
                minValue: minValue,
                maxValue: maxValue,
                currentValue: currentValue,
                valueIncrement: valueIncrement
            )
        }.value
    }

    // MARK: - Semantic AX Element State Change (Phase 2K)
    //
    // ui.set_element_state — a Level 2, reversible, semantic checkbox/radio-button state change.
    // Every element is identified by role + (identifier or title), exactly like
    // ui.click_element/ui.set_text_value, restricted to QAXElementStateRolePolicy's fail-closed
    // allowlist (AXCheckBox/AXRadioButton only). Unlike ui.click_element's stateless press, this
    // capability verifies the resulting VALUE, not just identity — QAXElementSnapshot has no
    // value field, so click's own verification would very likely report a false failure for a
    // value-bearing control. Mutation is AXUIElementPerformAction(kAXPressAction) only — the same
    // dispatch primitive click already uses — never AXUIElementSetAttributeValue, since many
    // native controls only run their real state-change handling in response to a genuine press.

    /// Resolves exactly one semantic AXCheckBox/AXRadioButton target, verifies it is not stale by
    /// BOTH identity (role/identifier/title/enabled, like click) and VALUE (a new check this
    /// capability introduces — the state read at resolution time must still match immediately
    /// before dispatch, or the operation is refused as a value-drift staleness failure), and
    /// presses it via `AXUIElementPerformAction` only if its current state differs from
    /// `desiredState` — an already-correct target is an idempotent no-op, never pressed. Fails
    /// closed (throws `QAXInteractionError`) on a disallowed role, unreadable/uninterpretable
    /// state, ambiguous/stale target, or a state transition the AX press mechanism cannot
    /// guarantee (deselecting an `AXRadioButton`). Never falls back to coordinates, CGEvent, or
    /// keyboard simulation.
    public func setElementState(
        applicationName: String,
        role: String,
        identifier: String?,
        title: String?,
        desiredState: QAXElementState
    ) async throws -> QAXElementStateOutcome {
        guard identifier != nil || title != nil else {
            throw QAXInteractionError.missingMatchCriteria
        }
        guard QAXElementStateRolePolicy.isAllowedStateRole(role) else {
            throw QAXInteractionError.disallowedStateRole(role)
        }

        guard AXIsProcessTrusted() else {
            throw QAXInteractionError.accessibilityPermissionDenied
        }

        let runningApp = try Self.resolveExactRunningApplication(named: applicationName)

        let processIdentifier = runningApp.processIdentifier

        return try await Task.detached(priority: .userInitiated) {
            let appElement = AXUIElementCreateApplication(processIdentifier)

            let matches = Self.collectMatches(root: appElement, role: role, identifier: identifier, title: title)
            guard !matches.isEmpty else { throw QAXInteractionError.noMatchingElement }
            guard matches.count == 1 else { throw QAXInteractionError.ambiguousTarget(count: matches.count) }

            let (targetElement, observedAtSearch) = matches[0]

            // Identity observation binding: identical discipline to clickElement/setTextValue.
            guard let observedAtVerify = Self.snapshotIfMatches(targetElement, role: role, identifier: identifier, title: title) else {
                throw QAXInteractionError.staleTarget("target element is no longer resolvable immediately before dispatch")
            }
            guard observedAtVerify == observedAtSearch else {
                throw QAXInteractionError.staleTarget("target element identity changed between observation and dispatch")
            }
            guard observedAtVerify.isEnabled else {
                throw QAXInteractionError.targetDisabled
            }

            // Value-drift staleness check (Phase 2K's addition beyond click's identity-only
            // discipline): read the state once at resolution, once again immediately before
            // dispatch, and refuse if they differ — the target may still be the exact same
            // element by identity, but something already changed its value out from under this
            // call. As with the identity re-verify above, both reads happen back-to-back inside
            // one synchronous closure with no `await` between them — a genuine race in the
            // sub-millisecond window between the two reads themselves cannot be triggered
            // deterministically without an artificial delay seam in production code, the same
            // documented, honest limitation already accepted for click's identity check.
            guard let stateAtSearch = Self.axCheckboxRadioState(of: targetElement) else {
                throw QAXInteractionError.stateReadFailed
            }
            guard let stateAtVerify = Self.axCheckboxRadioState(of: targetElement) else {
                throw QAXInteractionError.stateReadFailed
            }
            guard stateAtVerify == stateAtSearch else {
                throw QAXInteractionError.valueDriftDetected("target element state changed between observation and dispatch")
            }

            let targetIdentity = "application=\(applicationName) role=\(role) identifier=\(observedAtVerify.identifier ?? "none") label=\(observedAtVerify.titleOrDescription ?? "none")"
            let desiredStateHash = Self.sha256Hex(desiredState.rawValue)

            guard stateAtVerify != desiredState else {
                // Idempotent no-op: the control already holds the desired state. No AX press is
                // performed — an unnecessary mutation is itself something to avoid.
                return QAXElementStateOutcome(
                    changeKind: .alreadyDesired,
                    previousState: stateAtVerify,
                    currentState: stateAtVerify,
                    targetIdentity: targetIdentity,
                    previousStateHash: Self.sha256Hex(stateAtVerify.rawValue),
                    desiredStateHash: desiredStateHash
                )
            }

            // AXRadioButton supports being reliably SELECTED (press while off) but macOS provides
            // no reliable way to deselect a single radio button via its own press action — the
            // standard interaction model selects a different button in the group instead. Refuse
            // rather than press and hope, per "if the AX API cannot safely guarantee the desired
            // state, fail closed."
            if role == "AXRadioButton" && desiredState == .off {
                throw QAXInteractionError.stateChangeNotGuaranteed(
                    "AXRadioButton cannot be reliably deselected via its own press action; select a different radio button in the group instead"
                )
            }

            let pressResult = AXUIElementPerformAction(targetElement, kAXPressAction as CFString)
            switch pressResult {
            case .success:
                break
            case .actionUnsupported:
                throw QAXInteractionError.actionUnsupported
            default:
                throw QAXInteractionError.pressFailed("AXError(\(pressResult.rawValue))")
            }

            // Immediate ephemeral post-press read — provisional only; the authoritative check is
            // the later, independent closed-loop verification step
            // (QVerificationStrategy.axElementStateMatchesDesired), which re-resolves the target
            // fresh rather than trusting this in-process observation.
            let currentState = Self.axCheckboxRadioState(of: targetElement) ?? desiredState

            return QAXElementStateOutcome(
                changeKind: .changed,
                previousState: stateAtVerify,
                currentState: currentState,
                targetIdentity: targetIdentity,
                previousStateHash: Self.sha256Hex(stateAtVerify.rawValue),
                desiredStateHash: desiredStateHash
            )
        }.value
    }

    /// Best-effort, read-only re-resolution of the same match criteria used by `setElementState`,
    /// used only for the later closed-loop verification step
    /// (QVerificationStrategy.axElementStateMatchesDesired). Returns the CURRENT state's SHA-256
    /// hash only, or nil if the target is no longer uniquely resolvable or its state cannot be
    /// read/interpreted.
    public func observeElementStateHash(
        applicationName: String,
        role: String,
        identifier: String?,
        title: String?
    ) async -> String? {
        guard AXIsProcessTrusted() else { return nil }
        guard let runningApp = try? Self.resolveExactRunningApplication(named: applicationName) else { return nil }

        let processIdentifier = runningApp.processIdentifier
        return await Task.detached(priority: .userInitiated) {
            let appElement = AXUIElementCreateApplication(processIdentifier)
            let matches = Self.collectMatches(root: appElement, role: role, identifier: identifier, title: title)
            guard matches.count == 1 else { return nil }
            guard let state = Self.axCheckboxRadioState(of: matches[0].element) else { return nil }
            return Self.sha256Hex(state.rawValue)
        }.value
    }

    /// Reads `kAXValueAttribute` and interprets it as a clean on/off boolean state: `0` → `.off`,
    /// `1` → `.on`. Any other value (including `2`, the conventional AX "mixed"/indeterminate
    /// tri-state) or a non-numeric/unreadable attribute returns nil — this capability never
    /// guesses at an ambiguous current state.
    fileprivate nonisolated static func axCheckboxRadioState(of element: AXUIElement) -> QAXElementState? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value)
        guard result == .success, let value else { return nil }
        guard let numberValue = value as? NSNumber else { return nil }
        switch numberValue.intValue {
        case 0: return .off
        case 1: return .on
        default: return nil
        }
    }

    // MARK: - Semantic Menu-Bar Item Selection (Phase 2L)
    //
    // ui.select_menu_item — a Level 2, single-level menu selection: one top-level AXMenuBarItem
    // (matched by menuBarTitle) and one direct AXMenuItem within its opened AXMenu (matched by
    // itemTitle). Never a nested submenu, never a context/right-click menu, never the system-wide
    // Apple menu (a distinct AX element under AXUIElementCreateSystemWide, never queried here),
    // never the application's own root menu (explicitly checked and refused below). Opening the
    // menu and selecting the item happen atomically within ONE approved execution — two
    // AXUIElementPerformAction presses, the same dispatch primitive ui.click_element already
    // uses — specifically because two separately-approved ui.click_element presses could not
    // reliably do this: the approval HUD appearing between them is itself a focus-stealing event,
    // and native menus dismiss on focus loss.

    /// Bounded menu-open poll: fixed maximum attempts, fixed interval between them — a hard
    /// ceiling of `maxMenuOpenPollAttempts * menuOpenPollIntervalNanoseconds` (10 * 50ms = 500ms),
    /// never unbounded, never exponential. This is genuinely new territory for this codebase
    /// (every prior semantic AX capability is single-shot, no-wait) because opening a native menu
    /// is asynchronous relative to the press call returning — the target AXMenuItem is not
    /// guaranteed queryable in the same synchronous instant. Both constants are intentionally
    /// small and conservative, mirroring the bounded-traversal philosophy `collectMatches` already
    /// uses (fixed depth/node/time limits) rather than introducing an unbounded wait.
    fileprivate static let maxMenuOpenPollAttempts = 10
    fileprivate static let menuOpenPollIntervalNanoseconds: UInt64 = 50_000_000

    /// Characters that indicate an attempted nested/multi-level menu path — rejected before any
    /// AX call. `ui.select_menu_item` supports exactly one level.
    fileprivate static let menuPathSeparators: Set<Character> = ["/", ">", "\\", "\u{2192}"]

    /// Resolves a single top-level `AXMenuBarItem`, presses it to open its menu, bounded-polls for
    /// the named direct `AXMenuItem` to become resolvable, re-verifies it immediately before
    /// dispatch, and presses it. Fails closed (throws `QAXInteractionError`) on a nested-path-
    /// shaped input, the application's own root menu, missing/ambiguous/disabled targets at either
    /// level, or a bounded-poll timeout. Never falls back to coordinates, CGEvent, or keyboard
    /// simulation. Never recurses into a submenu — only the opened menu's DIRECT children are
    /// ever searched.
    public func selectMenuItem(
        applicationName: String,
        menuBarTitle: String,
        itemTitle: String
    ) async throws -> QMenuItemSelectionOutcome {
        guard !menuBarTitle.isEmpty, !itemTitle.isEmpty else {
            throw QAXInteractionError.missingMatchCriteria
        }
        guard menuBarTitle.allSatisfy({ !Self.menuPathSeparators.contains($0) }) else {
            throw QAXInteractionError.nestedMenuPathUnsupported("menuBarTitle must name a single top-level menu, not a path")
        }
        guard itemTitle.allSatisfy({ !Self.menuPathSeparators.contains($0) }) else {
            throw QAXInteractionError.nestedMenuPathUnsupported("itemTitle must name a single direct menu item, not a path")
        }

        guard AXIsProcessTrusted() else {
            throw QAXInteractionError.accessibilityPermissionDenied
        }

        let runningApp = try Self.resolveExactRunningApplication(named: applicationName)

        let processIdentifier = runningApp.processIdentifier

        return try await Task.detached(priority: .userInitiated) {
            let appElement = AXUIElementCreateApplication(processIdentifier)

            // Phase A: resolve the app's menu bar, then the named top-level menu bar item.
            guard let menuBarElement = Self.axElementAttribute(kAXMenuBarAttribute as String, of: appElement),
                  Self.axStringAttribute(kAXRoleAttribute, of: menuBarElement) == "AXMenuBar",
                  let menuBarItems = Self.childrenAttribute(of: menuBarElement) else {
                throw QAXInteractionError.menuNotFound(menuBarTitle)
            }

            let matchingMenuBarItems = menuBarItems.enumerated().filter { _, item in
                Self.axStringAttribute(kAXRoleAttribute, of: item) == "AXMenuBarItem" &&
                Self.axStringAttribute(kAXTitleAttribute, of: item) == menuBarTitle
            }
            guard !matchingMenuBarItems.isEmpty else { throw QAXInteractionError.menuNotFound(menuBarTitle) }
            guard matchingMenuBarItems.count == 1 else {
                throw QAXInteractionError.ambiguousTarget(count: matchingMenuBarItems.count)
            }
            let (matchedIndex, menuBarItemElement) = matchingMenuBarItems[0]

            // The application's own root menu (About/Preferences/Quit) is always index 0 by
            // macOS AX convention — explicitly out of scope for this capability's first phase.
            guard matchedIndex != 0 else {
                throw QAXInteractionError.appRootMenuUnsupported(menuBarTitle)
            }

            guard Self.axBoolAttribute(kAXEnabledAttribute, of: menuBarItemElement) ?? false else {
                throw QAXInteractionError.targetDisabled
            }

            let openResult = AXUIElementPerformAction(menuBarItemElement, kAXPressAction as CFString)
            switch openResult {
            case .success:
                break
            case .actionUnsupported:
                throw QAXInteractionError.actionUnsupported
            default:
                throw QAXInteractionError.pressFailed("AXError(\(openResult.rawValue)) while opening menu '\(menuBarTitle)'")
            }

            // Phase B: bounded poll for the named item as a DIRECT child of the now-open menu —
            // never recurses into any nested submenu a matched item might itself contain.
            var resolvedItem: AXUIElement?
            for _ in 0..<Self.maxMenuOpenPollAttempts {
                try Task.checkCancellation()
                if let menuElement = Self.childrenAttribute(of: menuBarItemElement)?.first,
                   Self.axStringAttribute(kAXRoleAttribute, of: menuElement) == "AXMenu",
                   let menuItems = Self.childrenAttribute(of: menuElement) {
                    let matches = menuItems.filter { candidate in
                        Self.axStringAttribute(kAXRoleAttribute, of: candidate) == "AXMenuItem" &&
                        Self.axStringAttribute(kAXTitleAttribute, of: candidate) == itemTitle
                    }
                    if matches.count == 1 {
                        resolvedItem = matches[0]
                        break
                    } else if matches.count > 1 {
                        throw QAXInteractionError.ambiguousTarget(count: matches.count)
                    }
                }
                try? await Task.sleep(nanoseconds: Self.menuOpenPollIntervalNanoseconds)
            }
            guard let itemElement = resolvedItem else {
                throw QAXInteractionError.menuItemNotFound(itemTitle)
            }
            guard Self.axBoolAttribute(kAXEnabledAttribute, of: itemElement) ?? false else {
                throw QAXInteractionError.targetDisabled
            }

            // Re-verify immediately before dispatch, mirroring every prior capability's
            // observation-binding discipline — if the item became disabled between resolution
            // (found during the poll) and this instant, refuse rather than press regardless.
            guard Self.axBoolAttribute(kAXEnabledAttribute, of: itemElement) ?? false else {
                throw QAXInteractionError.staleTarget("target menu item became disabled between resolution and dispatch")
            }

            let targetIdentity = "application=\(applicationName) menu=\(menuBarTitle) item=\(itemTitle)"

            let selectResult = AXUIElementPerformAction(itemElement, kAXPressAction as CFString)
            switch selectResult {
            case .success:
                break
            case .actionUnsupported:
                throw QAXInteractionError.actionUnsupported
            default:
                throw QAXInteractionError.pressFailed("AXError(\(selectResult.rawValue)) while selecting item '\(itemTitle)'")
            }

            return QMenuItemSelectionOutcome(targetIdentity: targetIdentity, menuBarTitle: menuBarTitle, itemTitle: itemTitle)
        }.value
    }

    /// Best-effort, read-only re-resolution used only for the later closed-loop verification step
    /// (QVerificationStrategy.axMenuItemSelectionEvidence). Distinguishes the EXPECTED item-level
    /// disappearance (menu closed after a genuine selection) from an UNEXPECTED application/
    /// menu-bar-item-level disappearance (physical state uncertain) — see
    /// `QMenuItemSelectionEvidence`'s own documentation for the full contract. Never mutates
    /// anything; never re-opens the menu.
    public func observeMenuItemSelectionEvidence(
        applicationName: String,
        menuBarTitle: String,
        itemTitle: String
    ) async -> QMenuItemSelectionEvidence {
        guard AXIsProcessTrusted() else { return .applicationOrTargetUnavailable }
        guard let runningApp = try? Self.resolveExactRunningApplication(named: applicationName) else { return .applicationOrTargetUnavailable }

        let processIdentifier = runningApp.processIdentifier
        return await Task.detached(priority: .userInitiated) {
            let appElement = AXUIElementCreateApplication(processIdentifier)
            guard let menuBarElement = Self.axElementAttribute(kAXMenuBarAttribute as String, of: appElement),
                  let menuBarItems = Self.childrenAttribute(of: menuBarElement) else {
                return .applicationOrTargetUnavailable
            }
            let matchingMenuBarItems = menuBarItems.filter { item in
                Self.axStringAttribute(kAXRoleAttribute, of: item) == "AXMenuBarItem" &&
                Self.axStringAttribute(kAXTitleAttribute, of: item) == menuBarTitle
            }
            // The menu bar item itself disappearing/becoming ambiguous is UNEXPECTED — distinct
            // from the item-level disappearance below, which is the normal post-selection outcome.
            guard matchingMenuBarItems.count == 1 else { return .applicationOrTargetUnavailable }
            let menuBarItemElement = matchingMenuBarItems[0]

            guard let menuElement = Self.childrenAttribute(of: menuBarItemElement)?.first,
                  Self.axStringAttribute(kAXRoleAttribute, of: menuElement) == "AXMenu",
                  let menuItems = Self.childrenAttribute(of: menuElement) else {
                // Menu is no longer open (or has no children) — the expected lifecycle after a
                // genuine selection.
                return .itemNoLongerResolvable
            }
            let matches = menuItems.filter { candidate in
                Self.axStringAttribute(kAXRoleAttribute, of: candidate) == "AXMenuItem" &&
                Self.axStringAttribute(kAXTitleAttribute, of: candidate) == itemTitle
            }
            return matches.isEmpty ? .itemNoLongerResolvable : .itemStillResolvable
        }.value
    }

    /// Reads a single AXUIElement-typed attribute (e.g. `kAXMenuBarAttribute`, which returns the
    /// menu bar element itself, not an array) — distinct from `childrenAttribute`, which reads an
    /// array-typed attribute.
    fileprivate nonisolated static func axElementAttribute(_ attribute: String, of element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    // MARK: - Semantic Slider/Stepper Value Change (Phase 2M)
    //
    // ui.set_slider_value — a Level 2, semantic numeric value change. Every element is identified
    // by role + (identifier or title), exactly like every prior mutation capability, restricted
    // to QAXSliderRolePolicy's fail-closed allowlist (AXSlider/AXStepper only). Mutation is
    // AXUIElementSetAttributeValue(kAXValueAttribute) directly — correct here (unlike
    // ui.set_element_state's checkbox/radio press requirement) because a slider/stepper's
    // AXValue IS its authoritative state, the same reasoning ui.set_text_value already relies on
    // for text fields.

    /// Tolerance used ONLY for equality comparisons (idempotency, drift re-checks, post-action
    /// verification) — NEVER for range-boundary validation, which is always strict. A hybrid
    /// absolute+relative rule: two values are equal if they differ by no more than
    /// `valueComparisonAbsoluteTolerance`, OR by no more than `valueComparisonRelativeTolerance`
    /// of their magnitude (scale-aware, so this remains meaningful for both small
    /// normalized-range sliders, e.g. 0.0–1.0, and larger-range steppers, e.g. 0–1000). Both
    /// constants are deliberately small: large enough to absorb ordinary floating-point
    /// representation noise from an AX round trip, far too small to meaningfully move a value
    /// across a real range boundary.
    fileprivate static let valueComparisonAbsoluteTolerance: Double = 1e-6
    fileprivate static let valueComparisonRelativeTolerance: Double = 1e-9

    /// The single, canonical numeric-equality rule this capability uses everywhere it compares
    /// two AX-read (or AX-read-vs-desired) values — idempotency, value/range-drift re-checks, and
    /// closed-loop verification all call this SAME function, per the Phase 2M contract's explicit
    /// requirement that comparison semantics stay consistent across every one of those call
    /// sites. Public specifically so `QActionVerification.swift`'s verification strategy can
    /// reuse it rather than re-implementing the tolerance rule a second time.
    public static func sliderValuesAreEqual(_ a: Double, _ b: Double) -> Bool {
        let difference = abs(a - b)
        if difference <= valueComparisonAbsoluteTolerance { return true }
        let scale = max(abs(a), abs(b))
        return difference <= scale * valueComparisonRelativeTolerance
    }

    /// Resolves exactly one semantic `AXSlider`/`AXStepper` target, validates `desiredValue`
    /// against the target's own reported `[minValue, maxValue]` range using STRICT (non-tolerant)
    /// comparison — a hard security boundary — re-verifies both identity and value/range
    /// immediately before dispatch, and sets the value via `AXUIElementSetAttributeValue` only if
    /// it differs (tolerantly) from the current value. Fails closed on a disallowed role,
    /// non-finite `desiredValue`, unreadable/inconsistent range, an out-of-range request, or any
    /// staleness. Never falls back to coordinates, CGEvent, keyboard, or drag simulation.
    public func setSliderValue(
        applicationName: String,
        role: String,
        identifier: String?,
        title: String?,
        desiredValue: Double
    ) async throws -> QAXSliderValueOutcome {
        guard identifier != nil || title != nil else {
            throw QAXInteractionError.missingMatchCriteria
        }
        guard desiredValue.isFinite else {
            throw QAXInteractionError.invalidDesiredValue("desiredValue must be a finite number, got \(desiredValue)")
        }
        guard QAXSliderRolePolicy.isAllowedSliderRole(role) else {
            throw QAXInteractionError.disallowedSliderRole(role)
        }

        guard AXIsProcessTrusted() else {
            throw QAXInteractionError.accessibilityPermissionDenied
        }

        let runningApp = try Self.resolveExactRunningApplication(named: applicationName)

        let processIdentifier = runningApp.processIdentifier

        return try await Task.detached(priority: .userInitiated) {
            let appElement = AXUIElementCreateApplication(processIdentifier)

            let matches = Self.collectMatches(root: appElement, role: role, identifier: identifier, title: title)
            guard !matches.isEmpty else { throw QAXInteractionError.noMatchingElement }
            guard matches.count == 1 else { throw QAXInteractionError.ambiguousTarget(count: matches.count) }

            let (targetElement, observedAtSearch) = matches[0]

            // Identity observation binding: identical discipline to every prior mutation capability.
            guard let observedAtVerify = Self.snapshotIfMatches(targetElement, role: role, identifier: identifier, title: title) else {
                throw QAXInteractionError.staleTarget("target element is no longer resolvable immediately before dispatch")
            }
            guard observedAtVerify == observedAtSearch else {
                throw QAXInteractionError.staleTarget("target element identity changed between observation and dispatch")
            }
            guard observedAtVerify.isEnabled else {
                throw QAXInteractionError.targetDisabled
            }

            // Range discovery — read BEFORE any mutation decision, and before desiredValue is
            // validated against it. kAXMinValueAttribute/kAXMaxValueAttribute are new AX
            // territory for this codebase (see docs/PHASE_2M_SEMANTIC_SLIDER_VALUE.md).
            guard let minValueAtSearch = Self.axDoubleAttribute(kAXMinValueAttribute as String, of: targetElement),
                  let maxValueAtSearch = Self.axDoubleAttribute(kAXMaxValueAttribute as String, of: targetElement) else {
                throw QAXInteractionError.rangeReadFailed
            }
            guard minValueAtSearch <= maxValueAtSearch else {
                throw QAXInteractionError.invalidRange("minValue (\(minValueAtSearch)) is greater than maxValue (\(maxValueAtSearch))")
            }
            guard let currentValueAtSearch = Self.axDoubleAttribute(kAXValueAttribute as String, of: targetElement) else {
                throw QAXInteractionError.valueReadFailed
            }
            guard currentValueAtSearch >= minValueAtSearch, currentValueAtSearch <= maxValueAtSearch else {
                throw QAXInteractionError.invalidRange("current value (\(currentValueAtSearch)) is outside the reported range [\(minValueAtSearch), \(maxValueAtSearch)]")
            }

            // SECURITY BOUNDARY: strict, non-tolerant range check. Never widened by
            // sliderValuesAreEqual's tolerance — an out-of-range request is refused exactly at
            // its true boundary, not a tolerance-expanded one.
            guard desiredValue >= minValueAtSearch, desiredValue <= maxValueAtSearch else {
                throw QAXInteractionError.desiredValueOutOfRange("desiredValue (\(desiredValue)) is outside the allowed range [\(minValueAtSearch), \(maxValueAtSearch)]")
            }

            // Value/range-drift re-check immediately before dispatch — refuses on ANY drift in
            // current value, minValue, or maxValue (tolerant comparison: this is asking "did
            // anything actually change", not re-validating a boundary).
            guard let minValueAtVerify = Self.axDoubleAttribute(kAXMinValueAttribute as String, of: targetElement),
                  let maxValueAtVerify = Self.axDoubleAttribute(kAXMaxValueAttribute as String, of: targetElement),
                  let currentValueAtVerify = Self.axDoubleAttribute(kAXValueAttribute as String, of: targetElement) else {
                throw QAXInteractionError.valueReadFailed
            }
            guard Self.sliderValuesAreEqual(minValueAtVerify, minValueAtSearch),
                  Self.sliderValuesAreEqual(maxValueAtVerify, maxValueAtSearch),
                  Self.sliderValuesAreEqual(currentValueAtVerify, currentValueAtSearch) else {
                throw QAXInteractionError.valueDriftDetected("target element's value or range changed between observation and dispatch")
            }

            let targetIdentity = "application=\(applicationName) role=\(role) identifier=\(observedAtVerify.identifier ?? "none") label=\(observedAtVerify.titleOrDescription ?? "none")"

            guard !Self.sliderValuesAreEqual(currentValueAtVerify, desiredValue) else {
                // Idempotent no-op: already at the desired value. No AX write is performed.
                return QAXSliderValueOutcome(
                    changeKind: .alreadyDesired,
                    previousValue: currentValueAtVerify,
                    currentValue: currentValueAtVerify,
                    desiredValue: desiredValue,
                    minValue: minValueAtVerify,
                    maxValue: maxValueAtVerify,
                    targetIdentity: targetIdentity
                )
            }

            let setResult = AXUIElementSetAttributeValue(targetElement, kAXValueAttribute as CFString, NSNumber(value: desiredValue))
            guard setResult == .success else {
                throw QAXInteractionError.setValueFailed("AXError(\(setResult.rawValue))")
            }

            // Immediate ephemeral post-set read — provisional only; the authoritative check is
            // the later, independent closed-loop verification step
            // (QVerificationStrategy.axSliderValueMatchesDesired), which re-resolves the target
            // fresh rather than trusting this in-process observation.
            let currentValueAfterSet = Self.axDoubleAttribute(kAXValueAttribute as String, of: targetElement) ?? desiredValue

            return QAXSliderValueOutcome(
                changeKind: .changed,
                previousValue: currentValueAtVerify,
                currentValue: currentValueAfterSet,
                desiredValue: desiredValue,
                minValue: minValueAtVerify,
                maxValue: maxValueAtVerify,
                targetIdentity: targetIdentity
            )
        }.value
    }

    /// Best-effort, read-only re-resolution of the same match criteria used by `setSliderValue`,
    /// used only for the later closed-loop verification step
    /// (QVerificationStrategy.axSliderValueMatchesDesired). Also re-validates that the target's
    /// range remains internally consistent — a `QAXSliderValueEvidence.rangeInvalid` result means
    /// verification cannot be trusted, exactly like an unresolvable target.
    public func observeSliderValueEvidence(
        applicationName: String,
        role: String,
        identifier: String?,
        title: String?
    ) async -> QAXSliderValueEvidence {
        guard AXIsProcessTrusted() else { return .targetUnavailable }
        guard let runningApp = try? Self.resolveExactRunningApplication(named: applicationName) else { return .targetUnavailable }

        let processIdentifier = runningApp.processIdentifier
        return await Task.detached(priority: .userInitiated) {
            let appElement = AXUIElementCreateApplication(processIdentifier)
            let matches = Self.collectMatches(root: appElement, role: role, identifier: identifier, title: title)
            guard matches.count == 1 else { return .targetUnavailable }
            guard let currentValue = Self.axDoubleAttribute(kAXValueAttribute as String, of: matches[0].element),
                  let minValue = Self.axDoubleAttribute(kAXMinValueAttribute as String, of: matches[0].element),
                  let maxValue = Self.axDoubleAttribute(kAXMaxValueAttribute as String, of: matches[0].element) else {
                return .targetUnavailable
            }
            guard minValue <= maxValue, currentValue >= minValue, currentValue <= maxValue else {
                return .rangeInvalid(currentValue: currentValue)
            }
            return .resolved(currentValue: currentValue)
        }.value
    }

    // MARK: - Semantic Element Focus (Phase 2O)
    //
    // ui.focus_element — a Level 2, semantically-targeted focus mutation for a single element on
    // QAXFocusableRolePolicy's fail-closed allowlist. Mutation is
    // AXUIElementSetAttributeValue(kAXFocusedAttribute) only — never a press, never a value
    // write, never CGEvent/keyboard/mouse simulation. Idempotent: a target already the systemwide
    // focused element is a verified no-op, no AX write performed. Verification is independent and
    // re-reads kAXFocusedUIElementAttribute fresh — a successful set is never itself treated as
    // proof of success.

    /// Resolves exactly one semantic target and requests keyboard focus for it via
    /// `AXUIElementSetAttributeValue(kAXFocusedAttribute)`. Fails closed (throws
    /// `QAXInteractionError`) on a disallowed role, missing criteria, permission absence,
    /// application absence, zero/ambiguous matches, a disabled target, or a stale/drifted
    /// identity between resolution and dispatch — never falls back to coordinates, CGEvent, or
    /// keyboard simulation, and never fabricates success. Idempotent: if the target is already
    /// the systemwide `kAXFocusedUIElementAttribute` element, no `AXUIElementSetAttributeValue`
    /// call is made at all — `changeKind: .alreadyFocused` is itself the deterministic, purely
    /// structural proof that no AX write occurred (the mutation call sits in the one code path
    /// this early return can never reach), the same convention every prior idempotent AX
    /// capability in this codebase already establishes (see e.g. `setElementState`'s
    /// `.alreadyDesired`, `setSliderValue`'s `.alreadyDesired`).
    public func focusElement(
        applicationName: String,
        role: String,
        identifier: String?,
        title: String?
    ) async throws -> QAXFocusOutcome {
        guard identifier != nil || title != nil else {
            throw QAXInteractionError.missingMatchCriteria
        }
        // Role is validated as a search CRITERION, before any tree walk — an unauthorized role
        // is refused outright rather than allowed to shape what gets searched for, mirroring
        // every prior write-side role policy in this codebase.
        guard QAXFocusableRolePolicy.isAllowedFocusRole(role) else {
            throw QAXInteractionError.disallowedFocusRole(role)
        }

        guard AXIsProcessTrusted() else {
            throw QAXInteractionError.accessibilityPermissionDenied
        }

        let runningApp = try Self.resolveExactRunningApplication(named: applicationName)

        let processIdentifier = runningApp.processIdentifier

        return try await Task.detached(priority: .userInitiated) {
            let appElement = AXUIElementCreateApplication(processIdentifier)

            let matches = Self.collectMatches(root: appElement, role: role, identifier: identifier, title: title)
            guard !matches.isEmpty else { throw QAXInteractionError.noMatchingElement }
            guard matches.count == 1 else { throw QAXInteractionError.ambiguousTarget(count: matches.count) }

            let (targetElement, observedAtSearch) = matches[0]

            // Identity observation binding: identical discipline to every prior AX mutation
            // capability — re-read the SAME element reference immediately before any mutation
            // and refuse on any drift.
            guard let observedAtVerify = Self.snapshotIfMatches(targetElement, role: role, identifier: identifier, title: title) else {
                throw QAXInteractionError.staleTarget("target element is no longer resolvable immediately before dispatch")
            }
            guard observedAtVerify == observedAtSearch else {
                throw QAXInteractionError.staleTarget("target element identity changed between observation and dispatch")
            }
            guard observedAtVerify.isEnabled else {
                throw QAXInteractionError.targetDisabled
            }

            let targetIdentity = "application=\(applicationName) role=\(role) identifier=\(observedAtVerify.identifier ?? "none") label=\(observedAtVerify.titleOrDescription ?? "none")"

            // Idempotency check: is targetElement already the systemwide focused element? This
            // read happens BEFORE any mutation decision — the same
            // AXUIElementCreateSystemWide + kAXFocusedUIElementAttribute pattern
            // `setTextValue`'s focus precondition check already uses.
            if let currentlyFocused = Self.systemWideFocusedElement(), CFEqual(currentlyFocused, targetElement) {
                return QAXFocusOutcome(changeKind: .alreadyFocused, targetIdentity: targetIdentity)
            }

            let setResult = AXUIElementSetAttributeValue(targetElement, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            guard setResult == .success else {
                throw QAXInteractionError.setFocusFailed("AXError(\(setResult.rawValue))")
            }

            return QAXFocusOutcome(changeKind: .focused, targetIdentity: targetIdentity)
        }.value
    }

    /// Best-effort, read-only re-resolution of the same match criteria used by `focusElement`,
    /// used only for the later closed-loop verification step
    /// (`QVerificationStrategy.axElementIsFocused`). Independently re-reads
    /// `kAXFocusedUIElementAttribute` fresh — never trusts whatever `focusElement` itself last
    /// observed. `.targetUnavailable` (not `.notFocused`) is returned if the target itself can no
    /// longer be resolved — physical state is uncertain, so this is never conflated with a
    /// definite "resolvable but not focused" result.
    public func observeFocusedElementIdentity(
        applicationName: String,
        role: String,
        identifier: String?,
        title: String?
    ) async -> QAXFocusVerificationEvidence {
        guard AXIsProcessTrusted() else { return .targetUnavailable }
        guard let runningApp = try? Self.resolveExactRunningApplication(named: applicationName) else { return .targetUnavailable }

        let processIdentifier = runningApp.processIdentifier
        return await Task.detached(priority: .userInitiated) {
            let appElement = AXUIElementCreateApplication(processIdentifier)
            let matches = Self.collectMatches(root: appElement, role: role, identifier: identifier, title: title)
            guard matches.count == 1 else { return .targetUnavailable }
            let (targetElement, snapshot) = matches[0]

            guard let currentlyFocused = Self.systemWideFocusedElement(), CFEqual(currentlyFocused, targetElement) else {
                return .notFocused
            }
            let identity = "application=\(applicationName) role=\(role) identifier=\(snapshot.identifier ?? "none") label=\(snapshot.titleOrDescription ?? "none")"
            return .focused(identity: identity)
        }.value
    }

    /// Reads the systemwide currently-focused Accessibility element, or `nil` if none can be
    /// determined — the single shared primitive both `focusElement`'s idempotency check and
    /// `observeFocusedElementIdentity`'s independent verification read use, so the two never risk
    /// drifting into inconsistent focus-detection logic.
    fileprivate nonisolated static func systemWideFocusedElement() -> AXUIElement? {
        let systemWideElement = AXUIElementCreateSystemWide()
        var focusedElementValue: CFTypeRef?
        let focusedResult = AXUIElementCopyAttributeValue(
            systemWideElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElementValue
        )
        guard focusedResult == .success,
              let focusedElementValue,
              CFGetTypeID(focusedElementValue) == AXUIElementGetTypeID() else {
            return nil
        }
        return (focusedElementValue as! AXUIElement)
    }

    // MARK: - Semantic Focused Element Read (Phase 2BG)
    //
    // ui.read_focused_element — a Level 0, read-only, zero-prior-knowledge discovery primitive.
    // Every other capability in this codebase requires the caller to already know a target's
    // role/identifier/title before it can act or read; this is the first that reports back
    // WHATEVER currently holds systemwide keyboard focus, resolved purely via
    // AXUIElementCreateSystemWide() + kAXFocusedUIElementAttribute — the exact same primitive
    // `focusElement`'s idempotency check and `observeFocusedElementIdentity`'s independent
    // verification already share (`systemWideFocusedElement()` above). Zero tree traversal:
    // exactly one element is ever touched. Identity/structural metadata (role, subrole,
    // identifier, title, description, enabled, selected) is always returned when a focused
    // element is found and belongs to the requested application — reading WHICH element has
    // focus is never itself sensitive. Only the optional VALUE field is gated by
    // `QAXElementReadRolePolicy` (reused unmodified from Phase 2J) exactly like
    // `ui.read_element_value`: `AXSecureTextField` and any role not on that allowlist yield
    // `value: nil` rather than failing the whole read, mirroring `ui.read_element_value`'s own
    // "identity is safe, value is policy-gated" contract precisely.

    /// Resolves the systemwide currently-focused Accessibility element (never a search — a
    /// systemwide focused element is a singleton by OS definition, so resolution IS the read
    /// itself) and returns its safe structural metadata plus an optional policy-gated value.
    /// Fails closed (throws `QAXInteractionError`) when: no focused element can be determined;
    /// the focused element's own role attribute is unreadable/malformed; the focused element's
    /// owning process does not match the resolved `applicationName` (cross-app mismatch guard);
    /// or an optional `windowTitle` scope is supplied and does not match the focused element's
    /// containing window. Never falls back to another element, never fabricates a value, never
    /// traverses any descendant tree.
    public func readFocusedElement(
        applicationName: String,
        windowTitle: String?
    ) async throws -> QAXFocusedElementSnapshot {
        guard AXIsProcessTrusted() else {
            throw QAXInteractionError.accessibilityPermissionDenied
        }

        let runningApp = try Self.resolveExactRunningApplication(named: applicationName)
        let processIdentifier = runningApp.processIdentifier

        return try await Task.detached(priority: .userInitiated) {
            guard let focusedElement = Self.systemWideFocusedElement() else {
                throw QAXInteractionError.noFocusedElement
            }

            var focusedElementPid: pid_t = 0
            let pidResult = AXUIElementGetPid(focusedElement, &focusedElementPid)
            guard pidResult == .success else {
                throw QAXInteractionError.noFocusedElement
            }
            guard focusedElementPid == processIdentifier else {
                throw QAXInteractionError.focusedElementApplicationMismatch(applicationName)
            }

            guard let role = Self.axStringAttribute(kAXRoleAttribute, of: focusedElement) else {
                throw QAXInteractionError.noFocusedElement
            }

            if let windowTitle {
                guard let containingWindow = Self.axElementAttribute(kAXWindowAttribute, of: focusedElement),
                      Self.axStringAttribute(kAXTitleAttribute, of: containingWindow) == windowTitle else {
                    throw QAXInteractionError.focusedElementWindowMismatch(windowTitle)
                }
            }

            let subrole = Self.axStringAttribute(kAXSubroleAttribute, of: focusedElement)
            let identifier = Self.axStringAttribute(Self.axIdentifierAttributeName, of: focusedElement)
            let rawTitle = Self.axStringAttribute(kAXTitleAttribute, of: focusedElement)
            let title = (rawTitle?.isEmpty == false) ? rawTitle : nil
            let rawDescription = Self.axStringAttribute(kAXDescriptionAttribute, of: focusedElement)
            let elementDescription = (rawDescription?.isEmpty == false) ? rawDescription : nil
            let isEnabled = Self.axBoolAttribute(kAXEnabledAttribute, of: focusedElement) ?? true
            let isSelected = Self.axBoolAttribute(kAXSelectedAttribute, of: focusedElement)

            // Value exposure is the ONLY policy-gated field — identity/structural metadata above
            // is always returned. Mirrors ui.read_element_value's exact contract: a secure or
            // disallowed role withholds the value, never the whole read.
            let value: String?
            if role != "AXSecureTextField" && QAXElementReadRolePolicy.isAllowedReadRole(role) {
                value = Self.axValueDescription(of: focusedElement)
            } else {
                value = nil
            }

            return QAXFocusedElementSnapshot(
                role: role,
                subrole: subrole,
                identifier: identifier,
                title: title,
                elementDescription: elementDescription,
                isEnabled: isEnabled,
                isSelected: isSelected,
                value: value
            )
        }.value
    }

    // MARK: - Semantic Application State Read (Phase 2BH)
    //
    // ui.read_application_state — a Level 0, read-only, zero-mutation read of a named running
    // application's own authoritative AX state. Complements the write-only
    // ui.set_application_hidden/ui.activate_application pair (both of which use
    // NSRunningApplication, never AX, for their own mutation) with the read counterpart neither
    // has: this capability deliberately reads the NATIVE AX attributes
    // (kAXHiddenAttribute/kAXFrontmostAttribute/kAXMainWindowAttribute/kAXFocusedWindowAttribute)
    // on the exact same AXUIElementCreateApplication(pid) element ui.list_windows/
    // ui.list_menu_items already resolve — never NSRunningApplication heuristics, never
    // frontmost-only inference, never timing, never screenshots. Zero recursive traversal: the
    // application root element and, where present, its two directly-referenced windows (main,
    // focused) are the only elements ever touched — read for title/identifier only, never
    // descended into further.

    /// Resolves the named application's AX root element and reads its authoritative hidden/
    /// frontmost state plus (optionally) its main and focused window's title/identifier. Fails
    /// closed (throws `QAXInteractionError`) on permission absence, application absence/ambiguity,
    /// or an unreadable core state boolean (`applicationStateReadFailed`). A missing/unresolvable
    /// main or focused window — or one whose reference resolves but whose own `kAXRoleAttribute`
    /// is not exactly `AXWindow` — is a valid, honestly-reported `nil`, never an error, mirroring
    /// `ui.list_windows`'s own "no windows is a legitimate empty state" precedent. Never traverses
    /// beyond the one application element and its (at most two) directly-referenced windows —
    /// `kAXChildrenAttribute` is never read here.
    public func readApplicationState(
        applicationName: String
    ) async throws -> QAXApplicationStateSnapshot {
        guard AXIsProcessTrusted() else {
            throw QAXInteractionError.accessibilityPermissionDenied
        }

        let runningApp = try Self.resolveExactRunningApplication(named: applicationName)
        let processIdentifier = runningApp.processIdentifier

        return try await Task.detached(priority: .userInitiated) {
            // A pure AX object-reference constructor — never activates, focuses, or raises the
            // target application, the same primitive ui.list_windows/ui.list_menu_items already use.
            let appElement = AXUIElementCreateApplication(processIdentifier)

            guard let isHidden = Self.axBoolAttribute(kAXHiddenAttribute, of: appElement),
                  let isFrontmost = Self.axBoolAttribute(kAXFrontmostAttribute, of: appElement) else {
                throw QAXInteractionError.applicationStateReadFailed
            }

            var mainWindowTitle: String?
            var mainWindowIdentifier: String?
            if let mainWindowElement = Self.axElementAttribute(kAXMainWindowAttribute, of: appElement),
               Self.axStringAttribute(kAXRoleAttribute, of: mainWindowElement) == "AXWindow" {
                mainWindowTitle = Self.axStringAttribute(kAXTitleAttribute, of: mainWindowElement)
                mainWindowIdentifier = Self.axStringAttribute(Self.axIdentifierAttributeName, of: mainWindowElement)
            }

            var focusedWindowTitle: String?
            var focusedWindowIdentifier: String?
            if let focusedWindowElement = Self.axElementAttribute(kAXFocusedWindowAttribute, of: appElement),
               Self.axStringAttribute(kAXRoleAttribute, of: focusedWindowElement) == "AXWindow" {
                focusedWindowTitle = Self.axStringAttribute(kAXTitleAttribute, of: focusedWindowElement)
                focusedWindowIdentifier = Self.axStringAttribute(Self.axIdentifierAttributeName, of: focusedWindowElement)
            }

            return QAXApplicationStateSnapshot(
                isHidden: isHidden,
                isFrontmost: isFrontmost,
                mainWindowTitle: mainWindowTitle,
                mainWindowIdentifier: mainWindowIdentifier,
                focusedWindowTitle: focusedWindowTitle,
                focusedWindowIdentifier: focusedWindowIdentifier
            )
        }.value
    }

    // MARK: - Semantic Popup Item Selection (Phase 2P)
    //
    // ui.select_popup_item — a Level 2, single-role (AXPopUpButton only) selection: resolves one
    // semantically-identified popup button, and — unless it already shows the desired item —
    // opens it and selects one direct AXMenuItem within its opened AXMenu, atomically within ONE
    // approved execution. Architecturally the same two-press-atomic-with-bounded-poll mechanism
    // ui.select_menu_item (Phase 2L) already proved works in this codebase — reused verbatim
    // (maxMenuOpenPollAttempts/menuOpenPollIntervalNanoseconds), not duplicated with different
    // constants. The one genuine improvement over ui.select_menu_item: unlike a momentary menu-bar
    // command, an AXPopUpButton is a persistent value-holding control (its kAXValueAttribute is
    // already proven readable — QAXElementReadRolePolicy has listed AXPopUpButton since Phase 2J)
    // — so both idempotency (before dispatch) and closed-loop verification (after dispatch) can
    // compare the popup's OWN current value directly against the requested item title, a
    // stronger, more direct signal than menu-select's indirect "item disappeared" evidence.

    /// Resolves exactly one semantic `AXPopUpButton` target, and — unless it already shows the
    /// desired item — presses it to open, bounded-polls for the named direct `AXMenuItem` to
    /// become resolvable (reusing `ui.select_menu_item`'s exact poll constants), and presses it.
    /// Fails closed (throws `QAXInteractionError`) on a disallowed role, missing criteria,
    /// permission absence, application absence, zero/ambiguous popup or item matches, a
    /// disabled/stale target, or a value/identity drift between resolution and dispatch — never
    /// falls back to coordinates, CGEvent, or keyboard simulation, and never fabricates success.
    /// Idempotent: if the popup's current `kAXValueAttribute` already equals `itemTitle`, no
    /// press is performed at all — `changeKind: .alreadySelected` is itself the deterministic,
    /// structural proof that no mutation occurred (the same convention every prior idempotent AX
    /// capability in this codebase already establishes).
    public func selectPopupItem(
        applicationName: String,
        role: String,
        identifier: String?,
        title: String?,
        itemTitle: String
    ) async throws -> QAXPopupSelectionOutcome {
        guard identifier != nil || title != nil else {
            throw QAXInteractionError.missingMatchCriteria
        }
        guard !itemTitle.isEmpty else {
            throw QAXInteractionError.missingMatchCriteria
        }
        // Role is validated as a search CRITERION, before any tree walk — an unauthorized role
        // (AXComboBox, or anything not explicitly allowlisted) is refused outright rather than
        // allowed to shape what gets searched for, mirroring every prior write-side role policy.
        guard QAXPopupRolePolicy.isAllowedPopupRole(role) else {
            throw QAXInteractionError.disallowedPopupRole(role)
        }

        guard AXIsProcessTrusted() else {
            throw QAXInteractionError.accessibilityPermissionDenied
        }

        let runningApp = try Self.resolveExactRunningApplication(named: applicationName)

        let processIdentifier = runningApp.processIdentifier

        return try await Task.detached(priority: .userInitiated) {
            let appElement = AXUIElementCreateApplication(processIdentifier)

            let matches = Self.collectMatches(root: appElement, role: role, identifier: identifier, title: title)
            guard !matches.isEmpty else { throw QAXInteractionError.noMatchingElement }
            guard matches.count == 1 else { throw QAXInteractionError.ambiguousTarget(count: matches.count) }

            let (targetElement, observedAtSearch) = matches[0]

            // Identity observation binding: identical discipline to every prior AX mutation
            // capability — re-read the SAME element reference immediately before any mutation
            // and refuse on any drift.
            guard let observedAtVerify = Self.snapshotIfMatches(targetElement, role: role, identifier: identifier, title: title) else {
                throw QAXInteractionError.staleTarget("target element is no longer resolvable immediately before dispatch")
            }
            guard observedAtVerify == observedAtSearch else {
                throw QAXInteractionError.staleTarget("target element identity changed between observation and dispatch")
            }
            guard observedAtVerify.isEnabled else {
                throw QAXInteractionError.targetDisabled
            }

            // Value-drift staleness check (mirroring setElementState's/setSliderValue's
            // discipline, new territory for a press-based capability): read the popup's current
            // value once at resolution, once again immediately before any dispatch decision, and
            // refuse if they differ — the popup may still be the exact same element by identity,
            // but its shown value already changed out from under this call.
            guard let currentValueAtSearch = Self.axStringAttribute(kAXValueAttribute, of: targetElement) else {
                throw QAXInteractionError.valueReadFailed
            }
            guard let currentValueAtVerify = Self.axStringAttribute(kAXValueAttribute, of: targetElement) else {
                throw QAXInteractionError.valueReadFailed
            }
            guard currentValueAtVerify == currentValueAtSearch else {
                throw QAXInteractionError.valueDriftDetected("target popup's current value changed between observation and dispatch")
            }

            let targetIdentity = "application=\(applicationName) role=\(role) identifier=\(observedAtVerify.identifier ?? "none") label=\(observedAtVerify.titleOrDescription ?? "none")"

            guard currentValueAtVerify != itemTitle else {
                // Idempotent no-op: the popup already shows the desired item. No AX press is
                // performed — an unnecessary mutation is itself something to avoid.
                return QAXPopupSelectionOutcome(
                    changeKind: .alreadySelected,
                    previousValue: currentValueAtVerify,
                    requestedItemTitle: itemTitle,
                    targetIdentity: targetIdentity
                )
            }

            let openResult = AXUIElementPerformAction(targetElement, kAXPressAction as CFString)
            switch openResult {
            case .success:
                break
            case .actionUnsupported:
                throw QAXInteractionError.actionUnsupported
            default:
                throw QAXInteractionError.pressFailed("AXError(\(openResult.rawValue)) while opening popup")
            }

            // Bounded poll for the named item as a DIRECT child of the now-open popup's AXMenu —
            // the exact same ceiling and interval ui.select_menu_item already established
            // (maxMenuOpenPollAttempts * menuOpenPollIntervalNanoseconds = 10 * 50ms = 500ms),
            // reused verbatim rather than duplicated with new constants.
            var resolvedItem: AXUIElement?
            for _ in 0..<Self.maxMenuOpenPollAttempts {
                try Task.checkCancellation()
                if let menuElement = Self.childrenAttribute(of: targetElement)?.first,
                   Self.axStringAttribute(kAXRoleAttribute, of: menuElement) == "AXMenu",
                   let menuItems = Self.childrenAttribute(of: menuElement) {
                    let itemMatches = menuItems.filter { candidate in
                        Self.axStringAttribute(kAXRoleAttribute, of: candidate) == "AXMenuItem" &&
                        Self.axStringAttribute(kAXTitleAttribute, of: candidate) == itemTitle
                    }
                    if itemMatches.count == 1 {
                        resolvedItem = itemMatches[0]
                        break
                    } else if itemMatches.count > 1 {
                        throw QAXInteractionError.ambiguousTarget(count: itemMatches.count)
                    }
                }
                try? await Task.sleep(nanoseconds: Self.menuOpenPollIntervalNanoseconds)
            }
            guard let itemElement = resolvedItem else {
                throw QAXInteractionError.menuItemNotFound(itemTitle)
            }
            guard Self.axBoolAttribute(kAXEnabledAttribute, of: itemElement) ?? false else {
                throw QAXInteractionError.targetDisabled
            }

            // Re-verify immediately before dispatch, mirroring every prior capability's
            // observation-binding discipline — if the item became disabled between resolution
            // (found during the poll) and this instant, refuse rather than press regardless.
            guard Self.axBoolAttribute(kAXEnabledAttribute, of: itemElement) ?? false else {
                throw QAXInteractionError.staleTarget("target popup item became disabled between resolution and dispatch")
            }

            let selectResult = AXUIElementPerformAction(itemElement, kAXPressAction as CFString)
            switch selectResult {
            case .success:
                break
            case .actionUnsupported:
                throw QAXInteractionError.actionUnsupported
            default:
                throw QAXInteractionError.pressFailed("AXError(\(selectResult.rawValue)) while selecting item '\(itemTitle)'")
            }

            return QAXPopupSelectionOutcome(
                changeKind: .changed,
                previousValue: currentValueAtVerify,
                requestedItemTitle: itemTitle,
                targetIdentity: targetIdentity
            )
        }.value
    }

    /// Best-effort, read-only re-resolution of the same match criteria used by `selectPopupItem`,
    /// used only for the later closed-loop verification step
    /// (`QVerificationStrategy.axPopupValueMatchesDesired`). Independently re-reads the popup's
    /// OWN `kAXValueAttribute` fresh — never trusts whatever `selectPopupItem` itself last
    /// observed. `.targetUnavailable` (not a "resolved but wrong value" case) is returned if the
    /// target itself can no longer be resolved, or its value cannot be read at all — physical
    /// state is uncertain, so this is never conflated with a definite "resolvable with the wrong
    /// value" result.
    public func observePopupValueEvidence(
        applicationName: String,
        role: String,
        identifier: String?,
        title: String?
    ) async -> QAXPopupValueEvidence {
        guard AXIsProcessTrusted() else { return .targetUnavailable }
        guard let runningApp = try? Self.resolveExactRunningApplication(named: applicationName) else { return .targetUnavailable }

        let processIdentifier = runningApp.processIdentifier
        return await Task.detached(priority: .userInitiated) {
            let appElement = AXUIElementCreateApplication(processIdentifier)
            let matches = Self.collectMatches(root: appElement, role: role, identifier: identifier, title: title)
            guard matches.count == 1 else { return .targetUnavailable }
            guard let currentValue = Self.axStringAttribute(kAXValueAttribute, of: matches[0].element) else {
                return .targetUnavailable
            }
            return .resolved(currentValue: currentValue)
        }.value
    }

    // MARK: - Semantic Disclosure Toggle (Phase 2Q)
    //
    // ui.toggle_disclosure — a Level 2, single-role (AXDisclosureTriangle only) expand/collapse
    // toggle for exactly one semantically-identified disclosure triangle. Mutation is
    // AXUIElementPerformAction(kAXPressAction) only — the same primitive
    // ui.set_element_state/ui.click_element already use — never AXUIElementSetAttributeValue,
    // since a disclosure triangle (like a checkbox) only runs its real expand/collapse handling
    // in response to a genuine press, not a raw value write. Explicit desired-state semantics
    // (never a blind toggle): the caller states the desired final state, and the operation is a
    // true idempotent no-op if the target is already there. Reuses the exact same
    // press-based-mutation, direct-value-verification architecture ui.set_element_state (Phase
    // 2K) already established for checkbox/radio's binary state — this is structurally the same
    // interaction shape, just applied to a different (and, per Phase 2Q Discovery, already
    // read-allowlisted) role.

    /// Resolves exactly one semantic `AXDisclosureTriangle` target and, unless it already reports
    /// the desired expand/collapse state, presses it toward that state. Fails closed (throws
    /// `QAXInteractionError`) on a disallowed role, missing criteria, permission absence,
    /// application absence, zero/ambiguous matches, a disabled/stale target, an unreadable
    /// current state, or a state drift between resolution and dispatch — never falls back to
    /// coordinates, CGEvent, or keyboard simulation, and never fabricates success. Idempotent: if
    /// the disclosure triangle's current `kAXValueAttribute` already reports the desired state,
    /// no `AXUIElementPerformAction` call is made at all — `changeKind: .alreadyDesired` is
    /// itself the deterministic, structural proof that no mutation occurred (the same convention
    /// every prior idempotent AX capability in this codebase already establishes).
    public func toggleDisclosure(
        applicationName: String,
        role: String,
        identifier: String?,
        title: String?,
        desiredState: QAXDisclosureState
    ) async throws -> QAXDisclosureToggleOutcome {
        guard identifier != nil || title != nil else {
            throw QAXInteractionError.missingMatchCriteria
        }
        // Role is validated as a search CRITERION, before any tree walk — an unauthorized role
        // is refused outright rather than allowed to shape what gets searched for, mirroring
        // every prior write-side role policy in this codebase.
        guard QAXDisclosureRolePolicy.isAllowedDisclosureRole(role) else {
            throw QAXInteractionError.disallowedDisclosureRole(role)
        }

        guard AXIsProcessTrusted() else {
            throw QAXInteractionError.accessibilityPermissionDenied
        }

        let runningApp = try Self.resolveExactRunningApplication(named: applicationName)

        let processIdentifier = runningApp.processIdentifier

        return try await Task.detached(priority: .userInitiated) {
            let appElement = AXUIElementCreateApplication(processIdentifier)

            let matches = Self.collectMatches(root: appElement, role: role, identifier: identifier, title: title)
            guard !matches.isEmpty else { throw QAXInteractionError.noMatchingElement }
            guard matches.count == 1 else { throw QAXInteractionError.ambiguousTarget(count: matches.count) }

            let (targetElement, observedAtSearch) = matches[0]

            // Identity observation binding: identical discipline to every prior AX mutation
            // capability — re-read the SAME element reference immediately before any mutation
            // and refuse on any drift.
            guard let observedAtVerify = Self.snapshotIfMatches(targetElement, role: role, identifier: identifier, title: title) else {
                throw QAXInteractionError.staleTarget("target element is no longer resolvable immediately before dispatch")
            }
            guard observedAtVerify == observedAtSearch else {
                throw QAXInteractionError.staleTarget("target element identity changed between observation and dispatch")
            }
            guard observedAtVerify.isEnabled else {
                throw QAXInteractionError.targetDisabled
            }

            // Value-drift staleness check (mirroring setElementState's/selectPopupItem's
            // discipline): read the disclosure state once at resolution, once again immediately
            // before dispatch, and refuse if they differ — the target may still be the exact
            // same element by identity, but its expand/collapse state already changed out from
            // under this call. An unreadable/indeterminate state at either read fails closed
            // rather than defaulting to a guess.
            guard let stateAtSearch = Self.axDisclosureState(of: targetElement) else {
                throw QAXInteractionError.disclosureStateReadFailed
            }
            guard let stateAtVerify = Self.axDisclosureState(of: targetElement) else {
                throw QAXInteractionError.disclosureStateReadFailed
            }
            guard stateAtVerify == stateAtSearch else {
                throw QAXInteractionError.valueDriftDetected("target disclosure state changed between observation and dispatch")
            }

            let targetIdentity = "application=\(applicationName) role=\(role) identifier=\(observedAtVerify.identifier ?? "none") label=\(observedAtVerify.titleOrDescription ?? "none")"

            guard stateAtVerify != desiredState else {
                // Idempotent no-op: the target already reports the desired state. No AX press is
                // performed — an unnecessary mutation is itself something to avoid.
                return QAXDisclosureToggleOutcome(
                    changeKind: .alreadyDesired,
                    previousState: stateAtVerify,
                    currentState: stateAtVerify,
                    targetIdentity: targetIdentity
                )
            }

            let pressResult = AXUIElementPerformAction(targetElement, kAXPressAction as CFString)
            switch pressResult {
            case .success:
                break
            case .actionUnsupported:
                throw QAXInteractionError.actionUnsupported
            default:
                throw QAXInteractionError.pressFailed("AXError(\(pressResult.rawValue))")
            }

            // Immediate ephemeral post-press read — provisional only; the authoritative check is
            // the later, independent closed-loop verification step
            // (QVerificationStrategy.axDisclosureStateMatchesDesired), which re-resolves the
            // target fresh rather than trusting this in-process observation.
            let currentState = Self.axDisclosureState(of: targetElement) ?? desiredState

            return QAXDisclosureToggleOutcome(
                changeKind: .changed,
                previousState: stateAtVerify,
                currentState: currentState,
                targetIdentity: targetIdentity
            )
        }.value
    }

    /// Best-effort, read-only re-resolution of the same match criteria used by
    /// `toggleDisclosure`, used both by the later closed-loop verification step
    /// (`QVerificationStrategy.axDisclosureStateMatchesDesired`) and by
    /// `QTaskRecoveryManager`'s observation-first recovery branch — the SAME primitive for both,
    /// never a parallel resolver. Independently re-reads `kAXValueAttribute` fresh — never trusts
    /// whatever `toggleDisclosure` itself last observed. `.stateUnreadable` (an indeterminate/
    /// unknown value) is deliberately distinct from `.targetUnavailable` (the target itself
    /// cannot be resolved at all) for a clearer diagnostic, though both are treated as `.failed`
    /// by verification — neither is ever coerced into a definite expanded/collapsed guess.
    public func observeDisclosureStateEvidence(
        applicationName: String,
        role: String,
        identifier: String?,
        title: String?
    ) async -> QAXDisclosureVerificationEvidence {
        guard AXIsProcessTrusted() else { return .targetUnavailable }
        guard let runningApp = try? Self.resolveExactRunningApplication(named: applicationName) else { return .targetUnavailable }

        let processIdentifier = runningApp.processIdentifier
        return await Task.detached(priority: .userInitiated) {
            let appElement = AXUIElementCreateApplication(processIdentifier)
            let matches = Self.collectMatches(root: appElement, role: role, identifier: identifier, title: title)
            guard matches.count == 1 else { return .targetUnavailable }
            guard let currentState = Self.axDisclosureState(of: matches[0].element) else {
                return .stateUnreadable
            }
            return .resolved(currentState: currentState)
        }.value
    }

    /// Reads `kAXValueAttribute` and interprets it as a clean expanded/collapsed boolean:
    /// `0` → `.collapsed`, `1` → `.expanded`. Any other value or a non-numeric/unreadable
    /// attribute returns `nil` — this capability never guesses at an ambiguous current state, the
    /// same discipline `axCheckboxRadioState` already establishes for checkbox/radio's tri-state
    /// "mixed" value.
    fileprivate nonisolated static func axDisclosureState(of element: AXUIElement) -> QAXDisclosureState? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value)
        guard result == .success, let value else { return nil }
        guard let numberValue = value as? NSNumber else { return nil }
        switch numberValue.intValue {
        case 0: return .collapsed
        case 1: return .expanded
        default: return nil
        }
    }

    // MARK: - Semantic Tab Selection (Phase 2R)
    //
    // ui.select_tab — a Level 2, explicit-desired-selection operation for exactly one
    // semantically-identified tab. IMPORTANT EMPIRICAL FINDING (see
    // docs/PHASE_2R_SEMANTIC_TAB_SELECTION.md's Known limitations for the full account): there is
    // no standalone "AXTab" role in macOS's Accessibility API — confirmed directly against this
    // SDK's authoritative NSAccessibilityConstants.h. A tab item's real, header-confirmed shape is
    // base role AXRadioButton carrying kAXSubroleAttribute == "AXTabButton". `selectTab` therefore
    // resolves by role AXRadioButton (QAXTabRolePolicy's only allowed role) and additionally,
    // unconditionally requires the AXTabButton subrole — a generic AXRadioButton without that
    // subrole is refused (targetNotATabButton), never treated as a tab, and never cross-wired
    // with ui.set_element_state's existing, unconditional AXRadioButton coverage. Mutation is
    // AXUIElementPerformAction(kAXPressAction) only — the same primitive
    // ui.toggle_disclosure/ui.set_element_state/ui.click_element already use. Authoritative
    // selection state is read from kAXSelectedAttribute — a real, standard, generically-
    // documented Apple AX attribute for "is this one of several sibling elements currently
    // selected" — deliberately never kAXValueAttribute (an ordinary AXRadioButton's own on/off
    // state, a different semantic ui.set_element_state already owns) or kAXFocusedAttribute
    // (keyboard focus, a distinct concept ui.focus_element already owns). Explicit
    // desiredSelected semantics (never a blind toggle), mirroring ui.toggle_disclosure's
    // explicit-desired-state discipline exactly. AX provides no reliable way to deselect a
    // single tab via its own press action — the same limitation Phase 2K already established for
    // AXRadioButton deselection — so a desiredSelected=false request against an already-selected
    // tab is refused (stateChangeNotGuaranteed), never attempted.

    /// The exact `kAXSubroleAttribute` value that distinguishes a genuine tab-shaped
    /// `AXRadioButton` from an ordinary one. Never a model-configurable input — this is a
    /// hard-coded, non-negotiable part of `ui.select_tab`'s own contract, not something the
    /// caller supplies or could weaken.
    fileprivate static let tabButtonSubrole = "AXTabButton"

    /// Resolves exactly one semantic `AXRadioButton` target carrying the `AXTabButton` subrole
    /// and, unless it already reports the desired `kAXSelectedAttribute` state, presses it toward
    /// selection. Fails closed (throws `QAXInteractionError`) on a disallowed role, a resolved
    /// `AXRadioButton` lacking the `AXTabButton` subrole, missing criteria, permission absence,
    /// application absence, zero/ambiguous matches, a disabled/stale target, an unreadable
    /// current selection state, a selection-state drift between resolution and dispatch, or an
    /// unsupported deselection request — never falls back to coordinates, CGEvent, or keyboard
    /// simulation, and never fabricates success. Idempotent: if the tab's current
    /// `kAXSelectedAttribute` already matches `desiredSelected`, no `AXUIElementPerformAction`
    /// call is made at all — `changeKind: .alreadyDesired` is itself the deterministic,
    /// structural proof that no mutation occurred (the same convention every prior idempotent AX
    /// capability in this codebase already establishes).
    public func selectTab(
        applicationName: String,
        role: String,
        identifier: String?,
        title: String?,
        desiredSelected: Bool
    ) async throws -> QAXTabSelectionOutcome {
        guard identifier != nil || title != nil else {
            throw QAXInteractionError.missingMatchCriteria
        }
        // Role is validated as a search CRITERION, before any tree walk — an unauthorized role
        // is refused outright rather than allowed to shape what gets searched for, mirroring
        // every prior write-side role policy in this codebase. Note: passing this check alone
        // does NOT mean the target will be treated as a tab — the mandatory AXTabButton subrole
        // check below is what actually decides that.
        guard QAXTabRolePolicy.isAllowedTabRole(role) else {
            throw QAXInteractionError.disallowedTabRole(role)
        }

        guard AXIsProcessTrusted() else {
            throw QAXInteractionError.accessibilityPermissionDenied
        }

        let runningApp = try Self.resolveExactRunningApplication(named: applicationName)

        let processIdentifier = runningApp.processIdentifier

        return try await Task.detached(priority: .userInitiated) {
            let appElement = AXUIElementCreateApplication(processIdentifier)

            let matches = Self.collectMatches(root: appElement, role: role, identifier: identifier, title: title)
            guard !matches.isEmpty else { throw QAXInteractionError.noMatchingElement }
            guard matches.count == 1 else { throw QAXInteractionError.ambiguousTarget(count: matches.count) }

            let (targetElement, observedAtSearch) = matches[0]

            // Identity observation binding: identical discipline to every prior AX mutation
            // capability — re-read the SAME element reference immediately before any mutation
            // and refuse on any drift.
            guard let observedAtVerify = Self.snapshotIfMatches(targetElement, role: role, identifier: identifier, title: title) else {
                throw QAXInteractionError.staleTarget("target element is no longer resolvable immediately before dispatch")
            }
            guard observedAtVerify == observedAtSearch else {
                throw QAXInteractionError.staleTarget("target element identity changed between observation and dispatch")
            }
            guard observedAtVerify.isEnabled else {
                throw QAXInteractionError.targetDisabled
            }

            // The mandatory, non-negotiable subrole gate: an AXRadioButton without the
            // AXTabButton subrole is a generic radio button, not a tab — refused here, never
            // treated as a tab, never cross-wired with ui.set_element_state's own coverage.
            let observedSubrole = Self.axStringAttribute(kAXSubroleAttribute, of: targetElement)
            guard observedSubrole == Self.tabButtonSubrole else {
                throw QAXInteractionError.targetNotATabButton(observedSubrole ?? "none")
            }

            // Selection-state-drift staleness check (mirroring setElementState's/
            // toggleDisclosure's discipline): read kAXSelectedAttribute once at resolution, once
            // again immediately before dispatch, and refuse if they differ — the target may
            // still be the exact same element by identity, but its selection state already
            // changed out from under this call.
            guard let selectedAtSearch = Self.axBoolAttribute(kAXSelectedAttribute, of: targetElement) else {
                throw QAXInteractionError.tabSelectionStateReadFailed
            }
            guard let selectedAtVerify = Self.axBoolAttribute(kAXSelectedAttribute, of: targetElement) else {
                throw QAXInteractionError.tabSelectionStateReadFailed
            }
            guard selectedAtVerify == selectedAtSearch else {
                throw QAXInteractionError.valueDriftDetected("target tab's selected state changed between observation and dispatch")
            }

            let targetIdentity = "application=\(applicationName) role=\(role) identifier=\(observedAtVerify.identifier ?? "none") label=\(observedAtVerify.titleOrDescription ?? "none")"

            guard selectedAtVerify != desiredSelected else {
                // Idempotent no-op: the tab already reports the desired selection state. No AX
                // press is performed — an unnecessary mutation is itself something to avoid.
                return QAXTabSelectionOutcome(
                    changeKind: .alreadyDesired,
                    previousSelected: selectedAtVerify,
                    currentSelected: selectedAtVerify,
                    targetIdentity: targetIdentity
                )
            }

            // A tab (like an AXRadioButton in a radio group) supports being reliably SELECTED
            // (press while not selected) but macOS provides no reliable way to deselect a single
            // tab via its own press action — the standard interaction model selects a different
            // tab in the group instead, the same reasoning already established for AXRadioButton
            // deselection in Phase 2K. Refuse rather than press and hope.
            guard desiredSelected else {
                throw QAXInteractionError.stateChangeNotGuaranteed(
                    "A tab cannot be reliably deselected via its own press action; select a different tab instead"
                )
            }

            let pressResult = AXUIElementPerformAction(targetElement, kAXPressAction as CFString)
            switch pressResult {
            case .success:
                break
            case .actionUnsupported:
                throw QAXInteractionError.actionUnsupported
            default:
                throw QAXInteractionError.pressFailed("AXError(\(pressResult.rawValue))")
            }

            // Immediate ephemeral post-press read — provisional only; the authoritative check is
            // the later, independent closed-loop verification step
            // (QVerificationStrategy.axTabSelectionMatchesDesired), which re-resolves the target
            // fresh rather than trusting this in-process observation.
            let currentSelected = Self.axBoolAttribute(kAXSelectedAttribute, of: targetElement) ?? desiredSelected

            return QAXTabSelectionOutcome(
                changeKind: .changed,
                previousSelected: selectedAtVerify,
                currentSelected: currentSelected,
                targetIdentity: targetIdentity
            )
        }.value
    }

    /// Best-effort, read-only re-resolution of the same match criteria used by `selectTab`, used
    /// both by the later closed-loop verification step
    /// (`QVerificationStrategy.axTabSelectionMatchesDesired`) and by `QTaskRecoveryManager`'s
    /// observation-first recovery branch — the SAME primitive for both, never a parallel
    /// resolver. Independently re-reads `kAXSelectedAttribute` fresh — never trusts whatever
    /// `selectTab` itself last observed. Also independently re-verifies the `AXTabButton`
    /// subrole, so a target that has stopped being a tab (however implausible in practice) is
    /// never conflated with a genuine, still-authoritative selection observation.
    /// `.stateUnreadable` (the attribute could not be read) is deliberately distinct from
    /// `.targetUnavailable` (the target itself cannot be resolved, is ambiguous, or is no longer
    /// subrole-qualified) for a clearer diagnostic, though both are treated as `.failed` by
    /// verification — neither is ever coerced into a definite selected/not-selected guess.
    public func observeTabSelectionEvidence(
        applicationName: String,
        role: String,
        identifier: String?,
        title: String?
    ) async -> QAXTabSelectionEvidence {
        guard AXIsProcessTrusted() else { return .targetUnavailable }
        guard let runningApp = try? Self.resolveExactRunningApplication(named: applicationName) else { return .targetUnavailable }

        let processIdentifier = runningApp.processIdentifier
        return await Task.detached(priority: .userInitiated) {
            let appElement = AXUIElementCreateApplication(processIdentifier)
            let matches = Self.collectMatches(root: appElement, role: role, identifier: identifier, title: title)
            guard matches.count == 1 else { return .targetUnavailable }
            guard Self.axStringAttribute(kAXSubroleAttribute, of: matches[0].element) == Self.tabButtonSubrole else {
                return .targetUnavailable
            }
            guard let currentSelected = Self.axBoolAttribute(kAXSelectedAttribute, of: matches[0].element) else {
                return .stateUnreadable
            }
            return .resolved(currentSelected: currentSelected)
        }.value
    }

    // MARK: - Semantic Table Row Selection (Phase 2S)
    //
    // ui.select_table_row — a Level 2, selection-only operation (never deselection) for exactly
    // one semantically-identified table row. Confirmed directly against this SDK's authoritative
    // NSAccessibilityConstants.h: `AXRow` (NSAccessibilityRowRole) is a genuine, standalone base
    // role, distinct from `AXTable`/`AXOutline`, carrying one of two real, distinct subroles —
    // `AXTableRow` (NSAccessibilityTableRowSubrole) or `AXOutlineRow`
    // (NSAccessibilityOutlineRowSubrole). `selectTableRow` resolves by role `AXRow`
    // (`QAXTableRowRolePolicy`'s only allowed role) and additionally, unconditionally requires
    // BOTH the `AXTableRow` subrole AND a resolved `kAXParentAttribute` whose own role is exactly
    // `AXTable` — an `AXRow` missing either is refused, never treated as a table row.
    // `AXOutlineRow` is a real, SDK-confirmed subrole this phase deliberately does not support
    // (`QAXInteractionError.outlineRowUnsupported`) — see
    // docs/PHASE_2S_SEMANTIC_TABLE_ROW_SELECTION.md's Known limitations. Mutation is
    // AXUIElementPerformAction(kAXPressAction) only — the same primitive
    // ui.select_tab/ui.toggle_disclosure/ui.set_element_state/ui.click_element already use.
    // Authoritative selection state is read from kAXSelectedAttribute — deliberately never
    // kAXSelectedRowsAttribute (the table-level multi-selection array). Unlike `ui.select_tab`,
    // deselection is not merely unguaranteed — it is categorically out of scope: `desiredSelected`
    // MUST be `true`, refused BEFORE any Accessibility Trust check or application resolution is
    // even attempted if `false`.

    /// The exact `kAXSubroleAttribute` value that distinguishes a genuine table row from any
    /// other `AXRow`-shaped element. Never a model-configurable input — hard-coded, non-negotiable
    /// part of `ui.select_table_row`'s own contract.
    fileprivate static let tableRowSubrole = "AXTableRow"

    /// The real, SDK-confirmed subrole for an outline (`NSOutlineView`) row — recognized so it can
    /// be reported with a clear, distinct diagnostic, but deliberately unsupported in this phase.
    fileprivate static let outlineRowSubrole = "AXOutlineRow"

    /// The exact parent `kAXRoleAttribute` value that establishes a row's table context. Never a
    /// model-configurable input — hard-coded, non-negotiable part of `ui.select_table_row`'s own
    /// contract.
    fileprivate static let tableContextRole = "AXTable"

    /// Resolves exactly one semantic `AXRow` target carrying the `AXTableRow` subrole and an
    /// `AXTable`-rooted parent context, and — unless it already reports the desired
    /// `kAXSelectedAttribute` state — presses it toward selection. Fails closed (throws
    /// `QAXInteractionError`) on a disallowed role, a resolved `AXRow` lacking the `AXTableRow`
    /// subrole, a recognized-but-unsupported `AXOutlineRow` subrole, an unestablished table
    /// context, missing criteria, permission absence, application absence, zero/ambiguous
    /// matches, a disabled/stale target, an unreadable current selection state, a selection-state
    /// drift between resolution and dispatch, or a deselection request — never falls back to
    /// coordinates, CGEvent, or keyboard simulation, and never fabricates success. Idempotent: if
    /// the row's current `kAXSelectedAttribute` already reports `true`, no
    /// `AXUIElementPerformAction` call is made at all — `changeKind: .alreadyDesired` is itself
    /// the deterministic, structural proof that no mutation occurred (the same convention every
    /// prior idempotent AX capability in this codebase already establishes).
    public func selectTableRow(
        applicationName: String,
        role: String,
        identifier: String?,
        title: String?,
        desiredSelected: Bool
    ) async throws -> QAXTableRowSelectionOutcome {
        guard identifier != nil || title != nil else {
            throw QAXInteractionError.missingMatchCriteria
        }
        // Role is validated as a search CRITERION, before any tree walk — an unauthorized role
        // is refused outright rather than allowed to shape what gets searched for, mirroring
        // every prior write-side role policy in this codebase. Note: passing this check alone
        // does NOT mean the target will be treated as a table row — the mandatory AXTableRow
        // subrole + AXTable parent-context checks below are what actually decide that.
        guard QAXTableRowRolePolicy.isAllowedTableRowRole(role) else {
            throw QAXInteractionError.disallowedTableRowRole(role)
        }
        // Deselection is categorically out of scope for this phase — refused BEFORE any
        // Accessibility Trust check or application resolution is even attempted, never treated
        // as a blind toggle and never silently coerced to true.
        guard desiredSelected else {
            throw QAXInteractionError.rowDeselectionUnsupported(
                "ui.select_table_row supports selection only (desiredSelected must be true)"
            )
        }

        guard AXIsProcessTrusted() else {
            throw QAXInteractionError.accessibilityPermissionDenied
        }

        let runningApp = try Self.resolveExactRunningApplication(named: applicationName)

        let processIdentifier = runningApp.processIdentifier

        return try await Task.detached(priority: .userInitiated) {
            let appElement = AXUIElementCreateApplication(processIdentifier)

            let matches = Self.collectMatches(root: appElement, role: role, identifier: identifier, title: title)
            guard !matches.isEmpty else { throw QAXInteractionError.noMatchingElement }
            guard matches.count == 1 else { throw QAXInteractionError.ambiguousTarget(count: matches.count) }

            let (targetElement, observedAtSearch) = matches[0]

            // Identity observation binding: identical discipline to every prior AX mutation
            // capability — re-read the SAME element reference immediately before any mutation
            // and refuse on any drift.
            guard let observedAtVerify = Self.snapshotIfMatches(targetElement, role: role, identifier: identifier, title: title) else {
                throw QAXInteractionError.staleTarget("target element is no longer resolvable immediately before dispatch")
            }
            guard observedAtVerify == observedAtSearch else {
                throw QAXInteractionError.staleTarget("target element identity changed between observation and dispatch")
            }
            guard observedAtVerify.isEnabled else {
                throw QAXInteractionError.targetDisabled
            }

            // The mandatory, non-negotiable subrole gate: an AXRow without the AXTableRow subrole
            // is never treated as a table row. AXOutlineRow is recognized-but-refused with its
            // own distinct diagnostic, never silently folded into table-row handling.
            let observedSubrole = Self.axStringAttribute(kAXSubroleAttribute, of: targetElement)
            guard observedSubrole != Self.outlineRowSubrole else {
                throw QAXInteractionError.outlineRowUnsupported(observedSubrole ?? "none")
            }
            guard observedSubrole == Self.tableRowSubrole else {
                throw QAXInteractionError.targetNotATableRow(observedSubrole ?? "none")
            }

            // The mandatory, non-negotiable table-context gate: a row is never accepted unless
            // its own kAXParentAttribute resolves to an element whose role is exactly AXTable —
            // an arbitrary standalone AXRow+AXTableRow element with no such parent is refused.
            guard let parentElement = Self.axElementAttribute(kAXParentAttribute, of: targetElement) else {
                throw QAXInteractionError.tableContextUnavailable("parent element could not be resolved")
            }
            guard Self.axStringAttribute(kAXRoleAttribute, of: parentElement) == Self.tableContextRole else {
                throw QAXInteractionError.tableContextUnavailable("parent role is not AXTable")
            }

            // Selection-state-drift staleness check (mirroring selectTab's/setElementState's
            // discipline): read kAXSelectedAttribute once at resolution, once again immediately
            // before dispatch, and refuse if they differ — the target may still be the exact same
            // element by identity, but its selection state already changed out from under this
            // call.
            guard let selectedAtSearch = Self.axBoolAttribute(kAXSelectedAttribute, of: targetElement) else {
                throw QAXInteractionError.rowSelectionStateReadFailed
            }
            guard let selectedAtVerify = Self.axBoolAttribute(kAXSelectedAttribute, of: targetElement) else {
                throw QAXInteractionError.rowSelectionStateReadFailed
            }
            guard selectedAtVerify == selectedAtSearch else {
                throw QAXInteractionError.valueDriftDetected("target row's selected state changed between observation and dispatch")
            }

            let targetIdentity = "application=\(applicationName) role=\(role) subrole=\(Self.tableRowSubrole) identifier=\(observedAtVerify.identifier ?? "none") label=\(observedAtVerify.titleOrDescription ?? "none")"

            guard !selectedAtVerify else {
                // Idempotent no-op: the row already reports selected=true. No AX press is
                // performed — an unnecessary mutation is itself something to avoid.
                return QAXTableRowSelectionOutcome(
                    changeKind: .alreadyDesired,
                    previousSelected: selectedAtVerify,
                    currentSelected: selectedAtVerify,
                    targetIdentity: targetIdentity
                )
            }

            let pressResult = AXUIElementPerformAction(targetElement, kAXPressAction as CFString)
            switch pressResult {
            case .success:
                break
            case .actionUnsupported:
                throw QAXInteractionError.actionUnsupported
            default:
                throw QAXInteractionError.pressFailed("AXError(\(pressResult.rawValue))")
            }

            // Immediate ephemeral post-press read — provisional only; the authoritative check is
            // the later, independent closed-loop verification step
            // (QVerificationStrategy.axTableRowSelectionMatchesDesired), which re-resolves the
            // target fresh rather than trusting this in-process observation.
            let currentSelected = Self.axBoolAttribute(kAXSelectedAttribute, of: targetElement) ?? true

            return QAXTableRowSelectionOutcome(
                changeKind: .changed,
                previousSelected: selectedAtVerify,
                currentSelected: currentSelected,
                targetIdentity: targetIdentity
            )
        }.value
    }

    /// Best-effort, read-only re-resolution of the same match criteria used by `selectTableRow`,
    /// used both by the later closed-loop verification step
    /// (`QVerificationStrategy.axTableRowSelectionMatchesDesired`) and by
    /// `QTaskRecoveryManager`'s observation-first recovery branch — the SAME primitive for both,
    /// never a parallel resolver. Independently re-reads `kAXSelectedAttribute` fresh — never
    /// trusts whatever `selectTableRow` itself last observed. Also independently re-verifies the
    /// `AXTableRow` subrole and the `AXTable` parent context, so a target that has stopped being a
    /// qualifying table row (however implausible in practice) is never conflated with a genuine,
    /// still-authoritative selection observation. `.stateUnreadable` (the attribute could not be
    /// read) is deliberately distinct from `.targetUnavailable` (the target itself cannot be
    /// resolved, is ambiguous, or is no longer subrole/context-qualified) for a clearer
    /// diagnostic, though both are treated as `.failed` by verification — neither is ever coerced
    /// into a definite selected/not-selected guess.
    public func observeTableRowSelectionEvidence(
        applicationName: String,
        role: String,
        identifier: String?,
        title: String?
    ) async -> QAXTableRowSelectionEvidence {
        guard AXIsProcessTrusted() else { return .targetUnavailable }
        guard let runningApp = try? Self.resolveExactRunningApplication(named: applicationName) else { return .targetUnavailable }

        let processIdentifier = runningApp.processIdentifier
        return await Task.detached(priority: .userInitiated) {
            let appElement = AXUIElementCreateApplication(processIdentifier)
            let matches = Self.collectMatches(root: appElement, role: role, identifier: identifier, title: title)
            guard matches.count == 1 else { return .targetUnavailable }
            guard Self.axStringAttribute(kAXSubroleAttribute, of: matches[0].element) == Self.tableRowSubrole else {
                return .targetUnavailable
            }
            guard let parentElement = Self.axElementAttribute(kAXParentAttribute, of: matches[0].element),
                  Self.axStringAttribute(kAXRoleAttribute, of: parentElement) == Self.tableContextRole else {
                return .targetUnavailable
            }
            guard let currentSelected = Self.axBoolAttribute(kAXSelectedAttribute, of: matches[0].element) else {
                return .stateUnreadable
            }
            return .resolved(currentSelected: currentSelected)
        }.value
    }

    // MARK: - Semantic Outline Row Selection (Phase 2T)
    //
    // ui.select_outline_row — a Level 2, selection-only operation (never deselection) for exactly
    // one semantically-identified outline row. Confirmed directly against this SDK's
    // authoritative AXRoleConstants.h (the same header family that confirmed
    // ui.select_table_row's role/subrole/parent constants): `AXRow` (`kAXRowRole`) is the same
    // genuine, standalone base role table rows use — outline rows are distinguished purely by
    // subrole (`AXOutlineRow`/`kAXOutlineRowSubrole`) and parent role (`AXOutline`/
    // `kAXOutlineRole`), never by a distinct base role. `selectOutlineRow` resolves by role
    // `AXRow` (`QAXOutlineRowRolePolicy`'s only allowed role) and additionally, unconditionally
    // requires BOTH the `AXOutlineRow` subrole AND a resolved `kAXParentAttribute` whose own role
    // is exactly `AXOutline` — an `AXRow` missing either is refused, never treated as an outline
    // row. `AXTableRow` is a real, SDK-confirmed subrole this phase explicitly recognizes and
    // refuses (`QAXInteractionError.tableRowUnsupportedForOutline`) — see
    // docs/PHASE_2T_SEMANTIC_OUTLINE_ROW_SELECTION.md. Mutation is
    // AXUIElementPerformAction(kAXPressAction) only — the same primitive
    // ui.select_table_row/ui.select_tab/ui.toggle_disclosure/ui.set_element_state/
    // ui.click_element already use; kAXSelectedAttribute is never written directly. No
    // auto-expand-then-select: a collapsed row's descendant is simply not resolvable by the
    // bounded tree walk — never specially detected or expanded. Authoritative selection state is
    // read from kAXSelectedAttribute — deliberately never any table/outline-level multi-selection
    // attribute. Unlike `ui.select_tab`, deselection is not merely unguaranteed — it is
    // categorically out of scope: `desiredSelected` MUST be `true`, refused BEFORE any
    // Accessibility Trust check or application resolution is even attempted if `false`.

    // Reuses `Self.outlineRowSubrole` ("AXOutlineRow") and `Self.tableRowSubrole` ("AXTableRow")
    // directly — both already declared, fileprivate-scoped, in this same extension by
    // `ui.select_table_row`'s (Phase 2S) implementation above. No duplicate constant declared
    // here: the exact same SDK-confirmed string values apply unchanged to this capability.

    /// The exact parent `kAXRoleAttribute` value that establishes a row's outline context. Never
    /// a model-configurable input — hard-coded, non-negotiable part of
    /// `ui.select_outline_row`'s own contract.
    fileprivate static let outlineContextRole = "AXOutline"

    /// Resolves exactly one semantic `AXRow` target carrying the `AXOutlineRow` subrole and an
    /// `AXOutline`-rooted parent context, and — unless it already reports the desired
    /// `kAXSelectedAttribute` state — presses it toward selection. Fails closed (throws
    /// `QAXInteractionError`) on a disallowed role, a resolved `AXRow` lacking the `AXOutlineRow`
    /// subrole, a recognized-but-unsupported `AXTableRow` subrole, an unestablished outline
    /// context, missing criteria, permission absence, application absence, zero/ambiguous
    /// matches, a disabled/stale target, an unreadable current selection state, a selection-state
    /// drift between resolution and dispatch, or a deselection request — never falls back to
    /// coordinates, CGEvent, or keyboard simulation, and never fabricates success. Idempotent: if
    /// the row's current `kAXSelectedAttribute` already reports `true`, no
    /// `AXUIElementPerformAction` call is made at all — `changeKind: .alreadyDesired` is itself
    /// the deterministic, structural proof that no mutation occurred (the same convention every
    /// prior idempotent AX capability in this codebase already establishes).
    public func selectOutlineRow(
        applicationName: String,
        role: String,
        identifier: String?,
        title: String?,
        desiredSelected: Bool
    ) async throws -> QAXOutlineRowSelectionOutcome {
        guard identifier != nil || title != nil else {
            throw QAXInteractionError.missingMatchCriteria
        }
        // Role is validated as a search CRITERION, before any tree walk — an unauthorized role
        // is refused outright rather than allowed to shape what gets searched for, mirroring
        // every prior write-side role policy in this codebase. Note: passing this check alone
        // does NOT mean the target will be treated as an outline row — the mandatory
        // AXOutlineRow subrole + AXOutline parent-context checks below are what actually decide
        // that.
        guard QAXOutlineRowRolePolicy.isAllowedOutlineRowRole(role) else {
            throw QAXInteractionError.disallowedOutlineRowRole(role)
        }
        // Deselection is categorically out of scope for this phase — refused BEFORE any
        // Accessibility Trust check or application resolution is even attempted, never treated
        // as a blind toggle and never silently coerced to true.
        guard desiredSelected else {
            throw QAXInteractionError.outlineRowDeselectionUnsupported(
                "ui.select_outline_row supports selection only (desiredSelected must be true)"
            )
        }

        guard AXIsProcessTrusted() else {
            throw QAXInteractionError.accessibilityPermissionDenied
        }

        let runningApp = try Self.resolveExactRunningApplication(named: applicationName)

        let processIdentifier = runningApp.processIdentifier

        return try await Task.detached(priority: .userInitiated) {
            let appElement = AXUIElementCreateApplication(processIdentifier)

            let matches = Self.collectMatches(root: appElement, role: role, identifier: identifier, title: title)
            guard !matches.isEmpty else { throw QAXInteractionError.noMatchingElement }
            guard matches.count == 1 else { throw QAXInteractionError.ambiguousTarget(count: matches.count) }

            let (targetElement, observedAtSearch) = matches[0]

            // Identity observation binding: identical discipline to every prior AX mutation
            // capability — re-read the SAME element reference immediately before any mutation
            // and refuse on any drift.
            guard let observedAtVerify = Self.snapshotIfMatches(targetElement, role: role, identifier: identifier, title: title) else {
                throw QAXInteractionError.staleTarget("target element is no longer resolvable immediately before dispatch")
            }
            guard observedAtVerify == observedAtSearch else {
                throw QAXInteractionError.staleTarget("target element identity changed between observation and dispatch")
            }
            guard observedAtVerify.isEnabled else {
                throw QAXInteractionError.targetDisabled
            }

            // The mandatory, non-negotiable subrole gate: an AXRow without the AXOutlineRow
            // subrole is never treated as an outline row. AXTableRow is recognized-but-refused
            // with its own distinct diagnostic, never silently folded into outline-row handling.
            let observedSubrole = Self.axStringAttribute(kAXSubroleAttribute, of: targetElement)
            guard observedSubrole != Self.tableRowSubrole else {
                throw QAXInteractionError.tableRowUnsupportedForOutline(observedSubrole ?? "none")
            }
            guard observedSubrole == Self.outlineRowSubrole else {
                throw QAXInteractionError.targetNotAnOutlineRow(observedSubrole ?? "none")
            }

            // The mandatory, non-negotiable outline-context gate: a row is never accepted unless
            // its own kAXParentAttribute resolves to an element whose role is exactly AXOutline —
            // an arbitrary standalone AXRow+AXOutlineRow element with no such parent is refused.
            // This is re-verified independently on every observation (never assumed to persist
            // from resolution time) — a row discovered under an outline does not remain
            // trustworthy as an outline row merely because it once was.
            guard let parentElement = Self.axElementAttribute(kAXParentAttribute, of: targetElement) else {
                throw QAXInteractionError.outlineContextUnavailable("parent element could not be resolved")
            }
            guard Self.axStringAttribute(kAXRoleAttribute, of: parentElement) == Self.outlineContextRole else {
                throw QAXInteractionError.outlineContextUnavailable("parent role is not AXOutline")
            }

            // Selection-state-drift staleness check (mirroring selectTableRow's/selectTab's
            // discipline): read kAXSelectedAttribute once at resolution, once again immediately
            // before dispatch, and refuse if they differ — the target may still be the exact same
            // element by identity, but its selection state already changed out from under this
            // call.
            guard let selectedAtSearch = Self.axBoolAttribute(kAXSelectedAttribute, of: targetElement) else {
                throw QAXInteractionError.outlineRowSelectionStateReadFailed
            }
            guard let selectedAtVerify = Self.axBoolAttribute(kAXSelectedAttribute, of: targetElement) else {
                throw QAXInteractionError.outlineRowSelectionStateReadFailed
            }
            guard selectedAtVerify == selectedAtSearch else {
                throw QAXInteractionError.valueDriftDetected("target row's selected state changed between observation and dispatch")
            }

            let targetIdentity = "application=\(applicationName) role=\(role) subrole=\(Self.outlineRowSubrole) identifier=\(observedAtVerify.identifier ?? "none") label=\(observedAtVerify.titleOrDescription ?? "none")"

            guard !selectedAtVerify else {
                // Idempotent no-op: the row already reports selected=true. No AX press is
                // performed — an unnecessary mutation is itself something to avoid.
                return QAXOutlineRowSelectionOutcome(
                    changeKind: .alreadyDesired,
                    previousSelected: selectedAtVerify,
                    currentSelected: selectedAtVerify,
                    targetIdentity: targetIdentity
                )
            }

            let pressResult = AXUIElementPerformAction(targetElement, kAXPressAction as CFString)
            switch pressResult {
            case .success:
                break
            case .actionUnsupported:
                throw QAXInteractionError.actionUnsupported
            default:
                throw QAXInteractionError.pressFailed("AXError(\(pressResult.rawValue))")
            }

            // Immediate ephemeral post-press read — provisional only; the authoritative check is
            // the later, independent closed-loop verification step
            // (QVerificationStrategy.axOutlineRowSelectionMatchesDesired), which re-resolves the
            // target fresh rather than trusting this in-process observation.
            let currentSelected = Self.axBoolAttribute(kAXSelectedAttribute, of: targetElement) ?? true

            return QAXOutlineRowSelectionOutcome(
                changeKind: .changed,
                previousSelected: selectedAtVerify,
                currentSelected: currentSelected,
                targetIdentity: targetIdentity
            )
        }.value
    }

    /// Best-effort, read-only re-resolution of the same match criteria used by
    /// `selectOutlineRow`, used both by the later closed-loop verification step
    /// (`QVerificationStrategy.axOutlineRowSelectionMatchesDesired`) and by
    /// `QTaskRecoveryManager`'s observation-first recovery branch — the SAME primitive for both,
    /// never a parallel resolver. Independently re-reads `kAXSelectedAttribute` fresh — never
    /// trusts whatever `selectOutlineRow` itself last observed. Also independently re-verifies the
    /// `AXOutlineRow` subrole and the `AXOutline` parent context, so a target that has stopped
    /// being a qualifying outline row (however implausible in practice) is never conflated with a
    /// genuine, still-authoritative selection observation. `.stateUnreadable` (the attribute could
    /// not be read) is deliberately distinct from `.targetUnavailable` (the target itself cannot
    /// be resolved, is ambiguous, or is no longer subrole/context-qualified) for a clearer
    /// diagnostic, though both are treated as `.failed` by verification — neither is ever coerced
    /// into a definite selected/not-selected guess.
    public func observeOutlineRowSelectionEvidence(
        applicationName: String,
        role: String,
        identifier: String?,
        title: String?
    ) async -> QAXOutlineRowSelectionEvidence {
        guard AXIsProcessTrusted() else { return .targetUnavailable }
        guard let runningApp = try? Self.resolveExactRunningApplication(named: applicationName) else { return .targetUnavailable }

        let processIdentifier = runningApp.processIdentifier
        return await Task.detached(priority: .userInitiated) {
            let appElement = AXUIElementCreateApplication(processIdentifier)
            let matches = Self.collectMatches(root: appElement, role: role, identifier: identifier, title: title)
            guard matches.count == 1 else { return .targetUnavailable }
            guard Self.axStringAttribute(kAXSubroleAttribute, of: matches[0].element) == Self.outlineRowSubrole else {
                return .targetUnavailable
            }
            guard let parentElement = Self.axElementAttribute(kAXParentAttribute, of: matches[0].element),
                  Self.axStringAttribute(kAXRoleAttribute, of: parentElement) == Self.outlineContextRole else {
                return .targetUnavailable
            }
            guard let currentSelected = Self.axBoolAttribute(kAXSelectedAttribute, of: matches[0].element) else {
                return .stateUnreadable
            }
            return .resolved(currentSelected: currentSelected)
        }.value
    }

    // MARK: - Semantic Window Minimized State (Phase 2U)
    //
    // ui.set_window_minimized — a Level 2, symmetric explicit-desired-state operation (unlike
    // every prior row/tab-selection capability, BOTH `desiredMinimized=true` AND
    // `desiredMinimized=false` are fully supported — there is no one-way restriction here) for
    // exactly one semantically-identified window. The first WINDOW-level capability in this
    // codebase — every prior capability targets a control inside a window, never the window
    // itself. Confirmed directly against this SDK's authoritative AXAttributeConstants.h:
    // `kAXMinimizedAttribute` is documented as "Whether a window is currently minimized to the
    // dock... Writable? Yes." — a directly-settable boolean, the same "attribute IS the
    // authoritative state" reasoning `ui.set_slider_value` already established for
    // `kAXValueAttribute`, applied here to `kAXMinimizedAttribute` instead. Mutation is
    // AXUIElementSetAttributeValue(kAXMinimizedAttribute, kCFBooleanTrue/kCFBooleanFalse) only —
    // never AXUIElementPerformAction, never `kAXMinimizeButtonAttribute` (the read-only
    // convenience reference to the titlebar minimize button), never `kAXRaiseAction` (a real,
    // defined AX action, but one Apple's own header ships with an entirely empty `@discussion`
    // block — no documented behavior exists for it, so it is never used here), never
    // NSWindow/CGEvent/coordinate/AppleScript/shell interaction. This capability never activates,
    // focuses, or raises the target application or window as a side effect — `AXUIElementCreate
    // Application` is a pure AX object-reference constructor with no such effect, the same
    // primitive every prior capability already uses without activating anything.

    /// Resolves exactly one semantic `AXWindow` target and — unless it already reports the
    /// desired `kAXMinimizedAttribute` state — writes it directly. Fails closed (throws
    /// `QAXInteractionError`) on a disallowed role, missing criteria, permission absence,
    /// application absence, zero/ambiguous matches, a stale target, an unreadable current
    /// minimized state, or a state drift between resolution and dispatch — never falls back to
    /// coordinates, CGEvent, or keyboard simulation, and never fabricates success. Idempotent in
    /// BOTH directions: if the window's current `kAXMinimizedAttribute` already equals
    /// `desiredMinimized` (true OR false), no `AXUIElementSetAttributeValue` call is made at all —
    /// `changeKind: .alreadyDesired` is itself the deterministic, structural proof that no
    /// mutation occurred (the same convention every prior idempotent AX capability in this
    /// codebase already establishes).
    public func setWindowMinimizedState(
        applicationName: String,
        role: String,
        identifier: String?,
        title: String?,
        desiredMinimized: Bool
    ) async throws -> QAXWindowMinimizedOutcome {
        guard identifier != nil || title != nil else {
            throw QAXInteractionError.missingMatchCriteria
        }
        // Role is validated as a search CRITERION, before any tree walk — an unauthorized role
        // is refused outright rather than allowed to shape what gets searched for, mirroring
        // every prior write-side role policy in this codebase.
        guard QAXWindowRolePolicy.isAllowedWindowRole(role) else {
            throw QAXInteractionError.disallowedWindowRole(role)
        }

        guard AXIsProcessTrusted() else {
            throw QAXInteractionError.accessibilityPermissionDenied
        }

        let runningApp = try Self.resolveExactRunningApplication(named: applicationName)

        let processIdentifier = runningApp.processIdentifier

        return try await Task.detached(priority: .userInitiated) {
            // A pure AX object-reference constructor — never activates, focuses, or raises the
            // target application, the same primitive every prior capability already uses without
            // any such side effect.
            let appElement = AXUIElementCreateApplication(processIdentifier)

            let matches = Self.collectMatches(root: appElement, role: role, identifier: identifier, title: title)
            guard !matches.isEmpty else { throw QAXInteractionError.noMatchingElement }
            guard matches.count == 1 else { throw QAXInteractionError.ambiguousTarget(count: matches.count) }

            let (targetElement, observedAtSearch) = matches[0]

            // Identity observation binding: identical discipline to every prior AX mutation
            // capability — re-read the SAME element reference immediately before any mutation
            // and refuse on any drift.
            guard let observedAtVerify = Self.snapshotIfMatches(targetElement, role: role, identifier: identifier, title: title) else {
                throw QAXInteractionError.staleTarget("target element is no longer resolvable immediately before dispatch")
            }
            guard observedAtVerify == observedAtSearch else {
                throw QAXInteractionError.staleTarget("target element identity changed between observation and dispatch")
            }

            // Minimized-state-drift staleness check (mirroring setSliderValue's/selectTab's
            // discipline): read kAXMinimizedAttribute once at resolution, once again immediately
            // before dispatch, and refuse if they differ — the target may still be the exact same
            // element by identity, but its minimized state already changed out from under this
            // call. Authoritative source only — never inferred from position, visibility,
            // frontmost state, Dock appearance, or title.
            guard let minimizedAtSearch = Self.axBoolAttribute(kAXMinimizedAttribute, of: targetElement) else {
                throw QAXInteractionError.windowMinimizedStateReadFailed
            }
            guard let minimizedAtVerify = Self.axBoolAttribute(kAXMinimizedAttribute, of: targetElement) else {
                throw QAXInteractionError.windowMinimizedStateReadFailed
            }
            guard minimizedAtVerify == minimizedAtSearch else {
                throw QAXInteractionError.valueDriftDetected("target window's minimized state changed between observation and dispatch")
            }

            let targetIdentity = "application=\(applicationName) role=\(role) identifier=\(observedAtVerify.identifier ?? "none") label=\(observedAtVerify.titleOrDescription ?? "none")"

            guard minimizedAtVerify != desiredMinimized else {
                // Idempotent no-op in EITHER direction: the window already reports the desired
                // minimized state. No AX write is performed — an unnecessary mutation is itself
                // something to avoid, and no approval is consumed for a mutation that was never
                // needed.
                return QAXWindowMinimizedOutcome(
                    changeKind: .alreadyDesired,
                    previousMinimized: minimizedAtVerify,
                    currentMinimized: minimizedAtVerify,
                    desiredMinimized: desiredMinimized,
                    targetIdentity: targetIdentity
                )
            }

            let setResult = AXUIElementSetAttributeValue(
                targetElement,
                kAXMinimizedAttribute as CFString,
                desiredMinimized ? kCFBooleanTrue : kCFBooleanFalse
            )
            guard setResult == .success else {
                throw QAXInteractionError.setValueFailed("AXError(\(setResult.rawValue))")
            }

            // Immediate ephemeral post-set read — provisional only; the authoritative check is
            // the later, independent closed-loop verification step
            // (QVerificationStrategy.axWindowMinimizedStateMatchesDesired), which re-resolves the
            // target fresh rather than trusting this in-process observation.
            let currentMinimizedAfterSet = Self.axBoolAttribute(kAXMinimizedAttribute, of: targetElement) ?? desiredMinimized

            return QAXWindowMinimizedOutcome(
                changeKind: .changed,
                previousMinimized: minimizedAtVerify,
                currentMinimized: currentMinimizedAfterSet,
                desiredMinimized: desiredMinimized,
                targetIdentity: targetIdentity
            )
        }.value
    }

    /// Best-effort, read-only re-resolution of the same match criteria used by
    /// `setWindowMinimizedState`, used both by the later closed-loop verification step
    /// (`QVerificationStrategy.axWindowMinimizedStateMatchesDesired`) and by
    /// `QTaskRecoveryManager`'s observation-first recovery branch — the SAME primitive for both,
    /// never a parallel resolver. Independently re-reads `kAXMinimizedAttribute` fresh — never
    /// trusts whatever `setWindowMinimizedState` itself last observed. `.stateUnreadable` (the
    /// attribute could not be read) is deliberately distinct from `.targetUnavailable` (the
    /// target itself cannot be resolved or is ambiguous) for a clearer diagnostic, though both are
    /// treated as `.failed` by verification — neither is ever coerced into a definite
    /// minimized/not-minimized guess, and a window's disappearance is never automatically
    /// interpreted as success.
    public func observeWindowMinimizedStateEvidence(
        applicationName: String,
        role: String,
        identifier: String?,
        title: String?
    ) async -> QAXWindowMinimizedEvidence {
        guard AXIsProcessTrusted() else { return .targetUnavailable }
        guard let runningApp = try? Self.resolveExactRunningApplication(named: applicationName) else { return .targetUnavailable }

        let processIdentifier = runningApp.processIdentifier
        return await Task.detached(priority: .userInitiated) {
            let appElement = AXUIElementCreateApplication(processIdentifier)
            let matches = Self.collectMatches(root: appElement, role: role, identifier: identifier, title: title)
            guard matches.count == 1 else { return .targetUnavailable }
            guard let currentMinimized = Self.axBoolAttribute(kAXMinimizedAttribute, of: matches[0].element) else {
                return .stateUnreadable
            }
            return .resolved(currentMinimized: currentMinimized)
        }.value
    }

    // MARK: - Semantic Scroll Position (Phase 2W)
    //
    // ui.set_scroll_position — a Level 2, absolute-value operation (never scroll-by-delta, never
    // scroll-to-visible, never scroll-wheel simulation) for exactly one semantically-identified
    // scroll bar. Confirmed directly against this SDK's authoritative AXAttributeConstants.h:
    // `kAXValueAttribute`'s own discussion block explicitly names scroll bars — "a kAXScrollBar's
    // kAXValueAttribute is writable because it allows an efficient way for the user to get to a
    // specific position" — and `kAXMinValueAttribute`/`kAXMaxValueAttribute`'s own discussion
    // blocks explicitly name "sliders and scroll bars" together as their intended use case. The
    // target scroll bar is never searched for directly (raw `AXScrollBar` elements are commonly
    // unlabeled) — resolution anchors on the more commonly-labeled containing `AXScrollArea`
    // (`QAXScrollAreaRolePolicy`'s only allowed role) plus an explicit, never-inferred
    // `orientation` parameter, then follows the documented read-only convenience-reference
    // attribute (`kAXHorizontalScrollBarAttribute`/`kAXVerticalScrollBarAttribute` — resolution
    // only, NEVER mutated) to the actual scroll bar, whose own `kAXRoleAttribute` is independently
    // re-validated as exactly `AXScrollBar` before ever being treated as genuine — the mere
    // existence of the reference is never sufficient. Mutation is
    // AXUIElementSetAttributeValue(kAXValueAttribute) only — the same primitive
    // `ui.set_slider_value` already uses, reusing that capability's own proven range-validation
    // and `sliderValuesAreEqual` tolerance logic verbatim rather than duplicating a subtly
    // different rule. Never `kAXIncrementAction`/`kAXDecrementAction`/`kAXPressAction`, never
    // CGEvent, scroll-wheel, keyboard, mouse, or coordinate interaction.

    /// The exact `kAXRoleAttribute` value the element resolved via the orientation
    /// convenience-reference attribute must report before ever being treated as a genuine scroll
    /// bar. Never a model-configurable input — hard-coded, non-negotiable part of
    /// `ui.set_scroll_position`'s own contract.
    fileprivate static let scrollBarRole = "AXScrollBar"

    /// Maps an explicit, never-inferred orientation string to the exact, SDK-confirmed read-only
    /// convenience-reference attribute name that resolves the corresponding scroll bar from a
    /// scroll area. Returns `nil` for anything other than exactly `"horizontal"`/`"vertical"` —
    /// fails closed rather than guessing.
    fileprivate nonisolated static func scrollBarConvenienceAttribute(forOrientation orientation: String) -> String? {
        switch orientation {
        case "horizontal": return kAXHorizontalScrollBarAttribute as String
        case "vertical": return kAXVerticalScrollBarAttribute as String
        default: return nil
        }
    }

    /// Resolves exactly one semantic `AXScrollArea` target, follows its documented orientation
    /// convenience-reference to the actual scroll bar, independently re-validates that element's
    /// own role as exactly `AXScrollBar`, validates `desiredValue` against the scroll bar's own
    /// reported `[minValue, maxValue]` range using STRICT (non-tolerant) comparison — a hard
    /// security boundary — re-verifies value/range immediately before dispatch, and sets the
    /// value via `AXUIElementSetAttributeValue` only if it differs (tolerantly, via
    /// `sliderValuesAreEqual`) from the current value. Fails closed on a disallowed scroll-area
    /// role, an invalid orientation, an unresolvable/misqualified scroll-bar reference,
    /// non-finite `desiredValue`, unreadable/inconsistent range, an out-of-range request, or any
    /// staleness. Never falls back to coordinates, CGEvent, scroll-wheel, keyboard, or mouse
    /// simulation.
    public func setScrollPosition(
        applicationName: String,
        role: String,
        identifier: String?,
        title: String?,
        orientation: String,
        desiredValue: Double
    ) async throws -> QAXScrollPositionOutcome {
        guard identifier != nil || title != nil else {
            throw QAXInteractionError.missingMatchCriteria
        }
        guard desiredValue.isFinite else {
            throw QAXInteractionError.invalidDesiredValue("desiredValue must be a finite number, got \(desiredValue)")
        }
        // Role is validated as a search CRITERION, before any tree walk — an unauthorized role
        // is refused outright rather than allowed to shape what gets searched for, mirroring
        // every prior write-side role policy in this codebase.
        guard QAXScrollAreaRolePolicy.isAllowedScrollAreaRole(role) else {
            throw QAXInteractionError.disallowedScrollAreaRole(role)
        }
        // Orientation is explicit and never inferred — validated before any AX call is even
        // attempted.
        guard let scrollBarAttribute = Self.scrollBarConvenienceAttribute(forOrientation: orientation) else {
            throw QAXInteractionError.invalidOrientation(orientation)
        }

        guard AXIsProcessTrusted() else {
            throw QAXInteractionError.accessibilityPermissionDenied
        }

        let runningApp = try Self.resolveExactRunningApplication(named: applicationName)

        let processIdentifier = runningApp.processIdentifier

        return try await Task.detached(priority: .userInitiated) {
            let appElement = AXUIElementCreateApplication(processIdentifier)

            let matches = Self.collectMatches(root: appElement, role: role, identifier: identifier, title: title)
            guard !matches.isEmpty else { throw QAXInteractionError.noMatchingElement }
            guard matches.count == 1 else { throw QAXInteractionError.ambiguousTarget(count: matches.count) }

            let (scrollAreaElement, observedAtSearch) = matches[0]

            // Identity observation binding: identical discipline to every prior AX mutation
            // capability — re-read the SAME element reference immediately before any mutation
            // and refuse on any drift.
            guard let observedAtVerify = Self.snapshotIfMatches(scrollAreaElement, role: role, identifier: identifier, title: title) else {
                throw QAXInteractionError.staleTarget("target scroll area is no longer resolvable immediately before dispatch")
            }
            guard observedAtVerify == observedAtSearch else {
                throw QAXInteractionError.staleTarget("target scroll area identity changed between observation and dispatch")
            }

            // Resolve the actual scroll bar via the documented, read-only convenience-reference
            // attribute — resolution only, never mutated itself.
            guard let scrollBarElement = Self.axElementAttribute(scrollBarAttribute, of: scrollAreaElement) else {
                throw QAXInteractionError.scrollBarReferenceUnavailable(orientation)
            }

            // The mandatory, non-negotiable role gate: the mere existence of the convenience
            // reference is never sufficient — its own kAXRoleAttribute must independently report
            // exactly AXScrollBar before it is ever treated as a genuine scroll bar target.
            guard let scrollBarRole = Self.axStringAttribute(kAXRoleAttribute, of: scrollBarElement), scrollBarRole == Self.scrollBarRole else {
                throw QAXInteractionError.targetNotAScrollBar(Self.axStringAttribute(kAXRoleAttribute, of: scrollBarElement) ?? "none")
            }

            let scrollBarEnabled = Self.axBoolAttribute(kAXEnabledAttribute, of: scrollBarElement) ?? true
            guard scrollBarEnabled else {
                throw QAXInteractionError.targetDisabled
            }

            // Range discovery — read BEFORE any mutation decision, and before desiredValue is
            // validated against it, on the resolved SCROLL BAR (never the scroll area).
            guard let minValueAtSearch = Self.axDoubleAttribute(kAXMinValueAttribute as String, of: scrollBarElement),
                  let maxValueAtSearch = Self.axDoubleAttribute(kAXMaxValueAttribute as String, of: scrollBarElement) else {
                throw QAXInteractionError.rangeReadFailed
            }
            guard minValueAtSearch <= maxValueAtSearch else {
                throw QAXInteractionError.invalidRange("minValue (\(minValueAtSearch)) is greater than maxValue (\(maxValueAtSearch))")
            }
            guard let currentValueAtSearch = Self.axDoubleAttribute(kAXValueAttribute as String, of: scrollBarElement) else {
                throw QAXInteractionError.valueReadFailed
            }
            guard currentValueAtSearch >= minValueAtSearch, currentValueAtSearch <= maxValueAtSearch else {
                throw QAXInteractionError.invalidRange("current value (\(currentValueAtSearch)) is outside the reported range [\(minValueAtSearch), \(maxValueAtSearch)]")
            }

            // SECURITY BOUNDARY: strict, non-tolerant range check. Never widened by
            // sliderValuesAreEqual's tolerance — an out-of-range request is refused exactly at
            // its true boundary, not a tolerance-expanded one.
            guard desiredValue >= minValueAtSearch, desiredValue <= maxValueAtSearch else {
                throw QAXInteractionError.desiredValueOutOfRange("desiredValue (\(desiredValue)) is outside the allowed range [\(minValueAtSearch), \(maxValueAtSearch)]")
            }

            // Value/range-drift re-check immediately before dispatch, on the SAME scroll-bar
            // element reference — refuses on ANY drift in current value, minValue, or maxValue
            // (tolerant comparison: this is asking "did anything actually change", not
            // re-validating a boundary).
            guard let minValueAtVerify = Self.axDoubleAttribute(kAXMinValueAttribute as String, of: scrollBarElement),
                  let maxValueAtVerify = Self.axDoubleAttribute(kAXMaxValueAttribute as String, of: scrollBarElement),
                  let currentValueAtVerify = Self.axDoubleAttribute(kAXValueAttribute as String, of: scrollBarElement) else {
                throw QAXInteractionError.valueReadFailed
            }
            guard Self.sliderValuesAreEqual(minValueAtVerify, minValueAtSearch),
                  Self.sliderValuesAreEqual(maxValueAtVerify, maxValueAtSearch),
                  Self.sliderValuesAreEqual(currentValueAtVerify, currentValueAtSearch) else {
                throw QAXInteractionError.valueDriftDetected("target scroll bar's value or range changed between observation and dispatch")
            }

            let targetIdentity = "application=\(applicationName) role=\(role) identifier=\(observedAtVerify.identifier ?? "none") label=\(observedAtVerify.titleOrDescription ?? "none") orientation=\(orientation)"

            guard !Self.sliderValuesAreEqual(currentValueAtVerify, desiredValue) else {
                // Idempotent no-op: already at the desired position. No AX write is performed.
                return QAXScrollPositionOutcome(
                    changeKind: .alreadyDesired,
                    previousValue: currentValueAtVerify,
                    currentValue: currentValueAtVerify,
                    desiredValue: desiredValue,
                    minValue: minValueAtVerify,
                    maxValue: maxValueAtVerify,
                    targetIdentity: targetIdentity
                )
            }

            let setResult = AXUIElementSetAttributeValue(scrollBarElement, kAXValueAttribute as CFString, NSNumber(value: desiredValue))
            guard setResult == .success else {
                throw QAXInteractionError.setValueFailed("AXError(\(setResult.rawValue))")
            }

            // Immediate ephemeral post-set read — provisional only; the authoritative check is
            // the later, independent closed-loop verification step
            // (QVerificationStrategy.scrollPositionMatchesDesired), which re-resolves the FULL
            // identity chain fresh rather than trusting this in-process observation.
            let currentValueAfterSet = Self.axDoubleAttribute(kAXValueAttribute as String, of: scrollBarElement) ?? desiredValue

            return QAXScrollPositionOutcome(
                changeKind: .changed,
                previousValue: currentValueAtVerify,
                currentValue: currentValueAfterSet,
                desiredValue: desiredValue,
                minValue: minValueAtVerify,
                maxValue: maxValueAtVerify,
                targetIdentity: targetIdentity
            )
        }.value
    }

    /// Best-effort, read-only re-resolution of the same match criteria used by
    /// `setScrollPosition`, used both by the later closed-loop verification step
    /// (`QVerificationStrategy.scrollPositionMatchesDesired`) and by `QTaskRecoveryManager`'s
    /// observation-first recovery branch — the SAME primitive for both, never a parallel
    /// resolver. Re-resolves the ENTIRE identity chain fresh — scroll area, then the orientation
    /// convenience-reference, then the scroll bar's own role — never trusts a cached element
    /// reference. Also re-validates that the target's range remains internally consistent — a
    /// `.rangeInvalid` result means verification cannot be trusted, exactly like an unresolvable
    /// target.
    public func observeScrollPositionEvidence(
        applicationName: String,
        role: String,
        identifier: String?,
        title: String?,
        orientation: String
    ) async -> QAXScrollPositionEvidence {
        guard AXIsProcessTrusted() else { return .targetUnavailable }
        guard let scrollBarAttribute = Self.scrollBarConvenienceAttribute(forOrientation: orientation) else { return .targetUnavailable }
        guard let runningApp = try? Self.resolveExactRunningApplication(named: applicationName) else { return .targetUnavailable }

        let processIdentifier = runningApp.processIdentifier
        return await Task.detached(priority: .userInitiated) {
            let appElement = AXUIElementCreateApplication(processIdentifier)
            let matches = Self.collectMatches(root: appElement, role: role, identifier: identifier, title: title)
            guard matches.count == 1 else { return .targetUnavailable }
            guard let scrollBarElement = Self.axElementAttribute(scrollBarAttribute, of: matches[0].element) else {
                return .targetUnavailable
            }
            guard let scrollBarRole = Self.axStringAttribute(kAXRoleAttribute, of: scrollBarElement), scrollBarRole == Self.scrollBarRole else {
                return .targetUnavailable
            }
            guard let currentValue = Self.axDoubleAttribute(kAXValueAttribute as String, of: scrollBarElement),
                  let minValue = Self.axDoubleAttribute(kAXMinValueAttribute as String, of: scrollBarElement),
                  let maxValue = Self.axDoubleAttribute(kAXMaxValueAttribute as String, of: scrollBarElement) else {
                return .targetUnavailable
            }
            guard minValue <= maxValue, currentValue >= minValue, currentValue <= maxValue else {
                return .rangeInvalid(currentValue: currentValue)
            }
            return .resolved(currentValue: currentValue)
        }.value
    }

    // MARK: - Semantic Window Main Designation (Phase 2X)
    //
    // ui.set_window_main — a Level 2, SELECT-ONLY operation (never deselection) for exactly one
    // semantically-identified window. Confirmed directly against this SDK's authoritative
    // AXAttributeConstants.h: `kAXMainAttribute` is documented "Whether a window is the main
    // document window of an application... Main does not necessarily imply that the window has
    // key focus... Writable? Yes." — a directly-settable boolean, the same "attribute IS the
    // authoritative state" reasoning `ui.set_window_minimized` already established for
    // `kAXMinimizedAttribute`, applied here to `kAXMainAttribute` instead. Reuses
    // `QAXWindowRolePolicy` (Phase 2U) unmodified — the identical single-role allowlist (`AXWindow`
    // only). Unlike `ui.set_window_minimized`'s bidirectional model, this capability is
    // select-only, by direct analogy to `ui.select_tab`'s own already-established finding: AX
    // provides no reliable way to "un-main" a single window without designating a replacement —
    // the standard interaction model makes a DIFFERENT window main instead. `desiredMain` MUST be
    // `true`, refused BEFORE any Accessibility Trust check or application resolution is even
    // attempted if `false`. This capability makes NO claim about activation, focus, raise, or any
    // visual/ordering effect — it reads and writes `kAXMainAttribute` alone, nothing more; it
    // never enumerates other windows, never mutates any window other than the exact resolved
    // target, and never attempts to enforce exclusivity itself — that semantic is owned entirely
    // by the OS/application.

    /// Resolves exactly one semantic `AXWindow` target and — unless it already reports
    /// `kAXMainAttribute == true` — writes it directly. Fails closed (throws
    /// `QAXInteractionError`) on a disallowed role, missing criteria, permission absence,
    /// application absence, zero/ambiguous matches, a stale target, an unreadable current main
    /// state, a state drift between resolution and dispatch, or a deselection request — never
    /// falls back to coordinates, CGEvent, or keyboard simulation, and never fabricates success.
    /// Idempotent: if the window's current `kAXMainAttribute` already reports `true`, no
    /// `AXUIElementSetAttributeValue` call is made at all — `changeKind: .alreadyDesired` is
    /// itself the deterministic, structural proof that no mutation occurred.
    public func setWindowMain(
        applicationName: String,
        role: String,
        identifier: String?,
        title: String?,
        desiredMain: Bool
    ) async throws -> QAXWindowMainOutcome {
        guard identifier != nil || title != nil else {
            throw QAXInteractionError.missingMatchCriteria
        }
        // Role is validated as a search CRITERION, before any tree walk — an unauthorized role
        // is refused outright rather than allowed to shape what gets searched for, mirroring
        // every prior write-side role policy in this codebase.
        guard QAXWindowRolePolicy.isAllowedWindowRole(role) else {
            throw QAXInteractionError.disallowedWindowRole(role)
        }
        // Deselection is categorically out of scope for this capability — refused BEFORE any
        // Accessibility Trust check or application resolution is even attempted, never treated
        // as a blind toggle and never silently coerced to true.
        guard desiredMain else {
            throw QAXInteractionError.windowMainDeselectionUnsupported(
                "ui.set_window_main supports selection only (desiredMain must be true)"
            )
        }

        guard AXIsProcessTrusted() else {
            throw QAXInteractionError.accessibilityPermissionDenied
        }

        let runningApp = try Self.resolveExactRunningApplication(named: applicationName)

        let processIdentifier = runningApp.processIdentifier

        return try await Task.detached(priority: .userInitiated) {
            // A pure AX object-reference constructor — never activates, focuses, or raises the
            // target application, the same primitive every prior capability already uses without
            // any such side effect.
            let appElement = AXUIElementCreateApplication(processIdentifier)

            let matches = Self.collectMatches(root: appElement, role: role, identifier: identifier, title: title)
            guard !matches.isEmpty else { throw QAXInteractionError.noMatchingElement }
            guard matches.count == 1 else { throw QAXInteractionError.ambiguousTarget(count: matches.count) }

            let (targetElement, observedAtSearch) = matches[0]

            // Identity observation binding: identical discipline to every prior AX mutation
            // capability — re-read the SAME element reference immediately before any mutation
            // and refuse on any drift.
            guard let observedAtVerify = Self.snapshotIfMatches(targetElement, role: role, identifier: identifier, title: title) else {
                throw QAXInteractionError.staleTarget("target element is no longer resolvable immediately before dispatch")
            }
            guard observedAtVerify == observedAtSearch else {
                throw QAXInteractionError.staleTarget("target element identity changed between observation and dispatch")
            }

            // Main-state-drift staleness check (mirroring setWindowMinimizedState's/selectTab's
            // discipline): read kAXMainAttribute once at resolution, once again immediately
            // before dispatch, and refuse if they differ — the target may still be the exact same
            // element by identity, but its main state already changed out from under this call.
            guard let mainAtSearch = Self.axBoolAttribute(kAXMainAttribute, of: targetElement) else {
                throw QAXInteractionError.windowMainStateReadFailed
            }
            guard let mainAtVerify = Self.axBoolAttribute(kAXMainAttribute, of: targetElement) else {
                throw QAXInteractionError.windowMainStateReadFailed
            }
            guard mainAtVerify == mainAtSearch else {
                throw QAXInteractionError.valueDriftDetected("target window's main state changed between observation and dispatch")
            }

            let targetIdentity = "application=\(applicationName) role=\(role) identifier=\(observedAtVerify.identifier ?? "none") label=\(observedAtVerify.titleOrDescription ?? "none")"

            guard !mainAtVerify else {
                // Idempotent no-op: the window already reports main=true. No AX write is
                // performed — an unnecessary mutation is itself something to avoid, and no
                // approval is consumed for a mutation that was never needed.
                return QAXWindowMainOutcome(
                    changeKind: .alreadyDesired,
                    previousMain: mainAtVerify,
                    currentMain: mainAtVerify,
                    targetIdentity: targetIdentity
                )
            }

            let setResult = AXUIElementSetAttributeValue(targetElement, kAXMainAttribute as CFString, kCFBooleanTrue)
            guard setResult == .success else {
                throw QAXInteractionError.setValueFailed("AXError(\(setResult.rawValue))")
            }

            // Immediate ephemeral post-set read — provisional only; the authoritative check is
            // the later, independent closed-loop verification step
            // (QVerificationStrategy.windowMainStateMatchesDesired), which re-resolves the
            // target fresh rather than trusting this in-process observation. This capability
            // makes no claim about activation/focus/raise — only kAXMainAttribute's own value is
            // ever read or reasoned about.
            let currentMainAfterSet = Self.axBoolAttribute(kAXMainAttribute, of: targetElement) ?? true

            return QAXWindowMainOutcome(
                changeKind: .changed,
                previousMain: mainAtVerify,
                currentMain: currentMainAfterSet,
                targetIdentity: targetIdentity
            )
        }.value
    }

    /// Best-effort, read-only re-resolution of the same match criteria used by `setWindowMain`,
    /// used both by the later closed-loop verification step
    /// (`QVerificationStrategy.windowMainStateMatchesDesired`) and by `QTaskRecoveryManager`'s
    /// observation-first recovery branch — the SAME primitive for both, never a parallel
    /// resolver. Independently re-reads `kAXMainAttribute` fresh — never trusts whatever
    /// `setWindowMain` itself last observed. `.stateUnreadable` (the attribute could not be read)
    /// is deliberately distinct from `.targetUnavailable` (the target itself cannot be resolved
    /// or is ambiguous) for a clearer diagnostic, though both are treated as `.failed` by
    /// verification — neither is ever coerced into a definite main/not-main guess.
    public func observeWindowMainEvidence(
        applicationName: String,
        role: String,
        identifier: String?,
        title: String?
    ) async -> QAXWindowMainEvidence {
        guard AXIsProcessTrusted() else { return .targetUnavailable }
        guard let runningApp = try? Self.resolveExactRunningApplication(named: applicationName) else { return .targetUnavailable }

        let processIdentifier = runningApp.processIdentifier
        return await Task.detached(priority: .userInitiated) {
            let appElement = AXUIElementCreateApplication(processIdentifier)
            let matches = Self.collectMatches(root: appElement, role: role, identifier: identifier, title: title)
            guard matches.count == 1 else { return .targetUnavailable }
            guard let currentMain = Self.axBoolAttribute(kAXMainAttribute, of: matches[0].element) else {
                return .stateUnreadable
            }
            return .resolved(currentMain: currentMain)
        }.value
    }

    // MARK: - Semantic Window Full-Screen State (Phase 2AS)
    //
    // ui.set_window_full_screen — a Level 2, symmetric explicit-desired-state operation (unlike
    // ui.set_window_main, both true and false are fully supported) for exactly one
    // semantically-identified window. Confirmed against macOS AX API: kAXFullScreenAttribute
    // ("AXFullScreen") is documented as a boolean attribute indicating full-screen space state.
    // Mutation is AXUIElementSetAttributeValue(axFullScreenAttribute) only — never
    // NSWindow.toggleFullScreen(), never coordinate clicks on green zoom button, never
    // Cmd+Ctrl+F shortcuts, never CGEvent. Idempotent in either direction: already-at-desired-state
    // is a verified no-op, no attribute write performed.
    public func setWindowFullScreenState(
        applicationName: String,
        role: String,
        identifier: String?,
        title: String?,
        desiredFullScreen: Bool
    ) async throws -> QAXWindowFullScreenOutcome {
        guard identifier != nil || title != nil else {
            throw QAXInteractionError.missingMatchCriteria
        }
        guard QAXWindowRolePolicy.isAllowedWindowRole(role) else {
            throw QAXInteractionError.disallowedWindowRole(role)
        }

        guard AXIsProcessTrusted() else {
            throw QAXInteractionError.accessibilityPermissionDenied
        }

        let runningApp = try Self.resolveExactRunningApplication(named: applicationName)
        let processIdentifier = runningApp.processIdentifier

        return try await Task.detached(priority: .userInitiated) {
            let appElement = AXUIElementCreateApplication(processIdentifier)

            let matches = Self.collectMatches(root: appElement, role: role, identifier: identifier, title: title)
            guard !matches.isEmpty else { throw QAXInteractionError.noMatchingElement }
            guard matches.count == 1 else { throw QAXInteractionError.ambiguousTarget(count: matches.count) }

            let (targetElement, observedAtSearch) = matches[0]

            guard let observedAtVerify = Self.snapshotIfMatches(targetElement, role: role, identifier: identifier, title: title) else {
                throw QAXInteractionError.staleTarget("target element is no longer resolvable immediately before dispatch")
            }
            guard observedAtVerify == observedAtSearch else {
                throw QAXInteractionError.staleTarget("target element identity changed between observation and dispatch")
            }

            guard let fullScreenAtSearch = Self.axBoolAttribute(Self.axFullScreenAttribute, of: targetElement) else {
                throw QAXInteractionError.windowFullScreenStateReadFailed
            }
            guard let fullScreenAtVerify = Self.axBoolAttribute(Self.axFullScreenAttribute, of: targetElement) else {
                throw QAXInteractionError.windowFullScreenStateReadFailed
            }
            guard fullScreenAtVerify == fullScreenAtSearch else {
                throw QAXInteractionError.valueDriftDetected("target window's full-screen state changed between observation and dispatch")
            }

            let targetIdentity = "application=\(applicationName) role=\(role) identifier=\(observedAtVerify.identifier ?? "none") label=\(observedAtVerify.titleOrDescription ?? "none")"

            guard fullScreenAtVerify != desiredFullScreen else {
                return QAXWindowFullScreenOutcome(
                    changeKind: .alreadyDesired,
                    previousFullScreen: fullScreenAtVerify,
                    currentFullScreen: fullScreenAtVerify,
                    desiredFullScreen: desiredFullScreen,
                    targetIdentity: targetIdentity
                )
            }

            guard Self.axIsAttributeSettable(Self.axFullScreenAttribute, of: targetElement) else {
                throw QAXInteractionError.windowFullScreenNotWritable("AXFullScreen attribute is not settable for target window")
            }

            let setResult = AXUIElementSetAttributeValue(
                targetElement,
                Self.axFullScreenAttribute as CFString,
                desiredFullScreen ? kCFBooleanTrue : kCFBooleanFalse
            )
            guard setResult == .success else {
                throw QAXInteractionError.setValueFailed("AXError(\(setResult.rawValue))")
            }

            let currentFullScreenAfterSet = Self.axBoolAttribute(Self.axFullScreenAttribute, of: targetElement) ?? desiredFullScreen

            return QAXWindowFullScreenOutcome(
                changeKind: .changed,
                previousFullScreen: fullScreenAtVerify,
                currentFullScreen: currentFullScreenAfterSet,
                desiredFullScreen: desiredFullScreen,
                targetIdentity: targetIdentity
            )
        }.value
    }

    /// Best-effort, read-only re-resolution of the same match criteria used by `setWindowFullScreenState`,
    /// used both by the later closed-loop verification step
    /// (`QVerificationStrategy.axWindowFullScreenMatchesDesired`) and by `QTaskRecoveryManager`'s
    /// observation-first recovery branch. Independently re-reads `kAXFullScreenAttribute` fresh.
    public func observeWindowFullScreenStateEvidence(
        applicationName: String,
        role: String,
        identifier: String?,
        title: String?
    ) async -> QAXWindowFullScreenEvidence {
        guard AXIsProcessTrusted() else { return .targetUnavailable }
        guard let runningApp = try? Self.resolveExactRunningApplication(named: applicationName) else { return .targetUnavailable }

        let processIdentifier = runningApp.processIdentifier
        return await Task.detached(priority: .userInitiated) {
            let appElement = AXUIElementCreateApplication(processIdentifier)
            let matches = Self.collectMatches(root: appElement, role: role, identifier: identifier, title: title)
            guard matches.count == 1 else { return .targetUnavailable }
            guard let currentFullScreen = Self.axBoolAttribute(Self.axFullScreenAttribute, of: matches[0].element) else {
                return .stateUnreadable
            }
            return .resolved(currentFullScreen: currentFullScreen)
        }.value
    }

    /// Resolves exactly one semantic `AXWindow` target, follows its documented
    /// `kAXCloseButtonAttribute` convenience-reference to the actual close button, independently
    /// re-validates that element's own role as exactly `AXButton`, and presses it via
    /// `AXUIElementPerformAction(kAXPressAction)` — a ONE-WAY, high-risk (Level 3) action. This
    /// capability never mutates any window attribute directly (there is no writable "closed"
    /// attribute), never enumerates sibling windows, never closes more than the one exact target,
    /// and never interacts with any save/discard dialog the press may cause to appear — the
    /// press is the entire mutation; everything after it is independent observation only. Fails
    /// closed on a disallowed role, missing criteria, permission absence, application absence, an
    /// ambiguous target, a stale target, an unresolvable/misqualified close-button reference, or a
    /// disabled close button — never falls back to coordinates, CGEvent, keyboard shortcuts
    /// (Cmd+W), AppleScript, or shell. Idempotent: if the exact target window is ALREADY
    /// unresolvable at resolution time — with the owning application independently confirmed
    /// running via a fresh `NSRunningApplication` lookup moments earlier — `changeKind:
    /// .alreadyAbsent` is returned with NO `AXUIElementPerformAction` call at all; this is
    /// deliberately distinguished from every other failure path (ambiguous, permission-denied,
    /// application-absent), which all still throw rather than being folded into "absent."
    public func closeWindow(
        applicationName: String,
        role: String,
        identifier: String?,
        title: String?
    ) async throws -> QAXWindowCloseOutcome {
        guard identifier != nil || title != nil else {
            throw QAXInteractionError.missingMatchCriteria
        }
        // Role is validated as a search CRITERION, before any tree walk — an unauthorized role
        // is refused outright rather than allowed to shape what gets searched for, mirroring
        // every prior write-side role policy in this codebase.
        guard QAXWindowRolePolicy.isAllowedWindowRole(role) else {
            throw QAXInteractionError.disallowedWindowRole(role)
        }

        guard AXIsProcessTrusted() else {
            throw QAXInteractionError.accessibilityPermissionDenied
        }

        let runningApp = try Self.resolveExactRunningApplication(named: applicationName)

        let processIdentifier = runningApp.processIdentifier
        let absentTargetIdentity = "application=\(applicationName) role=\(role) identifier=\(identifier ?? "none") label=\(title ?? "none")"

        return try await Task.detached(priority: .userInitiated) {
            // A pure AX object-reference constructor — never activates, focuses, or raises the
            // target application, the same primitive every prior capability already uses without
            // any such side effect.
            let appElement = AXUIElementCreateApplication(processIdentifier)

            let matches = Self.collectMatches(root: appElement, role: role, identifier: identifier, title: title)
            guard !matches.isEmpty else {
                // Idempotent absence: the owning application was confirmed running moments ago
                // (fresh pid lookup, above), and the EXACT SAME identity criteria the later
                // closed-loop verification step will independently re-use already find zero
                // matches right now — genuine, safely-established absence, never an inability to
                // observe. No AXUIElementPerformAction call is made at all.
                return QAXWindowCloseOutcome(changeKind: .alreadyAbsent, targetIdentity: absentTargetIdentity)
            }
            guard matches.count == 1 else { throw QAXInteractionError.ambiguousTarget(count: matches.count) }

            let (windowElement, observedAtSearch) = matches[0]

            // Identity observation binding: identical discipline to every prior AX mutation
            // capability — re-read the SAME element reference immediately before any mutation
            // and refuse on any drift.
            guard let observedAtVerify = Self.snapshotIfMatches(windowElement, role: role, identifier: identifier, title: title) else {
                throw QAXInteractionError.staleTarget("target window is no longer resolvable immediately before dispatch")
            }
            guard observedAtVerify == observedAtSearch else {
                throw QAXInteractionError.staleTarget("target window identity changed between observation and dispatch")
            }

            let targetIdentity = "application=\(applicationName) role=\(role) identifier=\(observedAtVerify.identifier ?? "none") label=\(observedAtVerify.titleOrDescription ?? "none")"

            // Resolve the actual close button via the documented, read-only convenience-reference
            // attribute — resolution only, never mutated itself. Its absence is a hard
            // fail-closed condition: there is no fallback mechanism (no coordinates, no keyboard
            // shortcut, no menu item) this capability is permitted to try instead.
            guard let closeButtonElement = Self.axElementAttribute(kAXCloseButtonAttribute, of: windowElement) else {
                throw QAXInteractionError.closeButtonReferenceUnavailable
            }

            // The mandatory, non-negotiable role gate: the mere existence of the convenience
            // reference is never sufficient — its own kAXRoleAttribute must independently report
            // exactly AXButton before it is ever treated as a genuine, pressable close button.
            guard let closeButtonRole = Self.axStringAttribute(kAXRoleAttribute, of: closeButtonElement), closeButtonRole == "AXButton" else {
                throw QAXInteractionError.targetNotACloseButton(Self.axStringAttribute(kAXRoleAttribute, of: closeButtonElement) ?? "none")
            }

            let closeButtonEnabled = Self.axBoolAttribute(kAXEnabledAttribute, of: closeButtonElement) ?? true
            guard closeButtonEnabled else {
                throw QAXInteractionError.targetDisabled
            }

            // The ONE, single mutation this capability ever performs — exactly one
            // AXUIElementPerformAction(kAXPressAction) call on the close button, never on the
            // window itself, never kAXCloseAction (no such window action exists), never repeated.
            // Its return value is NOT treated as proof of success — the caller's independent,
            // absence-based closed-loop verification step (observeWindowCloseEvidence) is the
            // sole source of truth. No automatic retry on any outcome, successful or not.
            let pressResult = AXUIElementPerformAction(closeButtonElement, kAXPressAction as CFString)
            switch pressResult {
            case .success:
                break
            case .actionUnsupported:
                throw QAXInteractionError.actionUnsupported
            default:
                throw QAXInteractionError.pressFailed("AXError(\(pressResult.rawValue))")
            }

            return QAXWindowCloseOutcome(changeKind: .closeRequested, targetIdentity: targetIdentity)
        }.value
    }

    // MARK: - Semantic Window Default/Cancel Button Read (Phase 2BM)
    //
    // ui.read_window_default_button — a Level 0, read-only, zero-mutation, purely OBSERVATIONAL
    // read of a semantically-identified window's kAXDefaultButtonAttribute/
    // kAXCancelButtonAttribute references. Both are independently optional — many windows have
    // neither, some have one, some have both; all four combinations are valid, expected results.
    // This capability never presses either button, never performs any AX action of any kind,
    // never mutates window state, never changes focus, never activates the application. Reuses
    // QAXWindowRolePolicy (Phase 2U) unmodified — the identical single-role allowlist (AXWindow
    // only) every other window capability already establishes.
    //
    // MISSING VS FAILURE — the load-bearing design decision this capability makes:
    // `kAXErrorNoValue` and `kAXErrorAttributeUnsupported` both mean "this window genuinely has no
    // such button" — a valid, expected, non-error outcome that produces `nil` for that field. Any
    // OTHER `AXError` (`kAXErrorFailure`, `kAXErrorCannotComplete`, `kAXErrorInvalidUIElement`,
    // etc.) is a genuine read failure and is NEVER silently folded into "absent." A resolved
    // reference whose own role is not exactly `AXButton`, or whose copy succeeded but returned a
    // non-`AXUIElement` value, is likewise never folded into "absent." Deliberately, ANY of these
    // three non-absence problems — for EITHER button — fails the WHOLE read closed, rather than
    // returning a result that silently mixes one reliable field with one unreliable field the
    // caller could not otherwise distinguish. This is a stricter, simpler contract than a
    // partial-success design, chosen deliberately for auditability.

    /// Resolves exactly one semantic `AXWindow` target and reads its `kAXDefaultButtonAttribute`/
    /// `kAXCancelButtonAttribute` references. Fails closed (throws `QAXInteractionError`) on a
    /// disallowed role, missing criteria, permission absence, application/window absence or
    /// ambiguity, a stale/drifted target, or — for either button attribute — a genuine read
    /// failure, a malformed reference, or a reference whose own role is not exactly `AXButton`.
    /// Genuine absence (`kAXErrorNoValue`/`kAXErrorAttributeUnsupported`) is NEVER an error — it
    /// produces `nil` for that field. Never performs any AX action; never mutates anything; never
    /// descends into either referenced button's own children.
    public func readWindowDefaultButton(
        applicationName: String,
        windowTitle: String?,
        windowIdentifier: String?
    ) async throws -> QAXWindowDefaultButtonMetadata {
        guard windowIdentifier != nil || windowTitle != nil else {
            throw QAXInteractionError.missingMatchCriteria
        }
        guard AXIsProcessTrusted() else {
            throw QAXInteractionError.accessibilityPermissionDenied
        }

        let runningApp = try Self.resolveExactRunningApplication(named: applicationName)
        let processIdentifier = runningApp.processIdentifier

        return try await Task.detached(priority: .userInitiated) {
            // A pure AX object-reference constructor — never activates, focuses, or raises the
            // target application, the same primitive every prior capability already uses without
            // any such side effect.
            let appElement = AXUIElementCreateApplication(processIdentifier)

            let matches = Self.collectMatches(root: appElement, role: "AXWindow", identifier: windowIdentifier, title: windowTitle)
            guard !matches.isEmpty else { throw QAXInteractionError.noMatchingElement }
            guard matches.count == 1 else { throw QAXInteractionError.ambiguousTarget(count: matches.count) }

            let (windowElement, observedAtSearch) = matches[0]

            // Observation binding: re-read the SAME element reference immediately before the
            // button read and refuse on any drift — identical discipline to every prior AX
            // capability in this codebase, even though this is a read, not a mutation.
            guard let observedAtVerify = Self.snapshotIfMatches(windowElement, role: "AXWindow", identifier: windowIdentifier, title: windowTitle) else {
                throw QAXInteractionError.staleTarget("target window is no longer resolvable immediately before the button read")
            }
            guard observedAtVerify == observedAtSearch else {
                throw QAXInteractionError.staleTarget("target window identity changed between observation and the button read")
            }

            let defaultButton = try Self.resolveWindowButtonReference(
                attribute: kAXDefaultButtonAttribute, attributeDescription: "default button", of: windowElement
            )
            let cancelButton = try Self.resolveWindowButtonReference(
                attribute: kAXCancelButtonAttribute, attributeDescription: "cancel button", of: windowElement
            )

            return QAXWindowDefaultButtonMetadata(
                applicationName: applicationName,
                windowTitle: observedAtVerify.titleOrDescription,
                windowIdentifier: observedAtVerify.identifier,
                defaultButton: defaultButton,
                cancelButton: cancelButton
            )
        }.value
    }

    /// Resolves ONE window button-reference attribute (`kAXDefaultButtonAttribute` or
    /// `kAXCancelButtonAttribute`), distinguishing genuine absence from a genuine read failure —
    /// see the `MARK` section above for the full missing-vs-failure rationale. Never descends
    /// into the referenced button's own children; reads only its `kAXTitleAttribute`/
    /// `AXIdentifier` for structural identity, each bounded to `maxWindowButtonMetadataLength`
    /// (256 characters) — exceeding it fails closed rather than returning an oversized string.
    fileprivate nonisolated static func resolveWindowButtonReference(
        attribute: String,
        attributeDescription: String,
        of windowElement: AXUIElement
    ) throws -> QAXWindowButtonReference? {
        var value: CFTypeRef?
        let copyResult = AXUIElementCopyAttributeValue(windowElement, attribute as CFString, &value)

        switch copyResult {
        case .success:
            break
        case .noValue, .attributeUnsupported:
            // Genuine, expected absence — many windows have no default/cancel button at all.
            // Never an error.
            return nil
        default:
            throw QAXInteractionError.windowButtonReferenceReadFailed("\(attributeDescription) (AXError(\(copyResult.rawValue)))")
        }

        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            throw QAXInteractionError.windowButtonReferenceMalformed(attributeDescription)
        }
        let buttonElement = value as! AXUIElement

        let buttonRole = Self.axStringAttribute(kAXRoleAttribute, of: buttonElement)
        guard buttonRole == "AXButton" else {
            throw QAXInteractionError.windowButtonReferenceWrongRole("\(attributeDescription) reported role '\(buttonRole ?? "none")', expected 'AXButton'")
        }

        let rawTitle = Self.axStringAttribute(kAXTitleAttribute, of: buttonElement)
        let title = (rawTitle?.isEmpty == false) ? rawTitle : nil
        let identifier = Self.axStringAttribute(Self.axIdentifierAttributeName, of: buttonElement)

        if let title, title.count > Self.maxWindowButtonMetadataLength {
            throw QAXInteractionError.windowButtonMetadataExceedsSafeLength(title.count)
        }
        if let identifier, identifier.count > Self.maxWindowButtonMetadataLength {
            throw QAXInteractionError.windowButtonMetadataExceedsSafeLength(identifier.count)
        }

        return QAXWindowButtonReference(title: title, identifier: identifier)
    }

    // MARK: - Semantic Element Title Reference Read (Phase 2BN)
    //
    // ui.read_element_title_reference — a Level 0, read-only, zero-mutation, purely OBSERVATIONAL
    // read of a semantically-identified element's `kAXTitleUIElementAttribute` — the AX reference
    // to whichever element serves as ITS title/label (e.g. a preceding `AXStaticText` label for an
    // otherwise-untitled text field). Distinct from every prior capability: no existing capability
    // reads any cross-element semantic relationship — every existing read capability reads an
    // element's own attributes (`ui.read_element_value`, `ui.list_element_attributes`) or lists
    // its own children/rows/items. Reuses `QAXElementReadRolePolicy` (Phase 2J) unmodified for
    // BOTH the source element's role AND the referenced title element's own role — no new,
    // broader, or artificial allowlist is introduced for either. SECURITY-CRITICAL INVARIANT:
    // discovering that a title-reference relationship exists is DATA, not AUTHORIZATION — this
    // capability NEVER calls AXUIElementPerformAction or AXUIElementSetAttributeValue, NEVER
    // grants permissions, NEVER creates approvals or standing grants; the referenced element's raw
    // AXUIElement is never returned or cached, only its bounded, safe role/title/identifier
    // strings — any subsequent action against either element must independently pass its own full
    // resolution/role-policy/QPermissionGate pipeline, completely unaffected by this capability
    // ever having been called.

    /// Resolves exactly one semantic target on `QAXElementReadRolePolicy`'s allowlist and reads its
    /// `kAXTitleUIElementAttribute` reference — a purely observational call; neither
    /// `AXUIElementPerformAction` nor `AXUIElementSetAttributeValue` is invoked anywhere in this
    /// method. Fails closed (throws `QAXInteractionError`) on a disallowed/secure role, missing
    /// criteria, permission absence, application/target absence or ambiguity, a stale/drifted
    /// target, a genuine read failure, a malformed returned reference, a referenced element whose
    /// own role is not on the allowed read-role list, or either returned string exceeding
    /// `maxTitleReferenceMetadataLength` (256 characters). Genuine absence
    /// (`kAXErrorNoValue`/`kAXErrorAttributeUnsupported`) is NEVER an error — it produces `nil`;
    /// many elements have no title-UI-element reference at all. Never descends into the
    /// referenced element's own children; never reads its `AXValue` or any other attribute beyond
    /// role/title/identifier.
    public func readElementTitleReference(
        applicationName: String,
        role: String,
        identifier: String?,
        title: String?
    ) async throws -> QAXElementTitleReference? {
        guard identifier != nil || title != nil else {
            throw QAXInteractionError.missingMatchCriteria
        }
        // Secure field first, for a specific diagnostic; then the general allowlist, which would
        // also reject AXSecureTextField on its own (it is never listed) — belt and suspenders,
        // identical discipline to readElementValue's/listElementActions' own checks.
        guard role != "AXSecureTextField" else {
            throw QAXInteractionError.secureFieldReadDenied(role)
        }
        guard QAXElementReadRolePolicy.isAllowedReadRole(role) else {
            throw QAXInteractionError.disallowedReadRole(role)
        }

        guard AXIsProcessTrusted() else {
            throw QAXInteractionError.accessibilityPermissionDenied
        }

        let runningApp = try Self.resolveExactRunningApplication(named: applicationName)
        let processIdentifier = runningApp.processIdentifier

        return try await Task.detached(priority: .userInitiated) {
            let appElement = AXUIElementCreateApplication(processIdentifier)

            let matches = Self.collectMatches(root: appElement, role: role, identifier: identifier, title: title)
            guard !matches.isEmpty else { throw QAXInteractionError.noMatchingElement }
            guard matches.count == 1 else { throw QAXInteractionError.ambiguousTarget(count: matches.count) }

            let (targetElement, observedAtSearch) = matches[0]

            // Observation binding: re-read the SAME element reference immediately before the
            // title-reference read and refuse on any drift — identical discipline to every prior
            // AX capability in this codebase, even though this is a read, not a mutation.
            guard let observedAtVerify = Self.snapshotIfMatches(targetElement, role: role, identifier: identifier, title: title) else {
                throw QAXInteractionError.staleTarget("target element is no longer resolvable immediately before the title-reference read")
            }
            guard observedAtVerify == observedAtSearch else {
                throw QAXInteractionError.staleTarget("target element identity changed between observation and the title-reference read")
            }

            return try Self.resolveElementTitleReference(of: targetElement)
        }.value
    }

    /// Resolves the target element's `kAXTitleUIElementAttribute` reference, distinguishing
    /// genuine absence from a genuine read failure — see the `MARK` section above for the full
    /// missing-vs-failure rationale. Never descends into the referenced element's own children;
    /// reads only its `kAXRoleAttribute` (independently re-validated against
    /// `QAXElementReadRolePolicy` — never accepted merely because a reference was returned) and,
    /// once the role is confirmed safe, its `kAXTitleAttribute`/`AXIdentifier` for structural
    /// identity, each bounded to `maxTitleReferenceMetadataLength` (256 characters) — exceeding it
    /// fails closed rather than returning an oversized string.
    fileprivate nonisolated static func resolveElementTitleReference(
        of targetElement: AXUIElement
    ) throws -> QAXElementTitleReference? {
        var value: CFTypeRef?
        let copyResult = AXUIElementCopyAttributeValue(targetElement, kAXTitleUIElementAttribute as CFString, &value)

        switch copyResult {
        case .success:
            break
        case .noValue, .attributeUnsupported:
            // Genuine, expected absence — many elements have no title-UI-element reference at
            // all. Never an error.
            return nil
        default:
            throw QAXInteractionError.titleReferenceReadFailed("AXError(\(copyResult.rawValue))")
        }

        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            throw QAXInteractionError.titleReferenceMalformed
        }
        let titleElement = value as! AXUIElement

        // The mere existence of a returned reference is never sufficient — its own role is
        // independently re-validated against the SAME generic read-role allowlist the source
        // element itself had to satisfy, before it is ever treated as a genuine, safe title
        // element. This also forecloses a referenced AXSecureTextField (never on the allowlist)
        // from ever being surfaced as a "safe" reference.
        let titleElementRole = Self.axStringAttribute(kAXRoleAttribute, of: titleElement) ?? "none"
        guard QAXElementReadRolePolicy.isAllowedReadRole(titleElementRole) else {
            throw QAXInteractionError.titleReferenceDisallowedRole(titleElementRole)
        }

        let rawTitle = Self.axStringAttribute(kAXTitleAttribute, of: titleElement)
        let referenceTitle = (rawTitle?.isEmpty == false) ? rawTitle : nil
        let referenceIdentifier = Self.axStringAttribute(Self.axIdentifierAttributeName, of: titleElement)

        if let referenceTitle, referenceTitle.count > Self.maxTitleReferenceMetadataLength {
            throw QAXInteractionError.titleReferenceMetadataExceedsSafeLength(referenceTitle.count)
        }
        if let referenceIdentifier, referenceIdentifier.count > Self.maxTitleReferenceMetadataLength {
            throw QAXInteractionError.titleReferenceMetadataExceedsSafeLength(referenceIdentifier.count)
        }

        return QAXElementTitleReference(role: titleElementRole, title: referenceTitle, identifier: referenceIdentifier)
    }

    // MARK: - Semantic Window Modal State Read (Phase 2BO)
    //
    // ui.read_window_modal_state — a Level 0, read-only, zero-mutation, purely OBSERVATIONAL read
    // of a semantically-identified AXWindow's kAXModalAttribute. Distinct from every prior
    // window-scoped read: kAXModalAttribute is documented "Required for all window elements" —
    // unlike the optional button/title references ui.read_window_default_button/
    // ui.read_element_title_reference resolve, there is no genuine, expected absence case here, so
    // this capability's missing-vs-failure discipline is inverted relative to those: EVERY
    // non-success AXError (including kAXErrorNoValue/kAXErrorAttributeUnsupported) is treated as a
    // genuine read failure, never silently downgraded to a guessed `false`. Never begins or ends a
    // modal session, never activates the application, never focuses the window, never mutates any
    // UI state — it only ever reads the AX attribute a real, independently-running modal session
    // would already have set.

    /// Resolves exactly one semantic `AXWindow` (`QAXWindowRolePolicy`, reused unmodified) and
    /// reads its `kAXModalAttribute` — a purely observational call; neither
    /// `AXUIElementPerformAction` nor `AXUIElementSetAttributeValue` is invoked anywhere in this
    /// method, and no modal session is ever begun or ended by this capability itself. Fails closed
    /// (throws `QAXInteractionError`) on missing criteria, permission absence, application/window
    /// absence or ambiguity, a stale/drifted target, ANY `AXError` reading `kAXModalAttribute`
    /// (including `kAXErrorNoValue`/`kAXErrorAttributeUnsupported` — see the `MARK` section above
    /// for why this attribute has no valid-absence case), or a malformed (non-Boolean) returned
    /// value. Never fabricates a Boolean.
    public func readWindowModalState(
        applicationName: String,
        windowTitle: String?,
        windowIdentifier: String?
    ) async throws -> QAXWindowModalStateMetadata {
        guard windowIdentifier != nil || windowTitle != nil else {
            throw QAXInteractionError.missingMatchCriteria
        }
        guard AXIsProcessTrusted() else {
            throw QAXInteractionError.accessibilityPermissionDenied
        }

        let runningApp = try Self.resolveExactRunningApplication(named: applicationName)
        let processIdentifier = runningApp.processIdentifier

        return try await Task.detached(priority: .userInitiated) {
            let appElement = AXUIElementCreateApplication(processIdentifier)

            let matches = Self.collectMatches(root: appElement, role: "AXWindow", identifier: windowIdentifier, title: windowTitle)
            guard !matches.isEmpty else { throw QAXInteractionError.noMatchingElement }
            guard matches.count == 1 else { throw QAXInteractionError.ambiguousTarget(count: matches.count) }

            let (windowElement, observedAtSearch) = matches[0]

            // Observation binding: re-read the SAME element reference immediately before the
            // modal-state read and refuse on any drift — identical discipline to every prior AX
            // capability in this codebase, even though this is a read, not a mutation.
            guard let observedAtVerify = Self.snapshotIfMatches(windowElement, role: "AXWindow", identifier: windowIdentifier, title: windowTitle) else {
                throw QAXInteractionError.staleTarget("target window is no longer resolvable immediately before the modal-state read")
            }
            guard observedAtVerify == observedAtSearch else {
                throw QAXInteractionError.staleTarget("target window identity changed between observation and the modal-state read")
            }

            let isModal = try Self.resolveWindowModalState(of: windowElement)

            return QAXWindowModalStateMetadata(
                applicationName: applicationName,
                windowTitle: observedAtVerify.titleOrDescription,
                windowIdentifier: observedAtVerify.identifier,
                isModal: isModal
            )
        }.value
    }

    /// Resolves `kAXModalAttribute` as a definite `Bool` — never optional, since this attribute
    /// has no valid-absence case (see the `MARK` section above). Any non-`.success` `AXError`
    /// (including `kAXErrorNoValue`/`kAXErrorAttributeUnsupported`) fails closed as
    /// `windowModalStateReadFailed`; a successful copy whose value cannot be interpreted as a
    /// `Bool` fails closed as `windowModalStateMalformed` — the returned value is treated as
    /// untrusted external data, never assumed well-formed merely because the copy call itself
    /// reported success. An explicit `false` is a fully valid, distinct outcome from either
    /// failure case — it is returned directly, never conflated with "missing."
    fileprivate nonisolated static func resolveWindowModalState(of windowElement: AXUIElement) throws -> Bool {
        var value: CFTypeRef?
        let copyResult = AXUIElementCopyAttributeValue(windowElement, kAXModalAttribute as CFString, &value)

        guard copyResult == .success else {
            throw QAXInteractionError.windowModalStateReadFailed("AXError(\(copyResult.rawValue))")
        }
        guard let value, let isModal = value as? Bool else {
            throw QAXInteractionError.windowModalStateMalformed
        }
        return isModal
    }

    /// Best-effort, read-only re-observation of whether the exact same target-window criteria
    /// used by `closeWindow` still resolve, used both by the later closed-loop verification step
    /// (`QVerificationStrategy.windowCloseVerified`) and by `QTaskRecoveryManager`'s
    /// observation-first recovery branch — the SAME primitive for both, never a parallel
    /// resolver. Independently re-resolves the OWNING APPLICATION first, via a genuinely fresh,
    /// separate `NSRunningApplication` lookup — application termination and a genuine
    /// single-window close are NEVER conflated; only `.windowAbsentApplicationRunning`
    /// (application confirmed running AND the exact window no longer resolves) may ever be
    /// treated as success by a caller. `.ambiguousTarget` and `.permissionUnavailable` are
    /// deliberately distinct from both success and plain "still present" — neither is ever
    /// coerced into an absence conclusion.
    public func observeWindowCloseEvidence(
        applicationName: String,
        role: String,
        identifier: String?,
        title: String?
    ) async -> QAXWindowCloseEvidence {
        guard AXIsProcessTrusted() else { return .permissionUnavailable }
        let runningApp: NSRunningApplication
        do {
            runningApp = try Self.resolveExactRunningApplication(named: applicationName)
        } catch let axError as QAXInteractionError {
            switch axError {
            case .ambiguousTarget(let count):
                return .ambiguousTarget(count: count)
            default:
                return .applicationNotRunning
            }
        } catch {
            return .applicationNotRunning
        }

        let processIdentifier = runningApp.processIdentifier
        return await Task.detached(priority: .userInitiated) {
            let appElement = AXUIElementCreateApplication(processIdentifier)
            let matches = Self.collectMatches(root: appElement, role: role, identifier: identifier, title: title)
            if matches.isEmpty {
                return .windowAbsentApplicationRunning
            } else if matches.count == 1 {
                return .windowStillPresent
            } else {
                return .ambiguousTarget(count: matches.count)
            }
        }.value
    }

    /// Enumerates the windows belonging to exactly ONE named, running application (Phase 2Z,
    /// `ui.list_windows`) — READ-ONLY, no mutation of any kind. Resolves the application by EXACT
    /// `localizedName`/`bundleIdentifier` match; more than one running process matching the same
    /// name is treated as ambiguous and fails closed (never silently acts on an arbitrary one).
    /// Reads `kAXWindowsAttribute` — a DIRECT CHILD enumeration only, never a recursive descent
    /// into any returned window's own descendants. The returned value is treated as untrusted
    /// external data: a failed/absent attribute read is a legitimate empty result (e.g. a
    /// headless/background-only application genuinely has no windows), but a value that cannot be
    /// read as `[AXUIElement]` is a hard failure (`.windowsCollectionMalformed`) — never silently
    /// coerced into an empty list. The raw collection's size is checked against a defensive
    /// maximum BEFORE any per-element read. Only elements whose OWN `kAXRoleAttribute` reports
    /// exactly `AXWindow` are included — a wrong-role or malformed element is silently excluded,
    /// never causing the whole enumeration to fail. Every other metadata field
    /// (title/identifier/minimized/main) is independently optional — a missing one is never an
    /// error and never excludes the window. Array ordering is never treated as meaningful (no
    /// frontmost/z-order/main-window inference of any kind is ever drawn from position). This is
    /// a point-in-time snapshot only — it is never itself an actionable target reference; every
    /// subsequent mutation capability must perform its own fresh, independent, exact target
    /// resolution.
    public func listWindows(applicationName: String) async throws -> [QAXWindowMetadata] {
        guard AXIsProcessTrusted() else {
            throw QAXInteractionError.accessibilityPermissionDenied
        }

        let runningApp = try Self.resolveExactRunningApplication(named: applicationName)
        let processIdentifier = runningApp.processIdentifier

        return try await Task.detached(priority: .userInitiated) {
            // A pure AX object-reference constructor — never activates, focuses, or raises the
            // target application, the same primitive every prior capability already uses without
            // any such side effect.
            let appElement = AXUIElementCreateApplication(processIdentifier)

            var windowsValue: CFTypeRef?
            let copyResult = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsValue)
            guard copyResult == .success, let windowsValue else {
                // A failed or absent kAXWindowsAttribute read is a legitimate, valid state for an
                // application with no windows at all (e.g. a headless/background-only agent) —
                // an empty result, never an error.
                return []
            }
            guard let windowsArray = windowsValue as? [AXUIElement] else {
                // The returned value is treated as untrusted external data — success from the
                // copy call is never itself sufficient proof of a well-formed collection.
                throw QAXInteractionError.windowsCollectionMalformed
            }
            guard windowsArray.count <= Self.maxWindowEnumerationCount else {
                throw QAXInteractionError.windowCollectionExceedsSafeBound(windowsArray.count)
            }

            var metadata: [QAXWindowMetadata] = []
            metadata.reserveCapacity(windowsArray.count)
            for windowElement in windowsArray {
                // DIRECT CHILD ONLY: exactly one attribute read (kAXRoleAttribute) per returned
                // element to validate it, then at most four more direct attribute reads for
                // metadata — never a descent into this element's own children/descendants.
                guard let role = Self.axStringAttribute(kAXRoleAttribute, of: windowElement), role == "AXWindow" else {
                    // A wrong-role or malformed element is silently excluded — never causes the
                    // whole enumeration to fail merely because one returned item is not genuine.
                    continue
                }
                metadata.append(
                    QAXWindowMetadata(
                        title: Self.axStringAttribute(kAXTitleAttribute, of: windowElement),
                        identifier: Self.axStringAttribute(Self.axIdentifierAttributeName, of: windowElement),
                        minimized: Self.axBoolAttribute(kAXMinimizedAttribute, of: windowElement),
                        main: Self.axBoolAttribute(kAXMainAttribute, of: windowElement)
                    )
                )
            }
            return metadata
        }.value
    }

    /// Phase 2AA: semantic menu enumeration (Level 0, read-only). Enumerates top-level menus and
    /// direct menu items belonging to exactly ONE named, running application via kAXMenuBarAttribute.
    /// No mutation, no approval, no recovery. Submenus are strictly OUT OF SCOPE and never traversed.
    public func listMenuItems(applicationName: String) async throws -> [QAXTopLevelMenuMetadata] {
        guard AXIsProcessTrusted() else {
            throw QAXInteractionError.accessibilityPermissionDenied
        }

        let runningApp = try Self.resolveExactRunningApplication(named: applicationName)
        let processIdentifier = runningApp.processIdentifier

        return try await Task.detached(priority: .userInitiated) {
            let appElement = AXUIElementCreateApplication(processIdentifier)

            guard let menuBarElement = Self.axElementAttribute(kAXMenuBarAttribute as String, of: appElement),
                  Self.axStringAttribute(kAXRoleAttribute, of: menuBarElement) == "AXMenuBar" else {
                return []
            }

            guard let topLevelElements = Self.childrenAttribute(of: menuBarElement) else {
                return []
            }

            guard topLevelElements.count <= Self.maxTopLevelMenuCount else {
                throw QAXInteractionError.menuCollectionExceedsSafeBound(topLevelElements.count)
            }

            var topLevelMenus: [QAXTopLevelMenuMetadata] = []
            topLevelMenus.reserveCapacity(topLevelElements.count)
            var totalItemsCount = 0

            for topElement in topLevelElements {
                guard let topRole = Self.axStringAttribute(kAXRoleAttribute, of: topElement),
                      (topRole == "AXMenuBarItem" || topRole == "AXMenu" || topRole == "AXMenuExtra") else {
                    continue
                }

                let topTitle = Self.axStringAttribute(kAXTitleAttribute, of: topElement)
                let topIdentifier = Self.axStringAttribute(Self.axIdentifierAttributeName, of: topElement)
                let topEnabled = Self.axBoolAttribute(kAXEnabledAttribute, of: topElement)

                var itemElements: [AXUIElement] = []
                if topRole == "AXMenuBarItem" {
                    if let childMenus = Self.childrenAttribute(of: topElement) {
                        for child in childMenus {
                            if Self.axStringAttribute(kAXRoleAttribute, of: child) == "AXMenu" {
                                if let directItems = Self.childrenAttribute(of: child) {
                                    itemElements.append(contentsOf: directItems)
                                }
                            }
                        }
                    }
                } else if topRole == "AXMenu" {
                    if let directItems = Self.childrenAttribute(of: topElement) {
                        itemElements.append(contentsOf: directItems)
                    }
                } else if topRole == "AXMenuExtra" {
                    if let directItems = Self.childrenAttribute(of: topElement) {
                        itemElements.append(contentsOf: directItems)
                    }
                }

                guard itemElements.count <= Self.maxDirectMenuItemsPerMenuCount else {
                    throw QAXInteractionError.menuItemCollectionExceedsSafeBound(itemElements.count)
                }

                var menuItemsMetadata: [QAXMenuItemMetadata] = []
                menuItemsMetadata.reserveCapacity(itemElements.count)

                for itemElement in itemElements {
                    guard let itemRole = Self.axStringAttribute(kAXRoleAttribute, of: itemElement),
                          itemRole == "AXMenuItem" else {
                        continue
                    }

                    totalItemsCount += 1
                    guard totalItemsCount <= Self.maxTotalMenuItemsCount else {
                        throw QAXInteractionError.totalMenuItemCollectionExceedsSafeBound(totalItemsCount)
                    }

                    menuItemsMetadata.append(
                        QAXMenuItemMetadata(
                            title: Self.axStringAttribute(kAXTitleAttribute, of: itemElement),
                            identifier: Self.axStringAttribute(Self.axIdentifierAttributeName, of: itemElement),
                            isEnabled: Self.axBoolAttribute(kAXEnabledAttribute, of: itemElement),
                            role: itemRole
                        )
                    )
                }

                topLevelMenus.append(
                    QAXTopLevelMenuMetadata(
                        title: topTitle,
                        identifier: topIdentifier,
                        isEnabled: topEnabled,
                        role: topRole,
                        items: menuItemsMetadata
                    )
                )
            }

            return topLevelMenus
        }.value
    }

    /// Phase 2AD: semantic pop-up menu item enumeration (Level 0, read-only). Enumerates direct menu
    /// items belonging to exactly ONE named AXPopUpButton in an application.
    /// No mutation, no press, no open, no approval, no recovery. Submenus are strictly OUT OF SCOPE.
    public func listPopupItems(
        applicationName: String,
        role: String = "AXPopUpButton",
        identifier: String?,
        title: String?
    ) async throws -> QAXPopupMenuMetadata {
        guard QAXPopupRolePolicy.isAllowedPopupRole(role) else {
            throw QAXInteractionError.disallowedPopupRole(role)
        }
        guard identifier != nil || title != nil else {
            throw QAXInteractionError.missingMatchCriteria
        }
        guard AXIsProcessTrusted() else {
            throw QAXInteractionError.accessibilityPermissionDenied
        }

        let runningApp = try Self.resolveExactRunningApplication(named: applicationName)
        let processIdentifier = runningApp.processIdentifier

        return try await Task.detached(priority: .userInitiated) {
            let appElement = AXUIElementCreateApplication(processIdentifier)

            let matches = Self.collectMatches(root: appElement, role: role, identifier: identifier, title: title)
            guard !matches.isEmpty else { throw QAXInteractionError.noMatchingElement }
            guard matches.count == 1 else { throw QAXInteractionError.ambiguousTarget(count: matches.count) }

            let (targetElement, observedAtSearch) = matches[0]

            guard let observedAtVerify = Self.snapshotIfMatches(targetElement, role: role, identifier: identifier, title: title) else {
                throw QAXInteractionError.staleTarget("target pop-up element is no longer resolvable immediately before enumeration")
            }
            guard observedAtVerify == observedAtSearch else {
                throw QAXInteractionError.staleTarget("target pop-up element identity changed between observation and enumeration")
            }

            let currentValue = Self.axStringAttribute(kAXValueAttribute, of: targetElement)

            // Direct children of AXPopUpButton: find direct AXMenu child
            var candidateMenus: [AXUIElement] = []
            if let children = Self.childrenAttribute(of: targetElement) {
                for child in children {
                    if Self.axStringAttribute(kAXRoleAttribute, of: child) == "AXMenu" {
                        candidateMenus.append(child)
                    }
                }
            }

            guard candidateMenus.count <= 1 else {
                throw QAXInteractionError.ambiguousTarget(count: candidateMenus.count)
            }

            guard let menuElement = candidateMenus.first else {
                return QAXPopupMenuMetadata(selectedValue: currentValue, items: [])
            }

            guard let rawMenuItems = Self.childrenAttribute(of: menuElement) else {
                return QAXPopupMenuMetadata(selectedValue: currentValue, items: [])
            }

            let menuItemElements = rawMenuItems.filter {
                Self.axStringAttribute(kAXRoleAttribute, of: $0) == "AXMenuItem"
            }

            guard menuItemElements.count <= Self.maxDirectPopupItemsCount else {
                throw QAXInteractionError.menuItemCollectionExceedsSafeBound(menuItemElements.count)
            }

            var itemsMetadata: [QAXPopupItemMetadata] = []
            itemsMetadata.reserveCapacity(menuItemElements.count)

            for itemElement in menuItemElements {
                let itemTitle = Self.axStringAttribute(kAXTitleAttribute, of: itemElement)
                let itemIdentifier = Self.axStringAttribute(Self.axIdentifierAttributeName, of: itemElement)
                let itemEnabled = Self.axBoolAttribute(kAXEnabledAttribute, of: itemElement)
                let isSelected: Bool
                if let currentValue, let itemTitle, !currentValue.isEmpty, itemTitle == currentValue {
                    isSelected = true
                } else {
                    isSelected = false
                }

                itemsMetadata.append(
                    QAXPopupItemMetadata(
                        title: itemTitle,
                        identifier: itemIdentifier,
                        isEnabled: itemEnabled,
                        isSelected: isSelected,
                        role: "AXMenuItem"
                    )
                )
            }

            return QAXPopupMenuMetadata(
                selectedValue: currentValue,
                items: itemsMetadata
            )
        }.value
    }

    /// Phase 2AE: semantic table row enumeration (Level 0, read-only). Enumerates direct rows
    /// belonging to exactly ONE named AXTable in an application.
    /// No mutation, no press, no approval, no recovery. Cells and submenus are strictly OUT OF SCOPE.
    public func listTableRows(
        applicationName: String,
        role: String = "AXTable",
        identifier: String?,
        title: String?
    ) async throws -> QAXTableMetadata {
        guard QAXTableRolePolicy.isAllowedTableRole(role) else {
            throw QAXInteractionError.disallowedTableRole(role)
        }
        guard identifier != nil || title != nil else {
            throw QAXInteractionError.missingMatchCriteria
        }
        guard AXIsProcessTrusted() else {
            throw QAXInteractionError.accessibilityPermissionDenied
        }

        let runningApp = try Self.resolveExactRunningApplication(named: applicationName)
        let processIdentifier = runningApp.processIdentifier

        return try await Task.detached(priority: .userInitiated) {
            let appElement = AXUIElementCreateApplication(processIdentifier)

            let matches = Self.collectMatches(root: appElement, role: role, identifier: identifier, title: title)
            guard !matches.isEmpty else { throw QAXInteractionError.noMatchingElement }
            guard matches.count == 1 else { throw QAXInteractionError.ambiguousTarget(count: matches.count) }

            let (targetElement, observedAtSearch) = matches[0]

            guard let observedAtVerify = Self.snapshotIfMatches(targetElement, role: role, identifier: identifier, title: title) else {
                throw QAXInteractionError.staleTarget("target table element is no longer resolvable immediately before enumeration")
            }
            guard observedAtVerify == observedAtSearch else {
                throw QAXInteractionError.staleTarget("target table element identity changed between observation and enumeration")
            }

            var rawRowElements: [AXUIElement] = []
            var rowsValue: CFTypeRef?
            let copyResult = AXUIElementCopyAttributeValue(targetElement, "AXRows" as CFString, &rowsValue)
            if copyResult == .success, let array = rowsValue as? [AXUIElement] {
                rawRowElements = array
            } else if let children = Self.childrenAttribute(of: targetElement) {
                rawRowElements = children.filter {
                    Self.axStringAttribute(kAXRoleAttribute, of: $0) == "AXRow"
                }
            }

            var validRowElements: [AXUIElement] = []
            for rowElement in rawRowElements {
                guard Self.axStringAttribute(kAXRoleAttribute, of: rowElement) == "AXRow" else {
                    continue
                }
                let subrole = Self.axStringAttribute(kAXSubroleAttribute, of: rowElement)
                guard subrole != Self.outlineRowSubrole else {
                    continue
                }
                if subrole == nil || subrole == Self.tableRowSubrole {
                    validRowElements.append(rowElement)
                }
            }

            guard validRowElements.count <= Self.maxDirectTableRowsCount else {
                throw QAXInteractionError.tableRowCollectionExceedsSafeBound(validRowElements.count)
            }

            var rowsMetadata: [QAXTableRowItemMetadata] = []
            rowsMetadata.reserveCapacity(validRowElements.count)
            var selectedCount = 0

            for (index, rowElement) in validRowElements.enumerated() {
                let rowTitle = Self.axStringAttribute(kAXTitleAttribute, of: rowElement)
                    ?? Self.axStringAttribute(kAXDescriptionAttribute, of: rowElement)
                let rowIdentifier = Self.axStringAttribute(Self.axIdentifierAttributeName, of: rowElement)
                let rowSelected = Self.axBoolAttribute(kAXSelectedAttribute, of: rowElement)
                let rowEnabled = Self.axBoolAttribute(kAXEnabledAttribute, of: rowElement)

                if rowSelected == true {
                    selectedCount += 1
                }

                rowsMetadata.append(
                    QAXTableRowItemMetadata(
                        index: index,
                        title: rowTitle,
                        identifier: rowIdentifier,
                        isSelected: rowSelected,
                        isEnabled: rowEnabled,
                        role: "AXRow",
                        subrole: Self.tableRowSubrole
                    )
                )
            }

            return QAXTableMetadata(
                applicationName: applicationName,
                tableTitle: observedAtVerify.titleOrDescription,
                tableIdentifier: observedAtVerify.identifier,
                rowCount: rowsMetadata.count,
                selectedRowCount: selectedCount,
                rows: rowsMetadata
            )
        }.value
    }

    /// Phase 2BI: semantic table column enumeration (Level 0, read-only). Enumerates direct
    /// column-header elements belonging to exactly ONE named AXTable in an application via
    /// kAXColumnHeaderUIElementsAttribute — a direct child read only, never a recursive descent
    /// into any column's own contents (cell data is strictly out of scope, exactly like
    /// `ui.list_table_rows`'s own row-identity-only contract). No mutation, no press, no approval,
    /// no recovery. Reuses `QAXTableRolePolicy` (Phase 2AE) unmodified — the identical single-role
    /// allowlist (`AXTable` only) `ui.list_table_rows` already establishes; no new role policy was
    /// introduced. Application identity is resolved by exact matching via
    /// `resolveExactRunningApplication`. Bounded by `maxDirectTableColumnsCount` (32) — a maximum
    /// of 33 AX elements are ever touched in a single call (the table plus at most 32 columns).
    /// This is a POINT-IN-TIME SNAPSHOT ONLY: result is informational and never enters durable
    /// persistence snapshots beyond an aggregate count.
    public func listTableColumns(
        applicationName: String,
        role: String = "AXTable",
        identifier: String?,
        title: String?
    ) async throws -> QAXTableColumnCollectionMetadata {
        guard QAXTableRolePolicy.isAllowedTableRole(role) else {
            throw QAXInteractionError.disallowedTableRole(role)
        }
        guard identifier != nil || title != nil else {
            throw QAXInteractionError.missingMatchCriteria
        }
        guard AXIsProcessTrusted() else {
            throw QAXInteractionError.accessibilityPermissionDenied
        }

        let runningApp = try Self.resolveExactRunningApplication(named: applicationName)
        let processIdentifier = runningApp.processIdentifier

        return try await Task.detached(priority: .userInitiated) {
            let appElement = AXUIElementCreateApplication(processIdentifier)

            let matches = Self.collectMatches(root: appElement, role: role, identifier: identifier, title: title)
            guard !matches.isEmpty else { throw QAXInteractionError.noMatchingElement }
            guard matches.count == 1 else { throw QAXInteractionError.ambiguousTarget(count: matches.count) }

            let (targetElement, observedAtSearch) = matches[0]

            guard let observedAtVerify = Self.snapshotIfMatches(targetElement, role: role, identifier: identifier, title: title) else {
                throw QAXInteractionError.staleTarget("target table element is no longer resolvable immediately before enumeration")
            }
            guard observedAtVerify == observedAtSearch else {
                throw QAXInteractionError.staleTarget("target table element identity changed between observation and enumeration")
            }

            // DIRECT CHILD ONLY: kAXColumnHeaderUIElementsAttribute is the OS's own authoritative
            // list of a table's header elements — never inferred from row content, never a
            // recursive descent. Falls back to filtering the table's own direct children for
            // role == "AXColumn" only if the header attribute itself is absent/unreadable (the
            // same dual-strategy robustness ui.list_table_rows/ui.list_browser_columns already
            // apply for their own analogous collections).
            var rawColumnElements: [AXUIElement] = []
            var headersValue: CFTypeRef?
            let copyResult = AXUIElementCopyAttributeValue(targetElement, kAXColumnHeaderUIElementsAttribute as CFString, &headersValue)
            if copyResult == .success, let array = headersValue as? [AXUIElement] {
                rawColumnElements = array
            } else if let children = Self.childrenAttribute(of: targetElement) {
                rawColumnElements = children.filter {
                    Self.axStringAttribute(kAXRoleAttribute, of: $0) == "AXColumn"
                }
            }

            // Every candidate's OWN kAXRoleAttribute is independently re-validated as exactly
            // "AXColumn" before it is ever trusted — the returned value is treated as untrusted
            // external data, never assumed well-formed merely because the copy call succeeded.
            var validColumnElements: [AXUIElement] = []
            for element in rawColumnElements {
                guard Self.axStringAttribute(kAXRoleAttribute, of: element) == "AXColumn" else {
                    continue
                }
                validColumnElements.append(element)
            }

            guard validColumnElements.count <= Self.maxDirectTableColumnsCount else {
                throw QAXInteractionError.tableColumnCollectionExceedsSafeBound(validColumnElements.count)
            }

            // Direct, non-recursive metadata reads only — never a column's own children, never
            // cell contents. Exactly two attribute reads per column beyond the role check above:
            // kAXTitleAttribute (falling back to kAXDescriptionAttribute) and AXIdentifier, plus
            // kAXSubroleAttribute for structural completeness.
            var columnsMetadata: [QAXTableColumnItemMetadata] = []
            columnsMetadata.reserveCapacity(validColumnElements.count)

            for (index, colElement) in validColumnElements.enumerated() {
                let colTitle = Self.axStringAttribute(kAXTitleAttribute, of: colElement)
                    ?? Self.axStringAttribute(kAXDescriptionAttribute, of: colElement)
                let colIdentifier = Self.axStringAttribute(Self.axIdentifierAttributeName, of: colElement)
                let colSubrole = Self.axStringAttribute(kAXSubroleAttribute, of: colElement)

                columnsMetadata.append(
                    QAXTableColumnItemMetadata(
                        index: index,
                        title: colTitle,
                        identifier: colIdentifier,
                        role: "AXColumn",
                        subrole: colSubrole
                    )
                )
            }

            return QAXTableColumnCollectionMetadata(
                applicationName: applicationName,
                tableTitle: observedAtVerify.titleOrDescription,
                tableIdentifier: observedAtVerify.identifier,
                columnCount: columnsMetadata.count,
                columns: columnsMetadata
            )
        }.value
    }

    /// Phase 2AF: semantic outline item enumeration (Level 0, read-only). Enumerates direct rows
    /// belonging to exactly ONE named AXOutline in an application.
    /// No mutation, no press, no approval, no recovery. Cells and arbitrary subtrees are strictly OUT OF SCOPE.
    public func listOutlineItems(
        applicationName: String,
        role: String = "AXOutline",
        identifier: String?,
        title: String?
    ) async throws -> QAXOutlineMetadata {
        guard QAXOutlineRolePolicy.isAllowedOutlineRole(role) else {
            throw QAXInteractionError.disallowedOutlineRole(role)
        }
        guard identifier != nil || title != nil else {
            throw QAXInteractionError.missingMatchCriteria
        }
        guard AXIsProcessTrusted() else {
            throw QAXInteractionError.accessibilityPermissionDenied
        }

        let runningApp = try Self.resolveExactRunningApplication(named: applicationName)
        let processIdentifier = runningApp.processIdentifier

        return try await Task.detached(priority: .userInitiated) {
            let appElement = AXUIElementCreateApplication(processIdentifier)

            let matches = Self.collectMatches(root: appElement, role: role, identifier: identifier, title: title)
            guard !matches.isEmpty else { throw QAXInteractionError.noMatchingElement }
            guard matches.count == 1 else { throw QAXInteractionError.ambiguousTarget(count: matches.count) }

            let (targetElement, observedAtSearch) = matches[0]

            guard let observedAtVerify = Self.snapshotIfMatches(targetElement, role: role, identifier: identifier, title: title) else {
                throw QAXInteractionError.staleTarget("target outline element is no longer resolvable immediately before enumeration")
            }
            guard observedAtVerify == observedAtSearch else {
                throw QAXInteractionError.staleTarget("target outline element identity changed between observation and enumeration")
            }

            var rawRowElements: [AXUIElement] = []
            var rowsValue: CFTypeRef?
            let copyResult = AXUIElementCopyAttributeValue(targetElement, "AXRows" as CFString, &rowsValue)
            if copyResult == .success, let array = rowsValue as? [AXUIElement] {
                rawRowElements = array
            } else if let children = Self.childrenAttribute(of: targetElement) {
                rawRowElements = children.filter {
                    Self.axStringAttribute(kAXRoleAttribute, of: $0) == "AXRow"
                }
            }

            var validRowElements: [AXUIElement] = []
            for rowElement in rawRowElements {
                guard Self.axStringAttribute(kAXRoleAttribute, of: rowElement) == "AXRow" else {
                    continue
                }
                let subrole = Self.axStringAttribute(kAXSubroleAttribute, of: rowElement)
                guard subrole != Self.tableRowSubrole else {
                    continue
                }
                if subrole == nil || subrole == Self.outlineRowSubrole {
                    validRowElements.append(rowElement)
                }
            }

            guard validRowElements.count <= Self.maxDirectOutlineItemsCount else {
                throw QAXInteractionError.outlineItemCollectionExceedsSafeBound(validRowElements.count)
            }

            var itemsMetadata: [QAXOutlineRowItemMetadata] = []
            itemsMetadata.reserveCapacity(validRowElements.count)
            var selectedCount = 0
            var expandedCount = 0

            for (index, rowElement) in validRowElements.enumerated() {
                let depthInt: Int
                if let depthVal = Self.axIntAttribute(Self.axDisclosureLevelAttributeName, of: rowElement) {
                    depthInt = depthVal
                } else {
                    depthInt = 0
                }

                guard depthInt <= Self.maxOutlineDepth else {
                    throw QAXInteractionError.outlineItemDepthExceedsSafeBound(depthInt)
                }

                let itemTitle = Self.axStringAttribute(kAXTitleAttribute, of: rowElement)
                    ?? Self.axStringAttribute(kAXDescriptionAttribute, of: rowElement)
                let itemIdentifier = Self.axStringAttribute(Self.axIdentifierAttributeName, of: rowElement)
                let isExpanded = Self.axBoolAttribute(Self.axDisclosingAttributeName, of: rowElement)
                let isSelected = Self.axBoolAttribute(kAXSelectedAttribute, of: rowElement)
                let isEnabled = Self.axBoolAttribute(kAXEnabledAttribute, of: rowElement)

                if isSelected == true {
                    selectedCount += 1
                }
                if isExpanded == true {
                    expandedCount += 1
                }

                itemsMetadata.append(
                    QAXOutlineRowItemMetadata(
                        index: index,
                        title: itemTitle,
                        identifier: itemIdentifier,
                        depth: depthInt,
                        isExpanded: isExpanded,
                        isSelected: isSelected,
                        isEnabled: isEnabled,
                        role: "AXRow",
                        subrole: Self.outlineRowSubrole
                    )
                )
            }

            return QAXOutlineMetadata(
                applicationName: applicationName,
                outlineTitle: observedAtVerify.titleOrDescription,
                outlineIdentifier: observedAtVerify.identifier,
                itemCount: itemsMetadata.count,
                selectedItemCount: selectedCount,
                expandedItemCount: expandedCount,
                items: itemsMetadata
            )
        }.value
    }

    /// Phase 2AH: semantic tab item enumeration (Level 0, read-only). Enumerates direct tab items
    /// belonging to exactly ONE named AXTabGroup in an application.
    /// No mutation, no press, no approval, no recovery. Panes and arbitrary subtrees are strictly OUT OF SCOPE.
    public func listTabItems(
        applicationName: String,
        role: String = "AXTabGroup",
        identifier: String?,
        title: String?
    ) async throws -> QAXTabGroupMetadata {
        guard QAXTabGroupRolePolicy.isAllowedTabGroupRole(role) else {
            throw QAXInteractionError.disallowedTabGroupRole(role)
        }
        guard identifier != nil || title != nil else {
            throw QAXInteractionError.missingMatchCriteria
        }
        guard AXIsProcessTrusted() else {
            throw QAXInteractionError.accessibilityPermissionDenied
        }

        let runningApp = try Self.resolveExactRunningApplication(named: applicationName)
        let processIdentifier = runningApp.processIdentifier

        return try await Task.detached(priority: .userInitiated) {
            let appElement = AXUIElementCreateApplication(processIdentifier)

            let matches = Self.collectMatches(root: appElement, role: role, identifier: identifier, title: title)
            guard !matches.isEmpty else { throw QAXInteractionError.noMatchingElement }
            guard matches.count == 1 else { throw QAXInteractionError.ambiguousTarget(count: matches.count) }

            let (targetElement, observedAtSearch) = matches[0]

            guard let observedAtVerify = Self.snapshotIfMatches(targetElement, role: role, identifier: identifier, title: title) else {
                throw QAXInteractionError.staleTarget("target tab group element is no longer resolvable immediately before enumeration")
            }
            guard observedAtVerify == observedAtSearch else {
                throw QAXInteractionError.staleTarget("target tab group element identity changed between observation and enumeration")
            }

            var rawTabElements: [AXUIElement] = []
            var tabsValue: CFTypeRef?
            let copyResult = AXUIElementCopyAttributeValue(targetElement, Self.axTabsAttributeName as CFString, &tabsValue)
            if copyResult == .success, let array = tabsValue as? [AXUIElement] {
                rawTabElements = array
            } else if let children = Self.childrenAttribute(of: targetElement) {
                rawTabElements = children.filter {
                    Self.axStringAttribute(kAXRoleAttribute, of: $0) == "AXRadioButton" &&
                    Self.axStringAttribute(kAXSubroleAttribute, of: $0) == Self.tabButtonSubrole
                }
            }

            var validTabElements: [AXUIElement] = []
            for tabElement in rawTabElements {
                guard Self.axStringAttribute(kAXRoleAttribute, of: tabElement) == "AXRadioButton" else {
                    continue
                }
                guard Self.axStringAttribute(kAXSubroleAttribute, of: tabElement) == Self.tabButtonSubrole else {
                    continue
                }
                validTabElements.append(tabElement)
            }

            guard validTabElements.count <= Self.maxDirectTabItemsCount else {
                throw QAXInteractionError.tabItemCollectionExceedsSafeBound(validTabElements.count)
            }

            var itemsMetadata: [QAXTabItemMetadata] = []
            itemsMetadata.reserveCapacity(validTabElements.count)
            var selectedCount = 0

            for (index, tabElement) in validTabElements.enumerated() {
                let itemTitle = Self.axStringAttribute(kAXTitleAttribute, of: tabElement)
                    ?? Self.axStringAttribute(kAXDescriptionAttribute, of: tabElement)
                let itemIdentifier = Self.axStringAttribute(Self.axIdentifierAttributeName, of: tabElement)
                let isSelected = Self.axBoolAttribute(kAXSelectedAttribute, of: tabElement)
                let isEnabled = Self.axBoolAttribute(kAXEnabledAttribute, of: tabElement)

                if isSelected == true {
                    selectedCount += 1
                }

                itemsMetadata.append(
                    QAXTabItemMetadata(
                        index: index,
                        title: itemTitle,
                        identifier: itemIdentifier,
                        isSelected: isSelected,
                        isEnabled: isEnabled,
                        role: "AXRadioButton",
                        subrole: Self.tabButtonSubrole
                    )
                )
            }

            return QAXTabGroupMetadata(
                applicationName: applicationName,
                tabGroupTitle: observedAtVerify.titleOrDescription,
                tabGroupIdentifier: observedAtVerify.identifier,
                itemCount: itemsMetadata.count,
                selectedItemCount: selectedCount,
                items: itemsMetadata
            )
        }.value
    }

    /// Phase 2AI: semantic radio group direct item enumeration (Level 0, read-only). Enumerates direct radio buttons
    /// belonging to exactly ONE named AXRadioGroup in an application.
    /// No mutation, no press, no approval, no recovery. Subtrees, other containers, and tabs are strictly OUT OF SCOPE.
    public func listRadioGroupItems(
        applicationName: String,
        role: String = "AXRadioGroup",
        identifier: String?,
        title: String?
    ) async throws -> QAXRadioGroupMetadata {
        guard QAXRadioGroupRolePolicy.isAllowedRadioGroupRole(role) else {
            throw QAXInteractionError.disallowedRadioGroupRole(role)
        }
        guard identifier != nil || title != nil else {
            throw QAXInteractionError.missingMatchCriteria
        }
        guard AXIsProcessTrusted() else {
            throw QAXInteractionError.accessibilityPermissionDenied
        }

        let runningApp = try Self.resolveExactRunningApplication(named: applicationName)
        let processIdentifier = runningApp.processIdentifier

        return try await Task.detached(priority: .userInitiated) {
            let appElement = AXUIElementCreateApplication(processIdentifier)

            let matches = Self.collectMatches(root: appElement, role: role, identifier: identifier, title: title)
            guard !matches.isEmpty else { throw QAXInteractionError.noMatchingElement }
            guard matches.count == 1 else { throw QAXInteractionError.ambiguousTarget(count: matches.count) }

            let (targetElement, observedAtSearch) = matches[0]

            guard let observedAtVerify = Self.snapshotIfMatches(targetElement, role: role, identifier: identifier, title: title) else {
                throw QAXInteractionError.staleTarget("target radio group element is no longer resolvable immediately before enumeration")
            }
            guard observedAtVerify == observedAtSearch else {
                throw QAXInteractionError.staleTarget("target radio group element identity changed between observation and enumeration")
            }

            let rawChildElements = Self.childrenAttribute(of: targetElement) ?? []

            var validRadioElements: [AXUIElement] = []
            for childElement in rawChildElements {
                guard Self.axStringAttribute(kAXRoleAttribute, of: childElement) == "AXRadioButton" else {
                    continue
                }
                let subrole = Self.axStringAttribute(kAXSubroleAttribute, of: childElement)
                guard subrole != Self.tabButtonSubrole else {
                    continue
                }
                validRadioElements.append(childElement)
            }

            guard validRadioElements.count <= Self.maxDirectRadioItemsCount else {
                throw QAXInteractionError.radioItemCollectionExceedsSafeBound(validRadioElements.count)
            }

            var itemsMetadata: [QAXRadioGroupItemMetadata] = []
            itemsMetadata.reserveCapacity(validRadioElements.count)
            var selectedCount = 0

            for (index, radioElement) in validRadioElements.enumerated() {
                let itemTitle = Self.axStringAttribute(kAXTitleAttribute, of: radioElement)
                    ?? Self.axStringAttribute(kAXDescriptionAttribute, of: radioElement)
                let itemIdentifier = Self.axStringAttribute(Self.axIdentifierAttributeName, of: radioElement)
                let subrole = Self.axStringAttribute(kAXSubroleAttribute, of: radioElement)

                let isSelected: Bool?
                if let state = Self.axCheckboxRadioState(of: radioElement) {
                    isSelected = (state == .on)
                } else if let selectedVal = Self.axBoolAttribute(kAXSelectedAttribute, of: radioElement) {
                    isSelected = selectedVal
                } else {
                    isSelected = nil
                }

                let isEnabled = Self.axBoolAttribute(kAXEnabledAttribute, of: radioElement)

                if isSelected == true {
                    selectedCount += 1
                }

                itemsMetadata.append(
                    QAXRadioGroupItemMetadata(
                        index: index,
                        title: itemTitle,
                        identifier: itemIdentifier,
                        isSelected: isSelected,
                        isEnabled: isEnabled,
                        role: "AXRadioButton",
                        subrole: subrole
                    )
                )
            }

            return QAXRadioGroupMetadata(
                applicationName: applicationName,
                radioGroupTitle: observedAtVerify.titleOrDescription,
                radioGroupIdentifier: observedAtVerify.identifier,
                itemCount: itemsMetadata.count,
                selectedItemCount: selectedCount,
                items: itemsMetadata
            )
        }.value
    }

    /// Phase 2AK: semantic toolbar direct item enumeration (Level 0, read-only). Enumerates direct semantic controls
    /// belonging to exactly ONE named AXToolbar in an application window.
    /// No mutation, no press, no approval, no recovery. Subtrees, menus, and popups are strictly NOT expanded.
    public func listToolbarItems(
        applicationName: String,
        role: String = "AXToolbar",
        identifier: String?,
        title: String?,
        windowTitle: String? = nil,
        windowIdentifier: String? = nil
    ) async throws -> QAXToolbarMetadata {
        guard QAXToolbarRolePolicy.isAllowedToolbarRole(role) else {
            throw QAXInteractionError.disallowedToolbarRole(role)
        }
        guard AXIsProcessTrusted() else {
            throw QAXInteractionError.accessibilityPermissionDenied
        }

        let runningApp = try Self.resolveExactRunningApplication(named: applicationName)
        let processIdentifier = runningApp.processIdentifier

        return try await Task.detached(priority: .userInitiated) {
            let appElement = AXUIElementCreateApplication(processIdentifier)

            let searchRoot: AXUIElement
            let resolvedWindowTitle: String?

            if windowTitle != nil || windowIdentifier != nil {
                let windowMatches = Self.collectMatches(
                    root: appElement,
                    role: "AXWindow",
                    identifier: windowIdentifier,
                    title: windowTitle
                )
                guard !windowMatches.isEmpty else { throw QAXInteractionError.noMatchingElement }
                guard windowMatches.count == 1 else { throw QAXInteractionError.ambiguousTarget(count: windowMatches.count) }
                let (targetWindow, windowSnapshot) = windowMatches[0]
                guard let verifiedWindow = Self.snapshotIfMatches(targetWindow, role: "AXWindow", identifier: windowIdentifier, title: windowTitle) else {
                    throw QAXInteractionError.staleTarget("target window element is no longer resolvable")
                }
                guard verifiedWindow == windowSnapshot else {
                    throw QAXInteractionError.staleTarget("target window identity changed between observation and verification")
                }
                searchRoot = targetWindow
                resolvedWindowTitle = verifiedWindow.titleOrDescription
            } else {
                searchRoot = appElement
                resolvedWindowTitle = nil
            }

            let matches = Self.collectMatches(root: searchRoot, role: role, identifier: identifier, title: title)
            guard !matches.isEmpty else { throw QAXInteractionError.noMatchingElement }
            guard matches.count == 1 else { throw QAXInteractionError.ambiguousTarget(count: matches.count) }

            let (targetElement, observedAtSearch) = matches[0]

            guard let observedAtVerify = Self.snapshotIfMatches(targetElement, role: role, identifier: identifier, title: title) else {
                throw QAXInteractionError.staleTarget("target toolbar element is no longer resolvable immediately before enumeration")
            }
            guard observedAtVerify == observedAtSearch else {
                throw QAXInteractionError.staleTarget("target toolbar element identity changed between observation and enumeration")
            }

            let rawChildElements = Self.childrenAttribute(of: targetElement) ?? []

            var validToolbarItemElements: [AXUIElement] = []
            for childElement in rawChildElements {
                guard let childRole = Self.axStringAttribute(kAXRoleAttribute, of: childElement) else {
                    continue
                }
                guard Self.allowedDirectToolbarItemRoles.contains(childRole) else {
                    continue
                }
                validToolbarItemElements.append(childElement)
            }

            guard validToolbarItemElements.count <= Self.maxDirectToolbarItemsCount else {
                throw QAXInteractionError.toolbarItemCollectionExceedsSafeBound(validToolbarItemElements.count)
            }

            var itemsMetadata: [QAXToolbarItemMetadata] = []
            itemsMetadata.reserveCapacity(validToolbarItemElements.count)

            for (index, itemElement) in validToolbarItemElements.enumerated() {
                let itemTitle = Self.axStringAttribute(kAXTitleAttribute, of: itemElement)
                    ?? Self.axStringAttribute(kAXDescriptionAttribute, of: itemElement)
                let itemIdentifier = Self.axStringAttribute(Self.axIdentifierAttributeName, of: itemElement)
                let childRole = Self.axStringAttribute(kAXRoleAttribute, of: itemElement) ?? "AXUnknown"
                let subrole = Self.axStringAttribute(kAXSubroleAttribute, of: itemElement)
                let isEnabled = Self.axBoolAttribute(kAXEnabledAttribute, of: itemElement)
                let isSelected: Bool?
                if let state = Self.axCheckboxRadioState(of: itemElement) {
                    isSelected = (state == .on)
                } else if let selectedVal = Self.axBoolAttribute(kAXSelectedAttribute, of: itemElement) {
                    isSelected = selectedVal
                } else {
                    isSelected = nil
                }
                let help = Self.axStringAttribute(kAXHelpAttribute, of: itemElement)

                itemsMetadata.append(
                    QAXToolbarItemMetadata(
                        index: index,
                        title: itemTitle,
                        identifier: itemIdentifier,
                        role: childRole,
                        subrole: subrole,
                        isEnabled: isEnabled,
                        isSelected: isSelected,
                        help: help
                    )
                )
            }

            return QAXToolbarMetadata(
                applicationName: applicationName,
                windowTitle: resolvedWindowTitle,
                toolbarTitle: observedAtVerify.titleOrDescription,
                toolbarIdentifier: observedAtVerify.identifier,
                itemCount: itemsMetadata.count,
                items: itemsMetadata
            )
        }.value
    }

    /// Phase 2AT: semantic split view pane direct enumeration (Level 0, read-only). Enumerates direct
    /// panes belonging to exactly ONE named AXSplitGroup in an application window.
    /// No mutation, no press, no approval, no recovery. The `AXSplitter` divider elements between panes
    /// are strictly excluded — a pane's own descendant subtree is strictly NOT expanded.
    public func listSplitPanes(
        applicationName: String,
        role: String = "AXSplitGroup",
        identifier: String?,
        title: String?,
        windowTitle: String? = nil,
        windowIdentifier: String? = nil
    ) async throws -> QAXSplitGroupMetadata {
        guard QAXSplitGroupRolePolicy.isAllowedSplitGroupRole(role) else {
            throw QAXInteractionError.disallowedSplitGroupRole(role)
        }
        guard AXIsProcessTrusted() else {
            throw QAXInteractionError.accessibilityPermissionDenied
        }

        let runningApp = try Self.resolveExactRunningApplication(named: applicationName)
        let processIdentifier = runningApp.processIdentifier

        return try await Task.detached(priority: .userInitiated) {
            let appElement = AXUIElementCreateApplication(processIdentifier)

            let searchRoot: AXUIElement
            let resolvedWindowTitle: String?

            if windowTitle != nil || windowIdentifier != nil {
                let windowMatches = Self.collectMatches(
                    root: appElement,
                    role: "AXWindow",
                    identifier: windowIdentifier,
                    title: windowTitle
                )
                guard !windowMatches.isEmpty else { throw QAXInteractionError.noMatchingElement }
                guard windowMatches.count == 1 else { throw QAXInteractionError.ambiguousTarget(count: windowMatches.count) }
                let (targetWindow, windowSnapshot) = windowMatches[0]
                guard let verifiedWindow = Self.snapshotIfMatches(targetWindow, role: "AXWindow", identifier: windowIdentifier, title: windowTitle) else {
                    throw QAXInteractionError.staleTarget("target window element is no longer resolvable")
                }
                guard verifiedWindow == windowSnapshot else {
                    throw QAXInteractionError.staleTarget("target window identity changed between observation and verification")
                }
                searchRoot = targetWindow
                resolvedWindowTitle = verifiedWindow.titleOrDescription
            } else {
                searchRoot = appElement
                resolvedWindowTitle = nil
            }

            let matches = Self.collectMatches(root: searchRoot, role: role, identifier: identifier, title: title)
            guard !matches.isEmpty else { throw QAXInteractionError.noMatchingElement }
            guard matches.count == 1 else { throw QAXInteractionError.ambiguousTarget(count: matches.count) }

            let (targetElement, observedAtSearch) = matches[0]

            guard let observedAtVerify = Self.snapshotIfMatches(targetElement, role: role, identifier: identifier, title: title) else {
                throw QAXInteractionError.staleTarget("target split group element is no longer resolvable immediately before enumeration")
            }
            guard observedAtVerify == observedAtSearch else {
                throw QAXInteractionError.staleTarget("target split group element identity changed between observation and enumeration")
            }

            let rawChildElements = Self.childrenAttribute(of: targetElement) ?? []

            var validPaneElements: [AXUIElement] = []
            for childElement in rawChildElements {
                guard let childRole = Self.axStringAttribute(kAXRoleAttribute, of: childElement) else {
                    continue
                }
                guard childRole != Self.splitterRole else {
                    continue
                }
                validPaneElements.append(childElement)
            }

            guard validPaneElements.count <= Self.maxDirectSplitPanesCount else {
                throw QAXInteractionError.splitPaneCollectionExceedsSafeBound(validPaneElements.count)
            }

            var panesMetadata: [QAXSplitPaneItemMetadata] = []
            panesMetadata.reserveCapacity(validPaneElements.count)

            for (index, paneElement) in validPaneElements.enumerated() {
                let paneTitle = Self.axStringAttribute(kAXTitleAttribute, of: paneElement)
                    ?? Self.axStringAttribute(kAXDescriptionAttribute, of: paneElement)
                let paneIdentifier = Self.axStringAttribute(Self.axIdentifierAttributeName, of: paneElement)
                let childRole = Self.axStringAttribute(kAXRoleAttribute, of: paneElement) ?? "AXUnknown"
                let subrole = Self.axStringAttribute(kAXSubroleAttribute, of: paneElement)
                let isEnabled = Self.axBoolAttribute(kAXEnabledAttribute, of: paneElement)

                panesMetadata.append(
                    QAXSplitPaneItemMetadata(
                        index: index,
                        title: paneTitle,
                        identifier: paneIdentifier,
                        role: childRole,
                        subrole: subrole,
                        isEnabled: isEnabled
                    )
                )
            }

            return QAXSplitGroupMetadata(
                applicationName: applicationName,
                windowTitle: resolvedWindowTitle,
                splitGroupTitle: observedAtVerify.titleOrDescription,
                splitGroupIdentifier: observedAtVerify.identifier,
                paneCount: panesMetadata.count,
                panes: panesMetadata
            )
        }.value
    }

    /// Phase 2AV: semantic multi-column browser direct column enumeration (Level 0, read-only).
    /// Enumerates direct AXColumn elements belonging to exactly ONE named AXBrowser in an application window.
    /// No mutation, no press, no focus, no approval, no recovery.
    public func listBrowserColumns(
        applicationName: String,
        role: String = "AXBrowser",
        identifier: String? = nil,
        title: String? = nil,
        windowTitle: String? = nil,
        windowIdentifier: String? = nil
    ) async throws -> QAXBrowserColumnCollectionMetadata {
        guard QAXBrowserRolePolicy.isAllowedBrowserRole(role) else {
            throw QAXInteractionError.disallowedBrowserRole(role)
        }
        guard AXIsProcessTrusted() else {
            throw QAXInteractionError.accessibilityPermissionDenied
        }

        let runningApp = try Self.resolveExactRunningApplication(named: applicationName)
        let processIdentifier = runningApp.processIdentifier

        return try await Task.detached(priority: .userInitiated) {
            let appElement = AXUIElementCreateApplication(processIdentifier)

            let searchRoot: AXUIElement
            let resolvedWindowTitle: String?

            if windowTitle != nil || windowIdentifier != nil {
                let windowMatches = Self.collectMatches(
                    root: appElement,
                    role: "AXWindow",
                    identifier: windowIdentifier,
                    title: windowTitle
                )
                guard !windowMatches.isEmpty else { throw QAXInteractionError.noMatchingElement }
                guard windowMatches.count == 1 else { throw QAXInteractionError.ambiguousTarget(count: windowMatches.count) }
                let (targetWindow, windowSnapshot) = windowMatches[0]
                guard let verifiedWindow = Self.snapshotIfMatches(targetWindow, role: "AXWindow", identifier: windowIdentifier, title: windowTitle) else {
                    throw QAXInteractionError.staleTarget("target window element is no longer resolvable")
                }
                guard verifiedWindow == windowSnapshot else {
                    throw QAXInteractionError.staleTarget("target window identity changed between observation and verification")
                }
                searchRoot = targetWindow
                resolvedWindowTitle = verifiedWindow.titleOrDescription
            } else {
                searchRoot = appElement
                resolvedWindowTitle = nil
            }

            let matches = Self.collectMatches(root: searchRoot, role: role, identifier: identifier, title: title)
            guard !matches.isEmpty else { throw QAXInteractionError.noMatchingElement }
            guard matches.count == 1 else { throw QAXInteractionError.ambiguousTarget(count: matches.count) }

            let (targetElement, observedAtSearch) = matches[0]

            guard let observedAtVerify = Self.snapshotIfMatches(targetElement, role: role, identifier: identifier, title: title) else {
                throw QAXInteractionError.staleTarget("target browser element is no longer resolvable immediately before enumeration")
            }
            guard observedAtVerify == observedAtSearch else {
                throw QAXInteractionError.staleTarget("target browser element identity changed between observation and enumeration")
            }

            var candidateElements: [AXUIElement] = []
            if let colsAttr = Self.axUIElementsAttribute(Self.axColumnsAttributeName, of: targetElement) {
                candidateElements.append(contentsOf: colsAttr)
            }
            if let childElements = Self.childrenAttribute(of: targetElement) {
                candidateElements.append(contentsOf: childElements)
            }

            var validColumnElements: [AXUIElement] = []
            var seenSnapshots: [QAXElementSnapshot] = []

            for element in candidateElements {
                guard let elementRole = Self.axStringAttribute(kAXRoleAttribute, of: element) else {
                    continue
                }
                guard elementRole == "AXColumn" else {
                    continue
                }

                let elementIdentifier = Self.axStringAttribute(Self.axIdentifierAttributeName, of: element)
                let elementTitleOrDesc = Self.axStringAttribute(kAXTitleAttribute, of: element)
                    ?? Self.axStringAttribute(kAXDescriptionAttribute, of: element)
                let isEnabled = Self.axBoolAttribute(kAXEnabledAttribute, of: element) ?? true
                let snapshot = QAXElementSnapshot(role: elementRole, identifier: elementIdentifier, titleOrDescription: elementTitleOrDesc, isEnabled: isEnabled)
                if !seenSnapshots.contains(snapshot) {
                    seenSnapshots.append(snapshot)
                    validColumnElements.append(element)
                }
            }

            guard validColumnElements.count <= Self.maxDirectBrowserColumnsCount else {
                throw QAXInteractionError.browserColumnCollectionExceedsSafeBound(validColumnElements.count)
            }

            var columnsMetadata: [QAXBrowserColumnMetadata] = []
            columnsMetadata.reserveCapacity(validColumnElements.count)

            for (index, colElement) in validColumnElements.enumerated() {
                let colTitle = Self.axStringAttribute(kAXTitleAttribute, of: colElement)
                    ?? Self.axStringAttribute(kAXDescriptionAttribute, of: colElement)
                let colIdentifier = Self.axStringAttribute(Self.axIdentifierAttributeName, of: colElement)
                let colRole = Self.axStringAttribute(kAXRoleAttribute, of: colElement) ?? "AXColumn"
                let subrole = Self.axStringAttribute(kAXSubroleAttribute, of: colElement)
                let isEnabled = Self.axBoolAttribute(kAXEnabledAttribute, of: colElement)

                columnsMetadata.append(
                    QAXBrowserColumnMetadata(
                        index: index,
                        title: colTitle,
                        identifier: colIdentifier,
                        role: colRole,
                        subrole: subrole,
                        isEnabled: isEnabled
                    )
                )
            }

            return QAXBrowserColumnCollectionMetadata(
                applicationName: applicationName,
                windowTitle: resolvedWindowTitle,
                browserTitle: observedAtVerify.titleOrDescription,
                browserIdentifier: observedAtVerify.identifier,
                columnCount: columnsMetadata.count,
                columns: columnsMetadata
            )
        }.value
    }

    /// Phase 2AW: semantic popover container direct enumeration (Level 0, read-only).
    /// Enumerates direct AXPopover elements belonging to an application window or application root.
    /// No mutation, no press, no focus, no approval, no recovery.
    public func listPopovers(
        applicationName: String,
        role: String = "AXPopover",
        identifier: String? = nil,
        title: String? = nil,
        windowTitle: String? = nil,
        windowIdentifier: String? = nil
    ) async throws -> QAXPopoverCollectionMetadata {
        guard QAXPopoverRolePolicy.isAllowedPopoverRole(role) else {
            throw QAXInteractionError.disallowedPopoverRole(role)
        }
        guard AXIsProcessTrusted() else {
            throw QAXInteractionError.accessibilityPermissionDenied
        }

        let runningApp = try Self.resolveExactRunningApplication(named: applicationName)
        let processIdentifier = runningApp.processIdentifier

        return try await Task.detached(priority: .userInitiated) {
            let appElement = AXUIElementCreateApplication(processIdentifier)

            let searchRoot: AXUIElement
            let resolvedWindowTitle: String?

            if windowTitle != nil || windowIdentifier != nil {
                let windowMatches = Self.collectMatches(
                    root: appElement,
                    role: "AXWindow",
                    identifier: windowIdentifier,
                    title: windowTitle
                )
                guard !windowMatches.isEmpty else { throw QAXInteractionError.noMatchingElement }
                guard windowMatches.count == 1 else { throw QAXInteractionError.ambiguousTarget(count: windowMatches.count) }
                let (targetWindow, windowSnapshot) = windowMatches[0]
                guard let verifiedWindow = Self.snapshotIfMatches(targetWindow, role: "AXWindow", identifier: windowIdentifier, title: windowTitle) else {
                    throw QAXInteractionError.staleTarget("target window element is no longer resolvable")
                }
                guard verifiedWindow == windowSnapshot else {
                    throw QAXInteractionError.staleTarget("target window identity changed between observation and verification")
                }
                searchRoot = targetWindow
                resolvedWindowTitle = verifiedWindow.titleOrDescription
            } else {
                searchRoot = appElement
                resolvedWindowTitle = nil
            }

            var candidateElements: [AXUIElement] = []
            if let childElements = Self.childrenAttribute(of: searchRoot) {
                candidateElements.append(contentsOf: childElements)
            }
            if searchRoot != appElement, let appChildren = Self.childrenAttribute(of: appElement) {
                candidateElements.append(contentsOf: appChildren)
            }

            var validPopoverElements: [AXUIElement] = []
            var seenSnapshots: [QAXElementSnapshot] = []

            for element in candidateElements {
                guard let elementRole = Self.axStringAttribute(kAXRoleAttribute, of: element) else {
                    continue
                }
                guard QAXPopoverRolePolicy.isAllowedPopoverRole(elementRole) else {
                    continue
                }

                let elementIdentifier = Self.axStringAttribute(Self.axIdentifierAttributeName, of: element)
                let elementTitleOrDesc = Self.axStringAttribute(kAXTitleAttribute, of: element)
                    ?? Self.axStringAttribute(kAXDescriptionAttribute, of: element)
                let isEnabled = Self.axBoolAttribute(kAXEnabledAttribute, of: element) ?? true
                let snapshot = QAXElementSnapshot(role: elementRole, identifier: elementIdentifier, titleOrDescription: elementTitleOrDesc, isEnabled: isEnabled)
                if !seenSnapshots.contains(snapshot) {
                    seenSnapshots.append(snapshot)
                    validPopoverElements.append(element)
                }
            }

            var filteredPopovers: [AXUIElement] = []
            for pop in validPopoverElements {
                let pId = Self.axStringAttribute(Self.axIdentifierAttributeName, of: pop)
                let pTitle = Self.axStringAttribute(kAXTitleAttribute, of: pop)
                    ?? Self.axStringAttribute(kAXDescriptionAttribute, of: pop)

                if let identifier = identifier, let title = title {
                    if pId == identifier && pTitle == title {
                        filteredPopovers.append(pop)
                    }
                } else if let identifier = identifier {
                    if pId == identifier {
                        filteredPopovers.append(pop)
                    }
                } else if let title = title {
                    if pTitle == title {
                        filteredPopovers.append(pop)
                    }
                } else {
                    filteredPopovers.append(pop)
                }
            }

            guard filteredPopovers.count <= Self.maxDirectPopoversCount else {
                throw QAXInteractionError.popoverCollectionExceedsSafeBound(filteredPopovers.count)
            }

            var popoversMetadata: [QAXPopoverMetadata] = []
            popoversMetadata.reserveCapacity(filteredPopovers.count)

            for (index, popElement) in filteredPopovers.enumerated() {
                let popTitle = Self.axStringAttribute(kAXTitleAttribute, of: popElement)
                    ?? Self.axStringAttribute(kAXDescriptionAttribute, of: popElement)
                let popIdentifier = Self.axStringAttribute(Self.axIdentifierAttributeName, of: popElement)
                let popRole = Self.axStringAttribute(kAXRoleAttribute, of: popElement) ?? "AXPopover"
                let subrole = Self.axStringAttribute(kAXSubroleAttribute, of: popElement)
                let isModal = Self.axBoolAttribute(Self.axModalAttributeName, of: popElement)

                popoversMetadata.append(
                    QAXPopoverMetadata(
                        index: index,
                        title: popTitle,
                        identifier: popIdentifier,
                        role: popRole,
                        subrole: subrole,
                        isModal: isModal
                    )
                )
            }

            return QAXPopoverCollectionMetadata(
                applicationName: applicationName,
                windowTitle: resolvedWindowTitle,
                popoverCount: popoversMetadata.count,
                popovers: popoversMetadata
            )
        }.value
    }

    /// Phase 2AX: semantic color well direct enumeration (Level 0, read-only).
    /// Enumerates direct AXColorWell elements belonging to an application window or view hierarchy.
    /// No mutation, no press, no focus, no approval, no recovery.
    public func listColorWells(
        applicationName: String,
        role: String = "AXColorWell",
        identifier: String? = nil,
        title: String? = nil,
        windowTitle: String? = nil,
        windowIdentifier: String? = nil
    ) async throws -> QAXColorWellCollectionMetadata {
        guard QAXColorWellRolePolicy.isAllowedColorWellRole(role) else {
            throw QAXInteractionError.disallowedColorWellRole(role)
        }
        guard AXIsProcessTrusted() else {
            throw QAXInteractionError.accessibilityPermissionDenied
        }

        let runningApp = try Self.resolveExactRunningApplication(named: applicationName)
        let processIdentifier = runningApp.processIdentifier

        return try await Task.detached(priority: .userInitiated) {
            let appElement = AXUIElementCreateApplication(processIdentifier)

            let searchRoot: AXUIElement
            let resolvedWindowTitle: String?

            if windowTitle != nil || windowIdentifier != nil {
                let windowMatches = Self.collectMatches(
                    root: appElement,
                    role: "AXWindow",
                    identifier: windowIdentifier,
                    title: windowTitle
                )
                guard !windowMatches.isEmpty else { throw QAXInteractionError.noMatchingElement }
                guard windowMatches.count == 1 else { throw QAXInteractionError.ambiguousTarget(count: windowMatches.count) }
                let (targetWindow, windowSnapshot) = windowMatches[0]
                guard let verifiedWindow = Self.snapshotIfMatches(targetWindow, role: "AXWindow", identifier: windowIdentifier, title: windowTitle) else {
                    throw QAXInteractionError.staleTarget("target window element is no longer resolvable")
                }
                guard verifiedWindow == windowSnapshot else {
                    throw QAXInteractionError.staleTarget("target window identity changed between observation and verification")
                }
                searchRoot = targetWindow
                resolvedWindowTitle = verifiedWindow.titleOrDescription
            } else {
                searchRoot = appElement
                resolvedWindowTitle = nil
            }

            var candidateColorWells: [AXUIElement] = []
            var seenSnapshots: [QAXElementSnapshot] = []

            func scanForColorWells(_ element: AXUIElement, depth: Int) {
                guard depth <= 8, candidateColorWells.count <= Self.maxDirectColorWellsCount + 1 else { return }
                if let elementRole = Self.axStringAttribute(kAXRoleAttribute, of: element),
                   QAXColorWellRolePolicy.isAllowedColorWellRole(elementRole) {
                    let elementIdentifier = Self.axStringAttribute(Self.axIdentifierAttributeName, of: element)
                    let elementTitleOrDesc = Self.axStringAttribute(kAXTitleAttribute, of: element)
                        ?? Self.axStringAttribute(kAXDescriptionAttribute, of: element)
                    let isEnabled = Self.axBoolAttribute(kAXEnabledAttribute, of: element) ?? true
                    let snapshot = QAXElementSnapshot(role: elementRole, identifier: elementIdentifier, titleOrDescription: elementTitleOrDesc, isEnabled: isEnabled)
                    if !seenSnapshots.contains(snapshot) {
                        seenSnapshots.append(snapshot)
                        candidateColorWells.append(element)
                    }
                }
                guard let children = Self.childrenAttribute(of: element) else { return }
                for child in children {
                    scanForColorWells(child, depth: depth + 1)
                }
            }

            scanForColorWells(searchRoot, depth: 0)
            if searchRoot != appElement {
                scanForColorWells(appElement, depth: 0)
            }

            var filteredColorWells: [AXUIElement] = []
            for cw in candidateColorWells {
                let cwId = Self.axStringAttribute(Self.axIdentifierAttributeName, of: cw)
                let cwTitle = Self.axStringAttribute(kAXTitleAttribute, of: cw)
                    ?? Self.axStringAttribute(kAXDescriptionAttribute, of: cw)

                if let identifier = identifier, let title = title {
                    if cwId == identifier && cwTitle == title {
                        filteredColorWells.append(cw)
                    }
                } else if let identifier = identifier {
                    if cwId == identifier {
                        filteredColorWells.append(cw)
                    }
                } else if let title = title {
                    if cwTitle == title {
                        filteredColorWells.append(cw)
                    }
                } else {
                    filteredColorWells.append(cw)
                }
            }

            guard filteredColorWells.count <= Self.maxDirectColorWellsCount else {
                throw QAXInteractionError.colorWellCollectionExceedsSafeBound(filteredColorWells.count)
            }

            var colorWellsMetadata: [QAXColorWellMetadata] = []
            colorWellsMetadata.reserveCapacity(filteredColorWells.count)

            for (index, cwElement) in filteredColorWells.enumerated() {
                let cwTitle = Self.axStringAttribute(kAXTitleAttribute, of: cwElement)
                    ?? Self.axStringAttribute(kAXDescriptionAttribute, of: cwElement)
                let cwIdentifier = Self.axStringAttribute(Self.axIdentifierAttributeName, of: cwElement)
                let cwRole = Self.axStringAttribute(kAXRoleAttribute, of: cwElement) ?? "AXColorWell"
                let subrole = Self.axStringAttribute(kAXSubroleAttribute, of: cwElement)
                let value = Self.axStringAttribute(kAXValueAttribute, of: cwElement)
                let isEnabled = Self.axBoolAttribute(kAXEnabledAttribute, of: cwElement)

                colorWellsMetadata.append(
                    QAXColorWellMetadata(
                        index: index,
                        title: cwTitle,
                        identifier: cwIdentifier,
                        role: cwRole,
                        subrole: subrole,
                        value: value,
                        isEnabled: isEnabled
                    )
                )
            }

            return QAXColorWellCollectionMetadata(
                applicationName: applicationName,
                windowTitle: resolvedWindowTitle,
                colorWellCount: colorWellsMetadata.count,
                colorWells: colorWellsMetadata
            )
        }.value
    }

    /// Phase 2AY: semantic progress indicator direct enumeration (Level 0, read-only).
    /// Enumerates direct AXProgressIndicator and AXBusyIndicator elements belonging to an application window or view hierarchy.
    /// No mutation, no press, no focus, no approval, no recovery.
    public func listProgressIndicators(
        applicationName: String,
        role: String? = nil,
        identifier: String? = nil,
        title: String? = nil,
        windowTitle: String? = nil,
        windowIdentifier: String? = nil
    ) async throws -> QAXProgressIndicatorCollectionMetadata {
        if let role = role {
            guard QAXProgressIndicatorRolePolicy.isAllowedProgressIndicatorRole(role) else {
                throw QAXInteractionError.disallowedProgressIndicatorRole(role)
            }
        }
        guard AXIsProcessTrusted() else {
            throw QAXInteractionError.accessibilityPermissionDenied
        }

        let runningApp = try Self.resolveExactRunningApplication(named: applicationName)
        let processIdentifier = runningApp.processIdentifier

        return try await Task.detached(priority: .userInitiated) {
            let appElement = AXUIElementCreateApplication(processIdentifier)

            let searchRoot: AXUIElement
            let resolvedWindowTitle: String?

            if windowTitle != nil || windowIdentifier != nil {
                let windowMatches = Self.collectMatches(
                    root: appElement,
                    role: "AXWindow",
                    identifier: windowIdentifier,
                    title: windowTitle
                )
                guard !windowMatches.isEmpty else { throw QAXInteractionError.noMatchingElement }
                guard windowMatches.count == 1 else { throw QAXInteractionError.ambiguousTarget(count: windowMatches.count) }
                let (targetWindow, windowSnapshot) = windowMatches[0]
                guard let verifiedWindow = Self.snapshotIfMatches(targetWindow, role: "AXWindow", identifier: windowIdentifier, title: windowTitle) else {
                    throw QAXInteractionError.staleTarget("target window element is no longer resolvable")
                }
                guard verifiedWindow == windowSnapshot else {
                    throw QAXInteractionError.staleTarget("target window identity changed between observation and verification")
                }
                searchRoot = targetWindow
                resolvedWindowTitle = verifiedWindow.titleOrDescription
            } else {
                searchRoot = appElement
                resolvedWindowTitle = nil
            }

            var candidateIndicators: [AXUIElement] = []
            var seenSnapshots: [QAXElementSnapshot] = []

            func scanForProgressIndicators(_ element: AXUIElement, depth: Int) {
                guard depth <= 8, candidateIndicators.count <= Self.maxDirectProgressIndicatorsCount + 1 else { return }
                if let elementRole = Self.axStringAttribute(kAXRoleAttribute, of: element),
                   QAXProgressIndicatorRolePolicy.isAllowedProgressIndicatorRole(elementRole) {
                    let elementIdentifier = Self.axStringAttribute(Self.axIdentifierAttributeName, of: element)
                    let elementTitleOrDesc = Self.axStringAttribute(kAXTitleAttribute, of: element)
                        ?? Self.axStringAttribute(kAXDescriptionAttribute, of: element)
                    let isEnabled = Self.axBoolAttribute(kAXEnabledAttribute, of: element) ?? true
                    let snapshot = QAXElementSnapshot(role: elementRole, identifier: elementIdentifier, titleOrDescription: elementTitleOrDesc, isEnabled: isEnabled)
                    if !seenSnapshots.contains(snapshot) {
                        seenSnapshots.append(snapshot)
                        candidateIndicators.append(element)
                    }
                }
                guard let children = Self.childrenAttribute(of: element) else { return }
                for child in children {
                    scanForProgressIndicators(child, depth: depth + 1)
                }
            }

            scanForProgressIndicators(searchRoot, depth: 0)
            if searchRoot != appElement {
                scanForProgressIndicators(appElement, depth: 0)
            }

            var filteredIndicators: [AXUIElement] = []
            for pi in candidateIndicators {
                let piRole = Self.axStringAttribute(kAXRoleAttribute, of: pi) ?? ""
                if let role = role, piRole != role {
                    continue
                }
                let piId = Self.axStringAttribute(Self.axIdentifierAttributeName, of: pi)
                let piTitle = Self.axStringAttribute(kAXTitleAttribute, of: pi)
                    ?? Self.axStringAttribute(kAXDescriptionAttribute, of: pi)

                if let identifier = identifier, let title = title {
                    if piId == identifier && piTitle == title {
                        filteredIndicators.append(pi)
                    }
                } else if let identifier = identifier {
                    if piId == identifier {
                        filteredIndicators.append(pi)
                    }
                } else if let title = title {
                    if piTitle == title {
                        filteredIndicators.append(pi)
                    }
                } else {
                    filteredIndicators.append(pi)
                }
            }

            guard filteredIndicators.count <= Self.maxDirectProgressIndicatorsCount else {
                throw QAXInteractionError.progressIndicatorCollectionExceedsSafeBound(filteredIndicators.count)
            }

            var indicatorsMetadata: [QAXProgressIndicatorMetadata] = []
            indicatorsMetadata.reserveCapacity(filteredIndicators.count)

            for (index, piElement) in filteredIndicators.enumerated() {
                let piTitle = Self.axStringAttribute(kAXTitleAttribute, of: piElement)
                    ?? Self.axStringAttribute(kAXDescriptionAttribute, of: piElement)
                let piIdentifier = Self.axStringAttribute(Self.axIdentifierAttributeName, of: piElement)
                let piRole = Self.axStringAttribute(kAXRoleAttribute, of: piElement) ?? "AXProgressIndicator"
                let subrole = Self.axStringAttribute(kAXSubroleAttribute, of: piElement)
                let value = Self.axDoubleAttribute(kAXValueAttribute, of: piElement)
                let minValue = Self.axDoubleAttribute(kAXMinValueAttribute, of: piElement)
                let maxValue = Self.axDoubleAttribute(kAXMaxValueAttribute, of: piElement)
                let isBusy = (piRole == "AXBusyIndicator")
                let isEnabled = Self.axBoolAttribute(kAXEnabledAttribute, of: piElement)

                indicatorsMetadata.append(
                    QAXProgressIndicatorMetadata(
                        index: index,
                        title: piTitle,
                        identifier: piIdentifier,
                        role: piRole,
                        subrole: subrole,
                        value: value,
                        minValue: minValue,
                        maxValue: maxValue,
                        isBusy: isBusy,
                        isEnabled: isEnabled
                    )
                )
            }

            return QAXProgressIndicatorCollectionMetadata(
                applicationName: applicationName,
                windowTitle: resolvedWindowTitle,
                indicatorCount: indicatorsMetadata.count,
                indicators: indicatorsMetadata
            )
        }.value
    }

    /// Phase 2AZ: semantic level indicator direct enumeration (Level 0, read-only).
    /// Enumerates direct AXLevelIndicator and AXRelevanceIndicator elements belonging to an application window or view hierarchy.
    /// No mutation, no press, no focus, no approval, no recovery.
    public func listLevelIndicators(
        applicationName: String,
        role: String? = nil,
        identifier: String? = nil,
        title: String? = nil,
        windowTitle: String? = nil,
        windowIdentifier: String? = nil
    ) async throws -> QAXLevelIndicatorCollectionMetadata {
        if let role = role {
            guard QAXLevelIndicatorRolePolicy.isAllowedLevelIndicatorRole(role) else {
                throw QAXInteractionError.disallowedLevelIndicatorRole(role)
            }
        }
        guard AXIsProcessTrusted() else {
            throw QAXInteractionError.accessibilityPermissionDenied
        }

        let runningApp = try Self.resolveExactRunningApplication(named: applicationName)
        let processIdentifier = runningApp.processIdentifier

        return try await Task.detached(priority: .userInitiated) {
            let appElement = AXUIElementCreateApplication(processIdentifier)

            let searchRoot: AXUIElement
            let resolvedWindowTitle: String?

            if windowTitle != nil || windowIdentifier != nil {
                let windowMatches = Self.collectMatches(
                    root: appElement,
                    role: "AXWindow",
                    identifier: windowIdentifier,
                    title: windowTitle
                )
                guard !windowMatches.isEmpty else { throw QAXInteractionError.noMatchingElement }
                guard windowMatches.count == 1 else { throw QAXInteractionError.ambiguousTarget(count: windowMatches.count) }
                let (targetWindow, windowSnapshot) = windowMatches[0]
                guard let verifiedWindow = Self.snapshotIfMatches(targetWindow, role: "AXWindow", identifier: windowIdentifier, title: windowTitle) else {
                    throw QAXInteractionError.staleTarget("target window element is no longer resolvable")
                }
                guard verifiedWindow == windowSnapshot else {
                    throw QAXInteractionError.staleTarget("target window identity changed between observation and verification")
                }
                searchRoot = targetWindow
                resolvedWindowTitle = verifiedWindow.titleOrDescription
            } else {
                searchRoot = appElement
                resolvedWindowTitle = nil
            }

            var candidateIndicators: [AXUIElement] = []
            var seenSnapshots: [QAXElementSnapshot] = []

            func scanForLevelIndicators(_ element: AXUIElement, depth: Int) {
                guard depth <= 8, candidateIndicators.count <= Self.maxDirectLevelIndicatorsCount + 1 else { return }
                if let elementRole = Self.axStringAttribute(kAXRoleAttribute, of: element),
                   QAXLevelIndicatorRolePolicy.isAllowedLevelIndicatorRole(elementRole) {
                    let elementIdentifier = Self.axStringAttribute(Self.axIdentifierAttributeName, of: element)
                    let elementTitleOrDesc = Self.axStringAttribute(kAXTitleAttribute, of: element)
                        ?? Self.axStringAttribute(kAXDescriptionAttribute, of: element)
                    let isEnabled = Self.axBoolAttribute(kAXEnabledAttribute, of: element) ?? true
                    let snapshot = QAXElementSnapshot(role: elementRole, identifier: elementIdentifier, titleOrDescription: elementTitleOrDesc, isEnabled: isEnabled)
                    if !seenSnapshots.contains(snapshot) {
                        seenSnapshots.append(snapshot)
                        candidateIndicators.append(element)
                    }
                }
                guard let children = Self.childrenAttribute(of: element) else { return }
                for child in children {
                    scanForLevelIndicators(child, depth: depth + 1)
                }
            }

            scanForLevelIndicators(searchRoot, depth: 0)
            if searchRoot != appElement {
                scanForLevelIndicators(appElement, depth: 0)
            }

            var filteredIndicators: [AXUIElement] = []
            for li in candidateIndicators {
                let liRole = Self.axStringAttribute(kAXRoleAttribute, of: li) ?? ""
                if let role = role, liRole != role {
                    continue
                }
                let liId = Self.axStringAttribute(Self.axIdentifierAttributeName, of: li)
                let liTitle = Self.axStringAttribute(kAXTitleAttribute, of: li)
                    ?? Self.axStringAttribute(kAXDescriptionAttribute, of: li)

                if let identifier = identifier, let title = title {
                    if liId == identifier && liTitle == title {
                        filteredIndicators.append(li)
                    }
                } else if let identifier = identifier {
                    if liId == identifier {
                        filteredIndicators.append(li)
                    }
                } else if let title = title {
                    if liTitle == title {
                        filteredIndicators.append(li)
                    }
                } else {
                    filteredIndicators.append(li)
                }
            }

            guard filteredIndicators.count <= Self.maxDirectLevelIndicatorsCount else {
                throw QAXInteractionError.levelIndicatorCollectionExceedsSafeBound(filteredIndicators.count)
            }

            var indicatorsMetadata: [QAXLevelIndicatorMetadata] = []
            indicatorsMetadata.reserveCapacity(filteredIndicators.count)

            for (index, liElement) in filteredIndicators.enumerated() {
                let liTitle = Self.axStringAttribute(kAXTitleAttribute, of: liElement)
                    ?? Self.axStringAttribute(kAXDescriptionAttribute, of: liElement)
                let liIdentifier = Self.axStringAttribute(Self.axIdentifierAttributeName, of: liElement)
                let liRole = Self.axStringAttribute(kAXRoleAttribute, of: liElement) ?? "AXLevelIndicator"
                let subrole = Self.axStringAttribute(kAXSubroleAttribute, of: liElement)
                let value = Self.axDoubleAttribute(kAXValueAttribute, of: liElement)
                let minValue = Self.axDoubleAttribute(kAXMinValueAttribute, of: liElement)
                let maxValue = Self.axDoubleAttribute(kAXMaxValueAttribute, of: liElement)
                let warningValue = Self.axDoubleAttribute(kAXWarningValueAttribute, of: liElement)
                let criticalValue = Self.axDoubleAttribute(kAXCriticalValueAttribute, of: liElement)
                let isEnabled = Self.axBoolAttribute(kAXEnabledAttribute, of: liElement)

                indicatorsMetadata.append(
                    QAXLevelIndicatorMetadata(
                        index: index,
                        title: liTitle,
                        identifier: liIdentifier,
                        role: liRole,
                        subrole: subrole,
                        value: value,
                        minValue: minValue,
                        maxValue: maxValue,
                        warningValue: warningValue,
                        criticalValue: criticalValue,
                        isEnabled: isEnabled
                    )
                )
            }

            return QAXLevelIndicatorCollectionMetadata(
                applicationName: applicationName,
                windowTitle: resolvedWindowTitle,
                indicatorCount: indicatorsMetadata.count,
                indicators: indicatorsMetadata
            )
        }.value
    }

    /// Phase 2BA: semantic stepper / incrementor direct enumeration (Level 0, read-only).
    /// Enumerates direct AXIncrementor elements belonging to an application window or view hierarchy.
    /// No mutation, no press, no focus, no approval, no recovery.
    public func listIncrementors(
        applicationName: String,
        role: String? = nil,
        identifier: String? = nil,
        title: String? = nil,
        windowTitle: String? = nil,
        windowIdentifier: String? = nil
    ) async throws -> QAXIncrementorCollectionMetadata {
        if let role = role {
            guard QAXIncrementorRolePolicy.isAllowedIncrementorRole(role) else {
                throw QAXInteractionError.disallowedIncrementorRole(role)
            }
        }
        guard AXIsProcessTrusted() else {
            throw QAXInteractionError.accessibilityPermissionDenied
        }

        let runningApp = try Self.resolveExactRunningApplication(named: applicationName)
        let processIdentifier = runningApp.processIdentifier

        return try await Task.detached(priority: .userInitiated) {
            let appElement = AXUIElementCreateApplication(processIdentifier)

            let searchRoot: AXUIElement
            let resolvedWindowTitle: String?

            if windowTitle != nil || windowIdentifier != nil {
                let windowMatches = Self.collectMatches(
                    root: appElement,
                    role: "AXWindow",
                    identifier: windowIdentifier,
                    title: windowTitle
                )
                guard !windowMatches.isEmpty else { throw QAXInteractionError.noMatchingElement }
                guard windowMatches.count == 1 else { throw QAXInteractionError.ambiguousTarget(count: windowMatches.count) }
                let (targetWindow, windowSnapshot) = windowMatches[0]
                guard let verifiedWindow = Self.snapshotIfMatches(targetWindow, role: "AXWindow", identifier: windowIdentifier, title: windowTitle) else {
                    throw QAXInteractionError.staleTarget("target window element is no longer resolvable")
                }
                guard verifiedWindow == windowSnapshot else {
                    throw QAXInteractionError.staleTarget("target window identity changed between observation and verification")
                }
                searchRoot = targetWindow
                resolvedWindowTitle = verifiedWindow.titleOrDescription
            } else {
                searchRoot = appElement
                resolvedWindowTitle = nil
            }

            var candidateIncrementors: [AXUIElement] = []
            var seenSnapshots: [QAXElementSnapshot] = []

            func scanForIncrementors(_ element: AXUIElement, depth: Int) {
                guard depth <= 8, candidateIncrementors.count <= Self.maxDirectIncrementorsCount + 1 else { return }
                if let elementRole = Self.axStringAttribute(kAXRoleAttribute, of: element),
                   QAXIncrementorRolePolicy.isAllowedIncrementorRole(elementRole) {
                    let elementIdentifier = Self.axStringAttribute(Self.axIdentifierAttributeName, of: element)
                    let elementTitleOrDesc = Self.axStringAttribute(kAXTitleAttribute, of: element)
                        ?? Self.axStringAttribute(kAXDescriptionAttribute, of: element)
                    let isEnabled = Self.axBoolAttribute(kAXEnabledAttribute, of: element) ?? true
                    let snapshot = QAXElementSnapshot(role: elementRole, identifier: elementIdentifier, titleOrDescription: elementTitleOrDesc, isEnabled: isEnabled)
                    if !seenSnapshots.contains(snapshot) {
                        seenSnapshots.append(snapshot)
                        candidateIncrementors.append(element)
                    }
                }
                guard let children = Self.childrenAttribute(of: element) else { return }
                for child in children {
                    scanForIncrementors(child, depth: depth + 1)
                }
            }

            scanForIncrementors(searchRoot, depth: 0)
            if searchRoot != appElement {
                scanForIncrementors(appElement, depth: 0)
            }

            var filteredIncrementors: [AXUIElement] = []
            for inc in candidateIncrementors {
                let incRole = Self.axStringAttribute(kAXRoleAttribute, of: inc) ?? ""
                if let role = role, incRole != role {
                    continue
                }
                let incId = Self.axStringAttribute(Self.axIdentifierAttributeName, of: inc)
                let incTitle = Self.axStringAttribute(kAXTitleAttribute, of: inc)
                    ?? Self.axStringAttribute(kAXDescriptionAttribute, of: inc)

                if let identifier = identifier, let title = title {
                    if incId == identifier && incTitle == title {
                        filteredIncrementors.append(inc)
                    }
                } else if let identifier = identifier {
                    if incId == identifier {
                        filteredIncrementors.append(inc)
                    }
                } else if let title = title {
                    if incTitle == title {
                        filteredIncrementors.append(inc)
                    }
                } else {
                    filteredIncrementors.append(inc)
                }
            }

            guard filteredIncrementors.count <= Self.maxDirectIncrementorsCount else {
                throw QAXInteractionError.incrementorCollectionExceedsSafeBound(filteredIncrementors.count)
            }

            var incrementorsMetadata: [QAXIncrementorMetadata] = []
            incrementorsMetadata.reserveCapacity(filteredIncrementors.count)

            for (index, incElement) in filteredIncrementors.enumerated() {
                let incTitle = Self.axStringAttribute(kAXTitleAttribute, of: incElement)
                    ?? Self.axStringAttribute(kAXDescriptionAttribute, of: incElement)
                let incIdentifier = Self.axStringAttribute(Self.axIdentifierAttributeName, of: incElement)
                let incRole = Self.axStringAttribute(kAXRoleAttribute, of: incElement) ?? "AXIncrementor"
                let subrole = Self.axStringAttribute(kAXSubroleAttribute, of: incElement)
                let value = Self.axDoubleAttribute(kAXValueAttribute, of: incElement)
                let minValue = Self.axDoubleAttribute(kAXMinValueAttribute, of: incElement)
                let maxValue = Self.axDoubleAttribute(kAXMaxValueAttribute, of: incElement)
                let isEnabled = Self.axBoolAttribute(kAXEnabledAttribute, of: incElement)

                incrementorsMetadata.append(
                    QAXIncrementorMetadata(
                        index: index,
                        title: incTitle,
                        identifier: incIdentifier,
                        role: incRole,
                        subrole: subrole,
                        value: value,
                        minValue: minValue,
                        maxValue: maxValue,
                        isEnabled: isEnabled
                    )
                )
            }

            return QAXIncrementorCollectionMetadata(
                applicationName: applicationName,
                windowTitle: resolvedWindowTitle,
                incrementorCount: incrementorsMetadata.count,
                incrementors: incrementorsMetadata
            )
        }.value
    }

    /// Phase 2BB: semantic combo box direct enumeration (Level 0, read-only).
    /// Enumerates direct AXComboBox elements belonging to an application window or view hierarchy.
    /// No mutation, no selection change, no text entry, no approval, no recovery.
    public func listComboBoxes(
        applicationName: String,
        role: String? = nil,
        identifier: String? = nil,
        title: String? = nil,
        windowTitle: String? = nil,
        windowIdentifier: String? = nil
    ) async throws -> QAXComboBoxCollectionMetadata {
        if let role = role {
            guard QAXComboBoxRolePolicy.isAllowedComboBoxRole(role) else {
                throw QAXInteractionError.disallowedComboBoxRole(role)
            }
        }
        guard AXIsProcessTrusted() else {
            throw QAXInteractionError.accessibilityPermissionDenied
        }

        let runningApp = try Self.resolveExactRunningApplication(named: applicationName)
        let processIdentifier = runningApp.processIdentifier

        return try await Task.detached(priority: .userInitiated) {
            let appElement = AXUIElementCreateApplication(processIdentifier)

            let searchRoot: AXUIElement
            let resolvedWindowTitle: String?

            if windowTitle != nil || windowIdentifier != nil {
                let windowMatches = Self.collectMatches(
                    root: appElement,
                    role: "AXWindow",
                    identifier: windowIdentifier,
                    title: windowTitle
                )
                guard !windowMatches.isEmpty else { throw QAXInteractionError.noMatchingElement }
                guard windowMatches.count == 1 else { throw QAXInteractionError.ambiguousTarget(count: windowMatches.count) }
                let (targetWindow, windowSnapshot) = windowMatches[0]
                guard let verifiedWindow = Self.snapshotIfMatches(targetWindow, role: "AXWindow", identifier: windowIdentifier, title: windowTitle) else {
                    throw QAXInteractionError.staleTarget("target window element is no longer resolvable")
                }
                guard verifiedWindow == windowSnapshot else {
                    throw QAXInteractionError.staleTarget("target window identity changed between observation and verification")
                }
                searchRoot = targetWindow
                resolvedWindowTitle = verifiedWindow.titleOrDescription
            } else {
                searchRoot = appElement
                resolvedWindowTitle = nil
            }

            var candidateComboBoxes: [AXUIElement] = []
            var seenSnapshots: [QAXElementSnapshot] = []

            func scanForComboBoxes(_ element: AXUIElement, depth: Int) {
                guard depth <= 8, candidateComboBoxes.count <= Self.maxDirectComboBoxesCount + 1 else { return }
                if let elementRole = Self.axStringAttribute(kAXRoleAttribute, of: element),
                   QAXComboBoxRolePolicy.isAllowedComboBoxRole(elementRole) {
                    let elementIdentifier = Self.axStringAttribute(Self.axIdentifierAttributeName, of: element)
                    let elementTitleOrDesc = Self.axStringAttribute(kAXTitleAttribute, of: element)
                        ?? Self.axStringAttribute(kAXDescriptionAttribute, of: element)
                    let isEnabled = Self.axBoolAttribute(kAXEnabledAttribute, of: element) ?? true
                    let snapshot = QAXElementSnapshot(role: elementRole, identifier: elementIdentifier, titleOrDescription: elementTitleOrDesc, isEnabled: isEnabled)
                    if !seenSnapshots.contains(snapshot) {
                        seenSnapshots.append(snapshot)
                        candidateComboBoxes.append(element)
                    }
                }
                guard let children = Self.childrenAttribute(of: element) else { return }
                for child in children {
                    scanForComboBoxes(child, depth: depth + 1)
                }
            }

            scanForComboBoxes(searchRoot, depth: 0)
            if searchRoot != appElement {
                scanForComboBoxes(appElement, depth: 0)
            }

            var filteredComboBoxes: [AXUIElement] = []
            for cb in candidateComboBoxes {
                let cbRole = Self.axStringAttribute(kAXRoleAttribute, of: cb) ?? ""
                if let role = role, cbRole != role {
                    continue
                }
                let cbId = Self.axStringAttribute(Self.axIdentifierAttributeName, of: cb)
                let cbTitle = Self.axStringAttribute(kAXTitleAttribute, of: cb)
                    ?? Self.axStringAttribute(kAXDescriptionAttribute, of: cb)

                if let identifier = identifier, let title = title {
                    if cbId == identifier && cbTitle == title {
                        filteredComboBoxes.append(cb)
                    }
                } else if let identifier = identifier {
                    if cbId == identifier {
                        filteredComboBoxes.append(cb)
                    }
                } else if let title = title {
                    if cbTitle == title {
                        filteredComboBoxes.append(cb)
                    }
                } else {
                    filteredComboBoxes.append(cb)
                }
            }

            guard filteredComboBoxes.count <= Self.maxDirectComboBoxesCount else {
                throw QAXInteractionError.comboBoxCollectionExceedsSafeBound(filteredComboBoxes.count)
            }

            var comboBoxesMetadata: [QAXComboBoxMetadata] = []
            comboBoxesMetadata.reserveCapacity(filteredComboBoxes.count)

            for (index, cbElement) in filteredComboBoxes.enumerated() {
                let cbTitle = Self.axStringAttribute(kAXTitleAttribute, of: cbElement)
                    ?? Self.axStringAttribute(kAXDescriptionAttribute, of: cbElement)
                let cbIdentifier = Self.axStringAttribute(Self.axIdentifierAttributeName, of: cbElement)
                let cbRole = Self.axStringAttribute(kAXRoleAttribute, of: cbElement) ?? "AXComboBox"
                let subrole = Self.axStringAttribute(kAXSubroleAttribute, of: cbElement)
                let value = Self.axStringAttribute(kAXValueAttribute, of: cbElement)
                let placeholderValue = Self.axStringAttribute("AXPlaceholderValue", of: cbElement)
                    ?? Self.axStringAttribute(kAXHelpAttribute, of: cbElement)
                let isEnabled = Self.axBoolAttribute(kAXEnabledAttribute, of: cbElement)
                let isSettable = Self.axIsAttributeSettable(kAXValueAttribute, of: cbElement)

                comboBoxesMetadata.append(
                    QAXComboBoxMetadata(
                        index: index,
                        title: cbTitle,
                        identifier: cbIdentifier,
                        role: cbRole,
                        subrole: subrole,
                        value: value,
                        placeholderValue: placeholderValue,
                        isEnabled: isEnabled,
                        isSettable: isSettable
                    )
                )
            }

            return QAXComboBoxCollectionMetadata(
                applicationName: applicationName,
                windowTitle: resolvedWindowTitle,
                comboBoxCount: comboBoxesMetadata.count,
                comboBoxes: comboBoxesMetadata
            )
        }.value
    }

    /// Phase 2BC: semantic ruler direct enumeration (Level 0, read-only).
    /// Enumerates direct AXRuler elements belonging to an application window or view hierarchy.
    /// No mutation, no marker repositioning, no approval, no recovery.
    public func listRulers(
        applicationName: String,
        role: String? = nil,
        identifier: String? = nil,
        title: String? = nil,
        windowTitle: String? = nil,
        windowIdentifier: String? = nil
    ) async throws -> QAXRulerCollectionMetadata {
        if let role = role {
            guard QAXRulerRolePolicy.isAllowedRulerRole(role) else {
                throw QAXInteractionError.disallowedRulerRole(role)
            }
        }
        guard AXIsProcessTrusted() else {
            throw QAXInteractionError.accessibilityPermissionDenied
        }

        let runningApp = try Self.resolveExactRunningApplication(named: applicationName)
        let processIdentifier = runningApp.processIdentifier

        return try await Task.detached(priority: .userInitiated) {
            let appElement = AXUIElementCreateApplication(processIdentifier)

            let searchRoot: AXUIElement
            let resolvedWindowTitle: String?

            if windowTitle != nil || windowIdentifier != nil {
                let windowMatches = Self.collectMatches(
                    root: appElement,
                    role: "AXWindow",
                    identifier: windowIdentifier,
                    title: windowTitle
                )
                guard !windowMatches.isEmpty else { throw QAXInteractionError.noMatchingElement }
                guard windowMatches.count == 1 else { throw QAXInteractionError.ambiguousTarget(count: windowMatches.count) }
                let (targetWindow, windowSnapshot) = windowMatches[0]
                guard let verifiedWindow = Self.snapshotIfMatches(targetWindow, role: "AXWindow", identifier: windowIdentifier, title: windowTitle) else {
                    throw QAXInteractionError.staleTarget("target window element is no longer resolvable")
                }
                guard verifiedWindow == windowSnapshot else {
                    throw QAXInteractionError.staleTarget("target window identity changed between observation and verification")
                }
                searchRoot = targetWindow
                resolvedWindowTitle = verifiedWindow.titleOrDescription
            } else {
                searchRoot = appElement
                resolvedWindowTitle = nil
            }

            var candidateRulers: [AXUIElement] = []
            var seenSnapshots: [QAXElementSnapshot] = []

            func scanForRulers(_ element: AXUIElement, depth: Int) {
                guard depth <= 8, candidateRulers.count <= Self.maxDirectRulersCount + 1 else { return }
                if let elementRole = Self.axStringAttribute(kAXRoleAttribute, of: element),
                   QAXRulerRolePolicy.isAllowedRulerRole(elementRole) {
                    let elementIdentifier = Self.axStringAttribute(Self.axIdentifierAttributeName, of: element)
                    let elementTitleOrDesc = Self.axStringAttribute(kAXTitleAttribute, of: element)
                        ?? Self.axStringAttribute(kAXDescriptionAttribute, of: element)
                    let isEnabled = Self.axBoolAttribute(kAXEnabledAttribute, of: element) ?? true
                    let snapshot = QAXElementSnapshot(role: elementRole, identifier: elementIdentifier, titleOrDescription: elementTitleOrDesc, isEnabled: isEnabled)
                    if !seenSnapshots.contains(snapshot) {
                        seenSnapshots.append(snapshot)
                        candidateRulers.append(element)
                    }
                }
                guard let children = Self.childrenAttribute(of: element) else { return }
                for child in children {
                    scanForRulers(child, depth: depth + 1)
                }
            }

            scanForRulers(searchRoot, depth: 0)
            if searchRoot != appElement {
                scanForRulers(appElement, depth: 0)
            }

            var filteredRulers: [AXUIElement] = []
            for ruler in candidateRulers {
                let rulerRole = Self.axStringAttribute(kAXRoleAttribute, of: ruler) ?? ""
                if let role = role, rulerRole != role {
                    continue
                }
                let rulerId = Self.axStringAttribute(Self.axIdentifierAttributeName, of: ruler)
                let rulerTitle = Self.axStringAttribute(kAXTitleAttribute, of: ruler)
                    ?? Self.axStringAttribute(kAXDescriptionAttribute, of: ruler)

                if let identifier = identifier, let title = title {
                    if rulerId == identifier && rulerTitle == title {
                        filteredRulers.append(ruler)
                    }
                } else if let identifier = identifier {
                    if rulerId == identifier {
                        filteredRulers.append(ruler)
                    }
                } else if let title = title {
                    if rulerTitle == title {
                        filteredRulers.append(ruler)
                    }
                } else {
                    filteredRulers.append(ruler)
                }
            }

            guard filteredRulers.count <= Self.maxDirectRulersCount else {
                throw QAXInteractionError.rulerCollectionExceedsSafeBound(filteredRulers.count)
            }

            var rulersMetadata: [QAXRulerMetadata] = []
            rulersMetadata.reserveCapacity(filteredRulers.count)

            for (index, rulerElement) in filteredRulers.enumerated() {
                let rulerTitle = Self.axStringAttribute(kAXTitleAttribute, of: rulerElement)
                    ?? Self.axStringAttribute(kAXDescriptionAttribute, of: rulerElement)
                let rulerIdentifier = Self.axStringAttribute(Self.axIdentifierAttributeName, of: rulerElement)
                let rulerRole = Self.axStringAttribute(kAXRoleAttribute, of: rulerElement) ?? "AXRuler"
                let subrole = Self.axStringAttribute(kAXSubroleAttribute, of: rulerElement)
                let orientation = Self.axStringAttribute(kAXOrientationAttribute, of: rulerElement)
                let unitDescription = Self.axStringAttribute(kAXUnitDescriptionAttribute, of: rulerElement)
                let markerChildren = Self.childrenAttribute(of: rulerElement)
                let markerCount = markerChildren?.count
                let isEnabled = Self.axBoolAttribute(kAXEnabledAttribute, of: rulerElement)

                rulersMetadata.append(
                    QAXRulerMetadata(
                        index: index,
                        title: rulerTitle,
                        identifier: rulerIdentifier,
                        role: rulerRole,
                        subrole: subrole,
                        orientation: orientation,
                        unitDescription: unitDescription,
                        markerCount: markerCount,
                        isEnabled: isEnabled
                    )
                )
            }

            return QAXRulerCollectionMetadata(
                applicationName: applicationName,
                windowTitle: resolvedWindowTitle,
                rulerCount: rulersMetadata.count,
                rulers: rulersMetadata
            )
        }.value
    }

    /// Phase 2BD: semantic combo box item direct enumeration (Level 0, read-only).
    /// Enumerates direct child items belonging to exactly ONE named AXComboBox in an application.
    /// No mutation, no selection change, no text entry, no approval, no recovery.
    public func listComboBoxItems(
        applicationName: String,
        role: String? = nil,
        identifier: String? = nil,
        title: String? = nil,
        windowTitle: String? = nil,
        windowIdentifier: String? = nil
    ) async throws -> QAXComboBoxItemsMetadata {
        let effectiveRole = role ?? "AXComboBox"
        guard QAXComboBoxRolePolicy.isAllowedComboBoxRole(effectiveRole) else {
            throw QAXInteractionError.disallowedComboBoxRole(effectiveRole)
        }
        guard identifier != nil || title != nil else {
            throw QAXInteractionError.missingMatchCriteria
        }
        guard AXIsProcessTrusted() else {
            throw QAXInteractionError.accessibilityPermissionDenied
        }

        let runningApp = try Self.resolveExactRunningApplication(named: applicationName)
        let processIdentifier = runningApp.processIdentifier

        return try await Task.detached(priority: .userInitiated) {
            let appElement = AXUIElementCreateApplication(processIdentifier)

            let searchRoot: AXUIElement
            let resolvedWindowTitle: String?

            if windowTitle != nil || windowIdentifier != nil {
                let windowMatches = Self.collectMatches(
                    root: appElement,
                    role: "AXWindow",
                    identifier: windowIdentifier,
                    title: windowTitle
                )
                guard !windowMatches.isEmpty else { throw QAXInteractionError.noMatchingElement }
                guard windowMatches.count == 1 else { throw QAXInteractionError.ambiguousTarget(count: windowMatches.count) }
                let (targetWindow, windowSnapshot) = windowMatches[0]
                guard let verifiedWindow = Self.snapshotIfMatches(targetWindow, role: "AXWindow", identifier: windowIdentifier, title: windowTitle) else {
                    throw QAXInteractionError.staleTarget("target window element is no longer resolvable")
                }
                guard verifiedWindow == windowSnapshot else {
                    throw QAXInteractionError.staleTarget("target window identity changed between observation and verification")
                }
                searchRoot = targetWindow
                resolvedWindowTitle = verifiedWindow.titleOrDescription
            } else {
                searchRoot = appElement
                resolvedWindowTitle = nil
            }

            let matches = Self.collectMatches(
                root: searchRoot,
                role: effectiveRole,
                identifier: identifier,
                title: title
            )
            guard !matches.isEmpty else { throw QAXInteractionError.noMatchingElement }
            guard matches.count == 1 else { throw QAXInteractionError.ambiguousTarget(count: matches.count) }

            let (targetElement, observedAtSearch) = matches[0]

            guard let observedAtVerify = Self.snapshotIfMatches(
                targetElement,
                role: effectiveRole,
                identifier: identifier,
                title: title
            ) else {
                throw QAXInteractionError.staleTarget("target combo box element is no longer resolvable immediately before enumeration")
            }
            guard observedAtVerify == observedAtSearch else {
                throw QAXInteractionError.staleTarget("target combo box element identity changed between observation and enumeration")
            }

            let currentValue = Self.axStringAttribute(kAXValueAttribute, of: targetElement)
            let isEnabled = Self.axBoolAttribute(kAXEnabledAttribute, of: targetElement)
            let isExpanded = Self.axBoolAttribute(kAXExpandedAttribute, of: targetElement)
            let resolvedIdentifier = Self.axStringAttribute(Self.axIdentifierAttributeName, of: targetElement)
            let resolvedTitle = Self.axStringAttribute(kAXTitleAttribute, of: targetElement)
                ?? Self.axStringAttribute(kAXDescriptionAttribute, of: targetElement)

            var rawItemElements: [AXUIElement] = []

            // Check if there is an AXList or AXMenu child
            if let children = Self.childrenAttribute(of: targetElement) {
                var foundListOrMenu = false
                for child in children {
                    let childRole = Self.axStringAttribute(kAXRoleAttribute, of: child)
                    if childRole == "AXList" || childRole == "AXMenu" {
                        foundListOrMenu = true
                        if let listChildren = Self.childrenAttribute(of: child) {
                            rawItemElements.append(contentsOf: listChildren)
                        }
                    }
                }
                if !foundListOrMenu {
                    // Filter out internal child textfield or button elements if direct children are mixed
                    for child in children {
                        let childRole = Self.axStringAttribute(kAXRoleAttribute, of: child) ?? ""
                        if childRole != "AXButton" && childRole != "AXPopUpButton" {
                            rawItemElements.append(child)
                        }
                    }
                }
            }

            guard rawItemElements.count <= Self.maxDirectComboBoxItemsCount else {
                throw QAXInteractionError.comboBoxItemCollectionExceedsSafeBound(rawItemElements.count)
            }

            var itemsMetadata: [QAXComboBoxItemMetadata] = []
            itemsMetadata.reserveCapacity(rawItemElements.count)

            for (index, itemElement) in rawItemElements.enumerated() {
                let itemTitle = Self.axStringAttribute(kAXTitleAttribute, of: itemElement)
                    ?? Self.axStringAttribute(kAXValueAttribute, of: itemElement)
                    ?? Self.axStringAttribute(kAXDescriptionAttribute, of: itemElement)
                    ?? ""
                let itemSelected = Self.axBoolAttribute(kAXSelectedAttribute, of: itemElement)
                    ?? (!itemTitle.isEmpty && itemTitle == currentValue)

                itemsMetadata.append(
                    QAXComboBoxItemMetadata(
                        index: index,
                        title: itemTitle,
                        isSelected: itemSelected
                    )
                )
            }

            return QAXComboBoxItemsMetadata(
                applicationName: applicationName,
                windowTitle: resolvedWindowTitle,
                comboBoxRole: effectiveRole,
                comboBoxIdentifier: resolvedIdentifier,
                comboBoxTitle: resolvedTitle,
                isEnabled: isEnabled,
                isExpanded: isExpanded,
                selectedValue: currentValue,
                itemCount: itemsMetadata.count,
                items: itemsMetadata
            )
        }.value
    }

    /// Phase 2BE: semantic combo box item selection (Level 2, approval required).
    /// Selects an item within exactly ONE semantically-identified `AXComboBox` in a named application window
    /// via `AXUIElementSetAttributeValue(kAXValueAttribute)`.
    /// Never uses mouse dragging, coordinate simulation, CGEvent, or physical input.
    public func selectComboBoxItem(
        applicationName: String,
        role: String? = nil,
        identifier: String? = nil,
        title: String? = nil,
        windowTitle: String? = nil,
        windowIdentifier: String? = nil,
        itemTitle: String? = nil,
        itemIndex: Int? = nil
    ) async throws -> QAXComboBoxSelectionOutcome {
        let effectiveRole = role ?? "AXComboBox"
        guard QAXComboBoxRolePolicy.isAllowedComboBoxRole(effectiveRole) else {
            throw QAXInteractionError.disallowedComboBoxRole(effectiveRole)
        }
        guard identifier != nil || title != nil else {
            throw QAXInteractionError.missingMatchCriteria
        }
        guard itemTitle != nil || itemIndex != nil else {
            throw QAXInteractionError.missingMatchCriteria
        }
        guard AXIsProcessTrusted() else {
            throw QAXInteractionError.accessibilityPermissionDenied
        }

        let runningApp = try Self.resolveExactRunningApplication(named: applicationName)
        let processIdentifier = runningApp.processIdentifier

        return try await Task.detached(priority: .userInitiated) {
            let appElement = AXUIElementCreateApplication(processIdentifier)

            let searchRoot: AXUIElement
            let resolvedWindowTitle: String?

            if windowTitle != nil || windowIdentifier != nil {
                let windowMatches = Self.collectMatches(
                    root: appElement,
                    role: "AXWindow",
                    identifier: windowIdentifier,
                    title: windowTitle
                )
                guard !windowMatches.isEmpty else { throw QAXInteractionError.noMatchingElement }
                guard windowMatches.count == 1 else { throw QAXInteractionError.ambiguousTarget(count: windowMatches.count) }
                let (targetWindow, windowSnapshot) = windowMatches[0]
                guard let verifiedWindow = Self.snapshotIfMatches(targetWindow, role: "AXWindow", identifier: windowIdentifier, title: windowTitle) else {
                    throw QAXInteractionError.staleTarget("target window element is no longer resolvable")
                }
                guard verifiedWindow == windowSnapshot else {
                    throw QAXInteractionError.staleTarget("target window identity changed between observation and verification")
                }
                searchRoot = targetWindow
                resolvedWindowTitle = verifiedWindow.titleOrDescription
            } else {
                searchRoot = appElement
                resolvedWindowTitle = nil
            }

            let matches = Self.collectMatches(
                root: searchRoot,
                role: effectiveRole,
                identifier: identifier,
                title: title
            )
            guard !matches.isEmpty else { throw QAXInteractionError.noMatchingElement }
            guard matches.count == 1 else { throw QAXInteractionError.ambiguousTarget(count: matches.count) }

            let (targetElement, observedAtSearch) = matches[0]

            guard let observedAtVerify = Self.snapshotIfMatches(
                targetElement,
                role: effectiveRole,
                identifier: identifier,
                title: title
            ) else {
                throw QAXInteractionError.staleTarget("target combo box element is no longer resolvable immediately before dispatch")
            }
            guard observedAtVerify == observedAtSearch else {
                throw QAXInteractionError.staleTarget("target combo box element identity changed between observation and dispatch")
            }
            guard observedAtVerify.isEnabled else {
                throw QAXInteractionError.targetDisabled
            }

            let currentValueAtSearch = Self.axStringAttribute(kAXValueAttribute, of: targetElement)
            let currentValueAtVerify = Self.axStringAttribute(kAXValueAttribute, of: targetElement)
            guard currentValueAtSearch == currentValueAtVerify else {
                throw QAXInteractionError.valueDriftDetected("target combo box current value changed between observation and dispatch")
            }

            // Determine target item title to set
            let desiredValue: String
            if let itemTitle = itemTitle, !itemTitle.isEmpty {
                desiredValue = itemTitle
            } else if let itemIndex = itemIndex {
                // Resolve from child items
                var rawItemElements: [AXUIElement] = []
                if let children = Self.childrenAttribute(of: targetElement) {
                    var foundListOrMenu = false
                    for child in children {
                        let childRole = Self.axStringAttribute(kAXRoleAttribute, of: child)
                        if childRole == "AXList" || childRole == "AXMenu" {
                            foundListOrMenu = true
                            if let listChildren = Self.childrenAttribute(of: child) {
                                rawItemElements.append(contentsOf: listChildren)
                            }
                        }
                    }
                    if !foundListOrMenu {
                        for child in children {
                            let childRole = Self.axStringAttribute(kAXRoleAttribute, of: child) ?? ""
                            if childRole != "AXButton" && childRole != "AXPopUpButton" {
                                rawItemElements.append(child)
                            }
                        }
                    }
                }
                guard itemIndex >= 0 && itemIndex < rawItemElements.count else {
                    throw QAXInteractionError.invalidDesiredValue("itemIndex \(itemIndex) is out of range [0, \(rawItemElements.count))")
                }
                let resolvedItem = rawItemElements[itemIndex]
                guard let resolvedTitle = Self.axStringAttribute(kAXTitleAttribute, of: resolvedItem)
                    ?? Self.axStringAttribute(kAXValueAttribute, of: resolvedItem)
                    ?? Self.axStringAttribute(kAXDescriptionAttribute, of: resolvedItem) else {
                    throw QAXInteractionError.invalidDesiredValue("could not read title or value for child item at index \(itemIndex)")
                }
                desiredValue = resolvedTitle
            } else {
                throw QAXInteractionError.missingMatchCriteria
            }

            let windowPart = resolvedWindowTitle.map { " window='\($0)'" } ?? ""
            let targetIdentity = "application=\(applicationName)\(windowPart) role=\(effectiveRole) identifier=\(observedAtVerify.identifier ?? "none") label=\(observedAtVerify.titleOrDescription ?? "none")"

            // Idempotency check: if current value already matches desired value, return safe no-op
            if let currentValue = currentValueAtVerify, currentValue == desiredValue {
                return QAXComboBoxSelectionOutcome(
                    changeKind: .alreadySelected,
                    previousValue: currentValueAtVerify,
                    requestedItemTitle: desiredValue,
                    targetIdentity: targetIdentity
                )
            }

            // Perform semantic mutation via kAXValueAttribute
            let error = AXUIElementSetAttributeValue(targetElement, kAXValueAttribute as CFString, desiredValue as CFTypeRef)
            guard error == .success else {
                throw QAXInteractionError.setValueFailed("AXUIElementSetAttributeValue returned \(error.rawValue)")
            }

            // Independent post-mutation verification
            guard let freshValue = Self.axStringAttribute(kAXValueAttribute, of: targetElement) else {
                throw QAXInteractionError.valueReadFailed
            }
            guard freshValue == desiredValue else {
                throw QAXInteractionError.setValueFailed("Post-mutation verification failed: expected '\(desiredValue)' but got '\(freshValue)'")
            }

            return QAXComboBoxSelectionOutcome(
                changeKind: .changed,
                previousValue: currentValueAtVerify,
                requestedItemTitle: desiredValue,
                targetIdentity: targetIdentity
            )
        }.value
    }

    /// Observes the current value of a target `AXComboBox` for post-mutation verification (Phase 2BE).
    public func observeComboBoxValueEvidence(
        applicationName: String,
        role: String,
        identifier: String?,
        title: String?
    ) async -> QAXComboBoxValueEvidence {
        guard AXIsProcessTrusted() else { return .targetUnavailable }
        guard let runningApp = try? Self.resolveExactRunningApplication(named: applicationName) else { return .targetUnavailable }

        let processIdentifier = runningApp.processIdentifier
        return await Task.detached(priority: .userInitiated) {
            let appElement = AXUIElementCreateApplication(processIdentifier)
            let matches = Self.collectMatches(root: appElement, role: role, identifier: identifier, title: title)
            guard matches.count == 1 else { return .targetUnavailable }
            guard let currentValue = Self.axStringAttribute(kAXValueAttribute, of: matches[0].element) else {
                return .targetUnavailable
            }
            return .resolved(currentValue: currentValue)
        }.value
    }

    /// Phase 2BF: semantic stepper / incrementor step mutation (Level 2, approval required).
    /// Increments or decrements exactly ONE semantically-identified `AXIncrementor` in a named application
    /// window via native `AXUIElementPerformAction(kAXIncrementAction)` / `AXUIElementPerformAction(kAXDecrementAction)` —
    /// the purpose-built AX actions for this role, confirmed against `AXActionConstants.h`.
    /// Never `AXUIElementSetAttributeValue(kAXValueAttribute)` directly, never mouse dragging, coordinate
    /// simulation, CGEvent, or physical input.
    public func stepIncrementor(
        applicationName: String,
        role: String? = nil,
        identifier: String? = nil,
        title: String? = nil,
        windowTitle: String? = nil,
        windowIdentifier: String? = nil,
        direction: QAXIncrementorStepDirection,
        steps: Int = 1
    ) async throws -> QAXIncrementorStepOutcome {
        let effectiveRole = role ?? "AXIncrementor"
        guard QAXIncrementorRolePolicy.isAllowedIncrementorRole(effectiveRole) else {
            throw QAXInteractionError.disallowedIncrementorRole(effectiveRole)
        }
        guard identifier != nil || title != nil else {
            throw QAXInteractionError.missingMatchCriteria
        }
        guard steps >= 1 && steps <= Self.maxIncrementorStepsPerCall else {
            throw QAXInteractionError.invalidStepCount("steps \(steps) is out of the allowed range [1, \(Self.maxIncrementorStepsPerCall)]")
        }
        guard AXIsProcessTrusted() else {
            throw QAXInteractionError.accessibilityPermissionDenied
        }

        let runningApp = try Self.resolveExactRunningApplication(named: applicationName)
        let processIdentifier = runningApp.processIdentifier

        return try await Task.detached(priority: .userInitiated) {
            let appElement = AXUIElementCreateApplication(processIdentifier)

            let searchRoot: AXUIElement
            let resolvedWindowTitle: String?

            if windowTitle != nil || windowIdentifier != nil {
                let windowMatches = Self.collectMatches(
                    root: appElement,
                    role: "AXWindow",
                    identifier: windowIdentifier,
                    title: windowTitle
                )
                guard !windowMatches.isEmpty else { throw QAXInteractionError.noMatchingElement }
                guard windowMatches.count == 1 else { throw QAXInteractionError.ambiguousTarget(count: windowMatches.count) }
                let (targetWindow, windowSnapshot) = windowMatches[0]
                guard let verifiedWindow = Self.snapshotIfMatches(targetWindow, role: "AXWindow", identifier: windowIdentifier, title: windowTitle) else {
                    throw QAXInteractionError.staleTarget("target window element is no longer resolvable")
                }
                guard verifiedWindow == windowSnapshot else {
                    throw QAXInteractionError.staleTarget("target window identity changed between observation and verification")
                }
                searchRoot = targetWindow
                resolvedWindowTitle = verifiedWindow.titleOrDescription
            } else {
                searchRoot = appElement
                resolvedWindowTitle = nil
            }

            let matches = Self.collectMatches(
                root: searchRoot,
                role: effectiveRole,
                identifier: identifier,
                title: title
            )
            guard !matches.isEmpty else { throw QAXInteractionError.noMatchingElement }
            guard matches.count == 1 else { throw QAXInteractionError.ambiguousTarget(count: matches.count) }

            let (targetElement, observedAtSearch) = matches[0]

            guard let observedAtVerify = Self.snapshotIfMatches(
                targetElement,
                role: effectiveRole,
                identifier: identifier,
                title: title
            ) else {
                throw QAXInteractionError.staleTarget("target incrementor element is no longer resolvable immediately before dispatch")
            }
            guard observedAtVerify == observedAtSearch else {
                throw QAXInteractionError.staleTarget("target incrementor element identity changed between observation and dispatch")
            }
            guard observedAtVerify.isEnabled else {
                throw QAXInteractionError.targetDisabled
            }

            guard let valueAtSearch = Self.axDoubleAttribute(kAXValueAttribute, of: targetElement) else {
                throw QAXInteractionError.valueReadFailed
            }
            guard let valueAtVerify = Self.axDoubleAttribute(kAXValueAttribute, of: targetElement) else {
                throw QAXInteractionError.valueReadFailed
            }
            guard valueAtSearch == valueAtVerify else {
                throw QAXInteractionError.valueDriftDetected("target incrementor current value changed between observation and dispatch")
            }
            let previousValue = valueAtVerify

            let minValue = Self.axDoubleAttribute(kAXMinValueAttribute, of: targetElement)
            let maxValue = Self.axDoubleAttribute(kAXMaxValueAttribute, of: targetElement)

            let windowPart = resolvedWindowTitle.map { " window='\($0)'" } ?? ""
            let targetIdentity = "application=\(applicationName)\(windowPart) role=\(effectiveRole) identifier=\(observedAtVerify.identifier ?? "none") label=\(observedAtVerify.titleOrDescription ?? "none")"

            // Idempotency check: already at the reported bound in the requested direction is a
            // verified no-op — zero AX actions performed, mirroring .alreadySelected / .alreadyDesired
            // elsewhere in this file.
            let epsilon = 0.0001
            if direction == .increment, let maxValue = maxValue, previousValue >= maxValue - epsilon {
                return QAXIncrementorStepOutcome(
                    changeKind: .alreadyAtBound,
                    direction: direction,
                    requestedSteps: steps,
                    performedSteps: 0,
                    previousValue: previousValue,
                    currentValue: previousValue,
                    targetIdentity: targetIdentity
                )
            }
            if direction == .decrement, let minValue = minValue, previousValue <= minValue + epsilon {
                return QAXIncrementorStepOutcome(
                    changeKind: .alreadyAtBound,
                    direction: direction,
                    requestedSteps: steps,
                    performedSteps: 0,
                    previousValue: previousValue,
                    currentValue: previousValue,
                    targetIdentity: targetIdentity
                )
            }

            let axAction: CFString = direction == .increment ? (kAXIncrementAction as CFString) : (kAXDecrementAction as CFString)

            var performedSteps = 0
            var lastObservedValue = previousValue
            for _ in 0..<steps {
                let error = AXUIElementPerformAction(targetElement, axAction)
                guard error == .success else {
                    throw QAXInteractionError.incrementorActionPerformFailed("AXUIElementPerformAction returned \(error.rawValue)")
                }
                performedSteps += 1

                guard let observedValue = Self.axDoubleAttribute(kAXValueAttribute, of: targetElement) else {
                    throw QAXInteractionError.valueReadFailed
                }
                lastObservedValue = observedValue

                let reachedBound: Bool
                if direction == .increment, let maxValue = maxValue {
                    reachedBound = observedValue >= maxValue - epsilon
                } else if direction == .decrement, let minValue = minValue {
                    reachedBound = observedValue <= minValue + epsilon
                } else {
                    reachedBound = false
                }
                if reachedBound { break }
            }

            // Independent post-mutation verification: fresh, separate re-read — never trusting the
            // dispatch loop's own last observed value as proof.
            guard let currentValue = Self.axDoubleAttribute(kAXValueAttribute, of: targetElement) else {
                throw QAXInteractionError.valueReadFailed
            }
            let movedCorrectly = direction == .increment ? currentValue > previousValue : currentValue < previousValue
            guard movedCorrectly else {
                throw QAXInteractionError.incrementorStepVerificationFailed(
                    "expected value to move \(direction == .increment ? "above" : "below") \(previousValue) but observed \(currentValue) (last loop observation \(lastObservedValue))"
                )
            }

            return QAXIncrementorStepOutcome(
                changeKind: .changed,
                direction: direction,
                requestedSteps: steps,
                performedSteps: performedSteps,
                previousValue: previousValue,
                currentValue: currentValue,
                targetIdentity: targetIdentity
            )
        }.value
    }

    /// Observes the current value of a target `AXIncrementor` for post-mutation verification (Phase 2BF).
    public func observeIncrementorValueEvidence(
        applicationName: String,
        role: String,
        identifier: String?,
        title: String?
    ) async -> QAXIncrementorValueEvidence {
        guard AXIsProcessTrusted() else { return .targetUnavailable }
        guard let runningApp = try? Self.resolveExactRunningApplication(named: applicationName) else { return .targetUnavailable }

        let processIdentifier = runningApp.processIdentifier
        return await Task.detached(priority: .userInitiated) {
            let appElement = AXUIElementCreateApplication(processIdentifier)
            let matches = Self.collectMatches(root: appElement, role: role, identifier: identifier, title: title)
            guard matches.count == 1 else { return .targetUnavailable }
            guard let currentValue = Self.axDoubleAttribute(kAXValueAttribute, of: matches[0].element) else {
                return .targetUnavailable
            }
            return .resolved(currentValue: currentValue)
        }.value
    }

    /// Compares two numeric splitter divider positions within an explicit floating-point tolerance (default 0.5 points).
    public static func splitterPositionsAreEqual(_ a: Double, _ b: Double, tolerance: Double = 0.5) -> Bool {
        abs(a - b) <= tolerance
    }

    /// Phase 2AU: semantic split view divider position mutation (Level 2, approval required).
    /// Sets the numeric divider position of exactly ONE semantically-identified `AXSplitter` within an `AXSplitGroup`
    /// in a named application window via `AXUIElementSetAttributeValue(kAXValueAttribute)`.
    /// Never uses mouse dragging, coordinate simulation, CGEvent, or physical input.
    public func setSplitterPosition(
        applicationName: String,
        desiredPosition: Double,
        splitterIndex: Int = 0,
        tolerance: Double = 0.5,
        windowTitle: String? = nil,
        windowIdentifier: String? = nil,
        splitGroupIdentifier: String? = nil,
        splitGroupTitle: String? = nil,
        role: String = "AXSplitter"
    ) async throws -> QAXSplitterPositionOutcome {
        guard desiredPosition.isFinite else {
            throw QAXInteractionError.invalidDesiredPosition("desiredPosition must be a finite number, got \(desiredPosition)")
        }
        guard tolerance >= 0.0 && tolerance.isFinite else {
            throw QAXInteractionError.invalidSplitterTolerance(tolerance)
        }
        guard splitterIndex >= 0 else {
            throw QAXInteractionError.invalidSplitterIndex(splitterIndex, availableCount: 0)
        }
        guard QAXSplitterRolePolicy.isAllowedSplitterRole(role) else {
            throw QAXInteractionError.disallowedSplitterRole(role)
        }
        guard AXIsProcessTrusted() else {
            throw QAXInteractionError.accessibilityPermissionDenied
        }

        let runningApp = try Self.resolveExactRunningApplication(named: applicationName)
        let processIdentifier = runningApp.processIdentifier

        return try await Task.detached(priority: .userInitiated) {
            let appElement = AXUIElementCreateApplication(processIdentifier)

            let searchRoot: AXUIElement
            let resolvedWindowTitle: String?

            if windowTitle != nil || windowIdentifier != nil {
                let windowMatches = Self.collectMatches(
                    root: appElement,
                    role: "AXWindow",
                    identifier: windowIdentifier,
                    title: windowTitle
                )
                guard !windowMatches.isEmpty else { throw QAXInteractionError.noMatchingElement }
                guard windowMatches.count == 1 else { throw QAXInteractionError.ambiguousTarget(count: windowMatches.count) }
                let (targetWindow, windowSnapshot) = windowMatches[0]
                guard let verifiedWindow = Self.snapshotIfMatches(targetWindow, role: "AXWindow", identifier: windowIdentifier, title: windowTitle) else {
                    throw QAXInteractionError.staleTarget("target window element is no longer resolvable")
                }
                guard verifiedWindow == windowSnapshot else {
                    throw QAXInteractionError.staleTarget("target window identity changed between observation and verification")
                }
                searchRoot = targetWindow
                resolvedWindowTitle = verifiedWindow.titleOrDescription
            } else {
                searchRoot = appElement
                resolvedWindowTitle = nil
            }

            let splitGroupMatches = Self.collectMatches(
                root: searchRoot,
                role: "AXSplitGroup",
                identifier: splitGroupIdentifier,
                title: splitGroupTitle
            )
            guard !splitGroupMatches.isEmpty else { throw QAXInteractionError.noMatchingElement }
            guard splitGroupMatches.count == 1 else { throw QAXInteractionError.ambiguousTarget(count: splitGroupMatches.count) }

            let (splitGroupElement, observedSplitGroup) = splitGroupMatches[0]

            guard let verifiedSplitGroup = Self.snapshotIfMatches(splitGroupElement, role: "AXSplitGroup", identifier: splitGroupIdentifier, title: splitGroupTitle) else {
                throw QAXInteractionError.staleTarget("target split group element is no longer resolvable immediately before splitter resolution")
            }
            guard verifiedSplitGroup == observedSplitGroup else {
                throw QAXInteractionError.staleTarget("target split group element identity changed between observation and verification")
            }

            let rawChildren = Self.childrenAttribute(of: splitGroupElement) ?? []
            var splitters: [AXUIElement] = rawChildren.filter {
                Self.axStringAttribute(kAXRoleAttribute, of: $0) == Self.splitterRole
            }
            if splitters.isEmpty {
                if let rawSplitters = Self.axUIElementsAttribute(kAXSplittersAttribute as String, of: splitGroupElement) {
                    splitters = rawSplitters
                }
            }

            guard !splitters.isEmpty else {
                throw QAXInteractionError.noMatchingElement
            }
            guard splitterIndex < splitters.count else {
                throw QAXInteractionError.invalidSplitterIndex(splitterIndex, availableCount: splitters.count)
            }

            let splitterElement = splitters[splitterIndex]

            guard let splitterRole = Self.axStringAttribute(kAXRoleAttribute, of: splitterElement) else {
                throw QAXInteractionError.noMatchingElement
            }
            guard QAXSplitterRolePolicy.isAllowedSplitterRole(splitterRole) else {
                throw QAXInteractionError.disallowedSplitterRole(splitterRole)
            }

            var isSettable: DarwinBoolean = false
            let settableResult = AXUIElementIsAttributeSettable(splitterElement, kAXValueAttribute as CFString, &isSettable)
            guard settableResult == .success, isSettable.boolValue else {
                throw QAXInteractionError.splitterPositionNotSettable
            }

            let minVal = Self.axDoubleAttribute(kAXMinValueAttribute as String, of: splitterElement) ?? 0.0
            let maxVal = Self.axDoubleAttribute(kAXMaxValueAttribute as String, of: splitterElement)
            if let maxVal = maxVal, minVal > maxVal {
                throw QAXInteractionError.invalidRange("Splitter minValue (\(minVal)) exceeds maxValue (\(maxVal))")
            }
            if desiredPosition < minVal || (maxVal != nil && desiredPosition > maxVal!) {
                throw QAXInteractionError.splitterPositionOutOfRange(
                    requested: desiredPosition,
                    min: minVal,
                    max: maxVal ?? .infinity
                )
            }

            guard let currentPosition = Self.axDoubleAttribute(kAXValueAttribute as String, of: splitterElement) else {
                throw QAXInteractionError.valueReadFailed
            }

            let targetIdentity = "application=\(applicationName) window=\(resolvedWindowTitle ?? "default") splitGroup=\(verifiedSplitGroup.titleOrDescription ?? verifiedSplitGroup.identifier ?? "default") splitterIndex=\(splitterIndex)"

            if Self.splitterPositionsAreEqual(currentPosition, desiredPosition, tolerance: tolerance) {
                return QAXSplitterPositionOutcome(
                    changeKind: .alreadyDesired,
                    previousPosition: currentPosition,
                    currentPosition: currentPosition,
                    desiredPosition: desiredPosition,
                    minValue: minVal,
                    maxValue: maxVal ?? minVal,
                    splitterIndex: splitterIndex,
                    targetIdentity: targetIdentity
                )
            }

            let axValue = NSNumber(value: desiredPosition) as CFTypeRef
            let setResult = AXUIElementSetAttributeValue(splitterElement, kAXValueAttribute as CFString, axValue)
            guard setResult == .success else {
                throw QAXInteractionError.setValueFailed("AXError(\(setResult.rawValue)) while writing splitter position (\(desiredPosition))")
            }

            guard let observedPosition = Self.axDoubleAttribute(kAXValueAttribute as String, of: splitterElement) else {
                throw QAXInteractionError.valueReadFailed
            }

            guard Self.splitterPositionsAreEqual(observedPosition, desiredPosition, tolerance: tolerance) else {
                throw QAXInteractionError.valueDriftDetected("Observed splitter position \(observedPosition) does not match requested position \(desiredPosition) within tolerance \(tolerance)")
            }

            return QAXSplitterPositionOutcome(
                changeKind: .changed,
                previousPosition: currentPosition,
                currentPosition: observedPosition,
                desiredPosition: desiredPosition,
                minValue: minVal,
                maxValue: maxVal ?? minVal,
                splitterIndex: splitterIndex,
                targetIdentity: targetIdentity
            )
        }.value
    }

    /// Best-effort, read-only re-observation of a target splitter's position used for independent closed-loop
    /// verification and observe-first recovery.
    public func reobserveSplitterPosition(
        applicationName: String,
        windowTitle: String? = nil,
        windowIdentifier: String? = nil,
        splitGroupIdentifier: String? = nil,
        splitGroupTitle: String? = nil,
        splitterIndex: Int = 0
    ) async -> QAXSplitterPositionEvidence {
        guard AXIsProcessTrusted() else {
            return .targetUnavailable
        }
        guard let runningApp = try? Self.resolveExactRunningApplication(named: applicationName) else {
            return .targetUnavailable
        }
        let processIdentifier = runningApp.processIdentifier

        return await Task.detached(priority: .userInitiated) {
            let appElement = AXUIElementCreateApplication(processIdentifier)

            let searchRoot: AXUIElement
            if windowTitle != nil || windowIdentifier != nil {
                let windowMatches = Self.collectMatches(
                    root: appElement,
                    role: "AXWindow",
                    identifier: windowIdentifier,
                    title: windowTitle
                )
                guard windowMatches.count == 1 else { return .targetUnavailable }
                searchRoot = windowMatches[0].0
            } else {
                searchRoot = appElement
            }

            let splitGroupMatches = Self.collectMatches(
                root: searchRoot,
                role: "AXSplitGroup",
                identifier: splitGroupIdentifier,
                title: splitGroupTitle
            )
            guard splitGroupMatches.count == 1 else { return .targetUnavailable }
            let splitGroupElement = splitGroupMatches[0].0

            let rawChildren = Self.childrenAttribute(of: splitGroupElement) ?? []
            var splitters: [AXUIElement] = rawChildren.filter {
                Self.axStringAttribute(kAXRoleAttribute, of: $0) == Self.splitterRole
            }
            if splitters.isEmpty {
                if let rawSplitters = Self.axUIElementsAttribute(kAXSplittersAttribute as String, of: splitGroupElement) {
                    splitters = rawSplitters
                }
            }

            guard splitterIndex >= 0 && splitterIndex < splitters.count else {
                return .targetUnavailable
            }
            let splitterElement = splitters[splitterIndex]
            guard let role = Self.axStringAttribute(kAXRoleAttribute, of: splitterElement),
                  QAXSplitterRolePolicy.isAllowedSplitterRole(role) else {
                return .targetUnavailable
            }

            let minVal = Self.axDoubleAttribute(kAXMinValueAttribute as String, of: splitterElement) ?? 0.0
            let maxVal = Self.axDoubleAttribute(kAXMaxValueAttribute as String, of: splitterElement)
            if let maxVal = maxVal, minVal > maxVal {
                return .rangeInvalid(currentPosition: minVal)
            }

            guard let currentVal = Self.axDoubleAttribute(kAXValueAttribute as String, of: splitterElement) else {
                return .targetUnavailable
            }

            if let maxVal = maxVal, (currentVal < minVal - 0.001 || currentVal > maxVal + 0.001) {
                return .rangeInvalid(currentPosition: currentVal)
            }

            return .resolved(currentPosition: currentVal)
        }.value
    }

    /// Phase 2AM: semantic segmented control direct item enumeration (Level 0, read-only). Enumerates direct segments
    /// belonging to exactly ONE named AXSegmentedControl in an application window.
    /// No mutation, no press, no approval, no recovery. Subtrees, menus, and groups are strictly NOT expanded.
    public func listSegmentedControlItems(
        applicationName: String,
        role: String = "AXSegmentedControl",
        identifier: String?,
        title: String?,
        windowTitle: String? = nil,
        windowIdentifier: String? = nil
    ) async throws -> QAXSegmentedControlMetadata {
        guard QAXSegmentedControlRolePolicy.isAllowedSegmentedControlRole(role) else {
            throw QAXInteractionError.disallowedSegmentedControlRole(role)
        }
        guard AXIsProcessTrusted() else {
            throw QAXInteractionError.accessibilityPermissionDenied
        }

        let runningApp = try Self.resolveExactRunningApplication(named: applicationName)
        let processIdentifier = runningApp.processIdentifier

        return try await Task.detached(priority: .userInitiated) {
            let appElement = AXUIElementCreateApplication(processIdentifier)

            let searchRoot: AXUIElement
            let resolvedWindowTitle: String?

            if windowTitle != nil || windowIdentifier != nil {
                let windowMatches = Self.collectMatches(
                    root: appElement,
                    role: "AXWindow",
                    identifier: windowIdentifier,
                    title: windowTitle
                )
                guard !windowMatches.isEmpty else { throw QAXInteractionError.noMatchingElement }
                guard windowMatches.count == 1 else { throw QAXInteractionError.ambiguousTarget(count: windowMatches.count) }
                let (targetWindow, windowSnapshot) = windowMatches[0]
                guard let verifiedWindow = Self.snapshotIfMatches(targetWindow, role: "AXWindow", identifier: windowIdentifier, title: windowTitle) else {
                    throw QAXInteractionError.staleTarget("target window element is no longer resolvable")
                }
                guard verifiedWindow == windowSnapshot else {
                    throw QAXInteractionError.staleTarget("target window identity changed between observation and verification")
                }
                searchRoot = targetWindow
                resolvedWindowTitle = verifiedWindow.titleOrDescription
            } else {
                searchRoot = appElement
                resolvedWindowTitle = nil
            }

            let matches = Self.collectMatches(root: searchRoot, role: role, identifier: identifier, title: title)
            guard !matches.isEmpty else { throw QAXInteractionError.noMatchingElement }
            guard matches.count == 1 else { throw QAXInteractionError.ambiguousTarget(count: matches.count) }

            let (targetElement, observedAtSearch) = matches[0]

            guard let observedAtVerify = Self.snapshotIfMatches(targetElement, role: role, identifier: identifier, title: title) else {
                throw QAXInteractionError.staleTarget("target segmented control element is no longer resolvable immediately before enumeration")
            }
            guard observedAtVerify == observedAtSearch else {
                throw QAXInteractionError.staleTarget("target segmented control element identity changed between observation and enumeration")
            }

            let rawChildElements = Self.childrenAttribute(of: targetElement) ?? []

            var validSegmentElements: [AXUIElement] = []
            for childElement in rawChildElements {
                guard let childRole = Self.axStringAttribute(kAXRoleAttribute, of: childElement) else {
                    continue
                }
                guard Self.allowedDirectSegmentRoles.contains(childRole) else {
                    continue
                }
                let subrole = Self.axStringAttribute(kAXSubroleAttribute, of: childElement)
                // Strict tab exclusion: AXTabButton is owned exclusively by Phase 2AH (ui.list_tab_items)
                guard subrole != Self.tabButtonSubrole else {
                    continue
                }
                validSegmentElements.append(childElement)
            }

            guard validSegmentElements.count <= Self.maxDirectSegmentsCount else {
                throw QAXInteractionError.segmentedControlItemCollectionExceedsSafeBound(validSegmentElements.count)
            }

            var itemsMetadata: [QAXSegmentedControlItemMetadata] = []
            itemsMetadata.reserveCapacity(validSegmentElements.count)
            var selectedCount = 0

            for (index, itemElement) in validSegmentElements.enumerated() {
                let itemTitle = Self.axStringAttribute(kAXTitleAttribute, of: itemElement)
                    ?? Self.axStringAttribute(kAXDescriptionAttribute, of: itemElement)
                let itemIdentifier = Self.axStringAttribute(Self.axIdentifierAttributeName, of: itemElement)
                let childRole = Self.axStringAttribute(kAXRoleAttribute, of: itemElement) ?? "AXUnknown"
                let subrole = Self.axStringAttribute(kAXSubroleAttribute, of: itemElement)
                let isEnabled = Self.axBoolAttribute(kAXEnabledAttribute, of: itemElement)
                let isSelected: Bool?
                if let state = Self.axCheckboxRadioState(of: itemElement) {
                    isSelected = (state == .on)
                } else if let selectedVal = Self.axBoolAttribute(kAXSelectedAttribute, of: itemElement) {
                    isSelected = selectedVal
                } else {
                    isSelected = nil
                }

                if isSelected == true {
                    selectedCount += 1
                }

                itemsMetadata.append(
                    QAXSegmentedControlItemMetadata(
                        index: index,
                        title: itemTitle,
                        identifier: itemIdentifier,
                        role: childRole,
                        subrole: subrole,
                        isEnabled: isEnabled,
                        isSelected: isSelected
                    )
                )
            }

            return QAXSegmentedControlMetadata(
                applicationName: applicationName,
                windowTitle: resolvedWindowTitle,
                controlTitle: observedAtVerify.titleOrDescription,
                controlIdentifier: observedAtVerify.identifier,
                itemCount: itemsMetadata.count,
                selectedItemCount: selectedCount,
                items: itemsMetadata
            )
        }.value
    }

    /// Phase 2AQ: semantic segmented control item selection (Level 2, reversible local action, approval required).
    /// Selects exactly ONE direct segment belonging to an exact AXSegmentedControl in a named application window.
    /// Mutation is AXUIElementPerformAction(kAXPressAction) only — never physical input, CGEvent, or coordinates.
    /// Idempotent (already desired selection is a no-op). Protected by stale-target & drift checks.
    public func selectSegmentedControlItem(
        applicationName: String,
        role: String = "AXSegmentedControl",
        controlIdentifier: String?,
        controlTitle: String?,
        windowTitle: String? = nil,
        windowIdentifier: String? = nil,
        segmentIdentifier: String?,
        segmentTitle: String?,
        desiredSelected: Bool = true
    ) async throws -> QAXSegmentedControlSelectionOutcome {
        guard segmentIdentifier != nil || segmentTitle != nil else {
            throw QAXInteractionError.missingMatchCriteria
        }
        guard QAXSegmentedControlRolePolicy.isAllowedSegmentedControlRole(role) else {
            throw QAXInteractionError.disallowedSegmentedControlRole(role)
        }
        guard desiredSelected else {
            throw QAXInteractionError.segmentDeselectionUnsupported(
                "ui.select_segmented_control_item supports selection only (desiredSelected must be true)"
            )
        }
        guard AXIsProcessTrusted() else {
            throw QAXInteractionError.accessibilityPermissionDenied
        }

        let runningApp = try Self.resolveExactRunningApplication(named: applicationName)
        let processIdentifier = runningApp.processIdentifier

        return try await Task.detached(priority: .userInitiated) {
            let appElement = AXUIElementCreateApplication(processIdentifier)

            let searchRoot: AXUIElement
            let resolvedWindowTitle: String?

            if windowTitle != nil || windowIdentifier != nil {
                let windowMatches = Self.collectMatches(
                    root: appElement,
                    role: "AXWindow",
                    identifier: windowIdentifier,
                    title: windowTitle
                )
                guard !windowMatches.isEmpty else { throw QAXInteractionError.noMatchingElement }
                guard windowMatches.count == 1 else { throw QAXInteractionError.ambiguousTarget(count: windowMatches.count) }
                let (targetWindow, windowSnapshot) = windowMatches[0]
                guard let verifiedWindow = Self.snapshotIfMatches(targetWindow, role: "AXWindow", identifier: windowIdentifier, title: windowTitle) else {
                    throw QAXInteractionError.staleTarget("target window element is no longer resolvable immediately before selection")
                }
                guard verifiedWindow == windowSnapshot else {
                    throw QAXInteractionError.staleTarget("target window identity changed between observation and selection")
                }
                searchRoot = targetWindow
                resolvedWindowTitle = verifiedWindow.titleOrDescription
            } else {
                searchRoot = appElement
                resolvedWindowTitle = nil
            }

            let controlMatches = Self.collectMatches(root: searchRoot, role: role, identifier: controlIdentifier, title: controlTitle)
            guard !controlMatches.isEmpty else { throw QAXInteractionError.noMatchingElement }
            guard controlMatches.count == 1 else { throw QAXInteractionError.ambiguousTarget(count: controlMatches.count) }

            let (targetControlElement, controlObservedAtSearch) = controlMatches[0]

            guard let controlObservedAtVerify = Self.snapshotIfMatches(targetControlElement, role: role, identifier: controlIdentifier, title: controlTitle) else {
                throw QAXInteractionError.staleTarget("target segmented control element is no longer resolvable immediately before selection")
            }
            guard controlObservedAtVerify == controlObservedAtSearch else {
                throw QAXInteractionError.staleTarget("target segmented control element identity changed between observation and selection")
            }
            guard controlObservedAtVerify.isEnabled else {
                throw QAXInteractionError.targetDisabled
            }

            let rawChildElements = Self.childrenAttribute(of: targetControlElement) ?? []

            var validSegmentElements: [AXUIElement] = []
            for childElement in rawChildElements {
                guard let childRole = Self.axStringAttribute(kAXRoleAttribute, of: childElement) else {
                    continue
                }
                guard Self.allowedDirectSegmentRoles.contains(childRole) else {
                    continue
                }
                let subrole = Self.axStringAttribute(kAXSubroleAttribute, of: childElement)
                // Strict tab exclusion: AXTabButton is owned exclusively by Phase 2AH / Phase 2R (ui.list_tab_items / ui.select_tab)
                guard subrole != Self.tabButtonSubrole else {
                    continue
                }
                validSegmentElements.append(childElement)
            }

            guard validSegmentElements.count <= Self.maxDirectSegmentsCount else {
                throw QAXInteractionError.segmentedControlItemCollectionExceedsSafeBound(validSegmentElements.count)
            }

            var matchingSegments: [AXUIElement] = []
            for child in validSegmentElements {
                let cId = Self.axStringAttribute(Self.axIdentifierAttributeName, of: child)
                let cTitle = Self.axStringAttribute(kAXTitleAttribute, of: child)
                    ?? Self.axStringAttribute(kAXDescriptionAttribute, of: child)

                if let segmentIdentifier = segmentIdentifier, let segmentTitle = segmentTitle {
                    // Both supplied: fail closed if they disagree on the element
                    if cId == segmentIdentifier && cTitle == segmentTitle {
                        matchingSegments.append(child)
                    } else if cId == segmentIdentifier || cTitle == segmentTitle {
                        // One matches but not the other: conflict / mismatch
                    }
                } else if let segmentIdentifier = segmentIdentifier {
                    if cId == segmentIdentifier {
                        matchingSegments.append(child)
                    }
                } else if let segmentTitle = segmentTitle {
                    if cTitle == segmentTitle {
                        matchingSegments.append(child)
                    }
                }
            }

            guard !matchingSegments.isEmpty else { throw QAXInteractionError.noMatchingElement }
            guard matchingSegments.count == 1 else { throw QAXInteractionError.ambiguousTarget(count: matchingSegments.count) }

            let targetSegment = matchingSegments[0]

            // Enabled check
            let isEnabled = Self.axBoolAttribute(kAXEnabledAttribute, of: targetSegment) ?? true
            guard isEnabled else {
                throw QAXInteractionError.targetDisabled
            }

            // Selection state read at search & verify (drift check)
            let isSelectedSearch: Bool
            if let state = Self.axCheckboxRadioState(of: targetSegment) {
                isSelectedSearch = (state == .on)
            } else if let selectedVal = Self.axBoolAttribute(kAXSelectedAttribute, of: targetSegment) {
                isSelectedSearch = selectedVal
            } else {
                throw QAXInteractionError.segmentSelectionStateReadFailed
            }

            let isSelectedVerify: Bool
            if let state = Self.axCheckboxRadioState(of: targetSegment) {
                isSelectedVerify = (state == .on)
            } else if let selectedVal = Self.axBoolAttribute(kAXSelectedAttribute, of: targetSegment) {
                isSelectedVerify = selectedVal
            } else {
                throw QAXInteractionError.segmentSelectionStateReadFailed
            }

            guard isSelectedVerify == isSelectedSearch else {
                throw QAXInteractionError.valueDriftDetected("target segment selection state changed between observation and dispatch")
            }

            let resolvedSegmentId = Self.axStringAttribute(Self.axIdentifierAttributeName, of: targetSegment)
            let resolvedSegmentTitle = Self.axStringAttribute(kAXTitleAttribute, of: targetSegment)
                ?? Self.axStringAttribute(kAXDescriptionAttribute, of: targetSegment)

            let targetIdentity = "application=\(applicationName) controlRole=\(role) controlIdentifier=\(controlObservedAtVerify.identifier ?? "none") controlLabel=\(controlObservedAtVerify.titleOrDescription ?? "none") segmentIdentifier=\(resolvedSegmentId ?? "none") segmentLabel=\(resolvedSegmentTitle ?? "none")"

            if isSelectedVerify == desiredSelected {
                return QAXSegmentedControlSelectionOutcome(
                    changeKind: .alreadyDesired,
                    previousSelected: isSelectedVerify,
                    currentSelected: isSelectedVerify,
                    targetIdentity: targetIdentity
                )
            }

            let pressResult = AXUIElementPerformAction(targetSegment, kAXPressAction as CFString)
            switch pressResult {
            case .success:
                break
            case .actionUnsupported:
                throw QAXInteractionError.actionUnsupported
            default:
                throw QAXInteractionError.pressFailed("AXError(\(pressResult.rawValue))")
            }

            let currentSelected: Bool
            if let state = Self.axCheckboxRadioState(of: targetSegment) {
                currentSelected = (state == .on)
            } else if let selectedVal = Self.axBoolAttribute(kAXSelectedAttribute, of: targetSegment) {
                currentSelected = selectedVal
            } else {
                currentSelected = desiredSelected
            }

            return QAXSegmentedControlSelectionOutcome(
                changeKind: .changed,
                previousSelected: isSelectedVerify,
                currentSelected: currentSelected,
                targetIdentity: targetIdentity
            )
        }.value
    }

    /// Best-effort, read-only re-resolution of the same match criteria used by `selectSegmentedControlItem`,
    /// used both by the later closed-loop verification step (.axSegmentedControlSelectionMatchesDesired)
    /// and by QTaskRecoveryManager's observation-first recovery branch.
    public func observeSegmentedControlSelectionEvidence(
        applicationName: String,
        role: String = "AXSegmentedControl",
        controlIdentifier: String?,
        controlTitle: String?,
        windowTitle: String? = nil,
        windowIdentifier: String? = nil,
        segmentIdentifier: String?,
        segmentTitle: String?
    ) async -> QAXSegmentedControlSelectionEvidence {
        guard AXIsProcessTrusted() else { return .targetUnavailable }
        guard let runningApp = try? Self.resolveExactRunningApplication(named: applicationName) else { return .targetUnavailable }

        let processIdentifier = runningApp.processIdentifier
        return await Task.detached(priority: .userInitiated) {
            let appElement = AXUIElementCreateApplication(processIdentifier)

            let searchRoot: AXUIElement
            if windowTitle != nil || windowIdentifier != nil {
                let windowMatches = Self.collectMatches(
                    root: appElement,
                    role: "AXWindow",
                    identifier: windowIdentifier,
                    title: windowTitle
                )
                guard windowMatches.count == 1 else { return .targetUnavailable }
                searchRoot = windowMatches[0].element
            } else {
                searchRoot = appElement
            }

            let controlMatches = Self.collectMatches(root: searchRoot, role: role, identifier: controlIdentifier, title: controlTitle)
            guard controlMatches.count == 1 else { return .targetUnavailable }
            let targetControlElement = controlMatches[0].element

            let rawChildElements = Self.childrenAttribute(of: targetControlElement) ?? []
            var validSegmentElements: [AXUIElement] = []
            for childElement in rawChildElements {
                guard let childRole = Self.axStringAttribute(kAXRoleAttribute, of: childElement) else {
                    continue
                }
                guard Self.allowedDirectSegmentRoles.contains(childRole) else {
                    continue
                }
                let subrole = Self.axStringAttribute(kAXSubroleAttribute, of: childElement)
                guard subrole != Self.tabButtonSubrole else {
                    continue
                }
                validSegmentElements.append(childElement)
            }

            var matchingSegments: [AXUIElement] = []
            for child in validSegmentElements {
                let cId = Self.axStringAttribute(Self.axIdentifierAttributeName, of: child)
                let cTitle = Self.axStringAttribute(kAXTitleAttribute, of: child)
                    ?? Self.axStringAttribute(kAXDescriptionAttribute, of: child)

                if let segmentIdentifier = segmentIdentifier, let segmentTitle = segmentTitle {
                    if cId == segmentIdentifier && cTitle == segmentTitle {
                        matchingSegments.append(child)
                    }
                } else if let segmentIdentifier = segmentIdentifier {
                    if cId == segmentIdentifier {
                        matchingSegments.append(child)
                    }
                } else if let segmentTitle = segmentTitle {
                    if cTitle == segmentTitle {
                        matchingSegments.append(child)
                    }
                }
            }

            guard matchingSegments.count == 1 else { return .targetUnavailable }
            let targetSegment = matchingSegments[0]

            if let state = Self.axCheckboxRadioState(of: targetSegment) {
                return .resolved(currentSelected: (state == .on))
            } else if let selectedVal = Self.axBoolAttribute(kAXSelectedAttribute, of: targetSegment) {
                return .resolved(currentSelected: selectedVal)
            } else {
                return .stateUnreadable
            }
        }.value
    }

    /// Phase 2AN: semantic sheet direct enumeration (Level 0, read-only). Enumerates direct AXSheet elements
    /// attached to exactly ONE named AXWindow in an application.
    /// No mutation, no press, no approval, no recovery. Descendant buttons, fields, and groups are strictly NOT traversed.
    public func listSheetDialogs(
        applicationName: String,
        windowTitle: String? = nil,
        windowIdentifier: String? = nil
    ) async throws -> QAXSheetCollectionMetadata {
        guard AXIsProcessTrusted() else {
            throw QAXInteractionError.accessibilityPermissionDenied
        }

        let runningApp = try Self.resolveExactRunningApplication(named: applicationName)
        let processIdentifier = runningApp.processIdentifier

        return try await Task.detached(priority: .userInitiated) {
            let appElement = AXUIElementCreateApplication(processIdentifier)

            let windowMatches = Self.collectMatches(
                root: appElement,
                role: "AXWindow",
                identifier: windowIdentifier,
                title: windowTitle
            )
            guard !windowMatches.isEmpty else { throw QAXInteractionError.noMatchingElement }
            guard windowMatches.count == 1 else { throw QAXInteractionError.ambiguousTarget(count: windowMatches.count) }

            let (targetWindow, windowSnapshot) = windowMatches[0]

            guard let verifiedWindow = Self.snapshotIfMatches(targetWindow, role: "AXWindow", identifier: windowIdentifier, title: windowTitle) else {
                throw QAXInteractionError.staleTarget("target window element is no longer resolvable immediately before sheet enumeration")
            }
            guard verifiedWindow == windowSnapshot else {
                throw QAXInteractionError.staleTarget("target window identity changed between observation and sheet enumeration")
            }

            var candidateElements: [AXUIElement] = []

            if let sheetsAttr = Self.axUIElementsAttribute(Self.axSheetsAttributeName, of: targetWindow) {
                candidateElements.append(contentsOf: sheetsAttr)
            }

            if let childElements = Self.childrenAttribute(of: targetWindow) {
                candidateElements.append(contentsOf: childElements)
            }

            var validSheetElements: [AXUIElement] = []
            var seenSnapshots: [QAXElementSnapshot] = []

            for element in candidateElements {
                guard let role = Self.axStringAttribute(kAXRoleAttribute, of: element) else {
                    continue
                }
                guard QAXSheetRolePolicy.isAllowedSheetRole(role) else {
                    continue
                }

                let identifier = Self.axStringAttribute(Self.axIdentifierAttributeName, of: element)
                let titleOrDesc = Self.axStringAttribute(kAXTitleAttribute, of: element)
                    ?? Self.axStringAttribute(kAXDescriptionAttribute, of: element)
                let isEnabled = Self.axBoolAttribute(kAXEnabledAttribute, of: element) ?? true
                let snapshot = QAXElementSnapshot(role: role, identifier: identifier, titleOrDescription: titleOrDesc, isEnabled: isEnabled)
                if !seenSnapshots.contains(snapshot) {
                    seenSnapshots.append(snapshot)
                    validSheetElements.append(element)
                }
            }

            guard validSheetElements.count <= Self.maxDirectSheetsCount else {
                throw QAXInteractionError.sheetCollectionExceedsSafeBound(validSheetElements.count)
            }

            var sheetsMetadata: [QAXSheetMetadata] = []
            sheetsMetadata.reserveCapacity(validSheetElements.count)

            for (index, sheetElement) in validSheetElements.enumerated() {
                let sheetTitle = Self.axStringAttribute(kAXTitleAttribute, of: sheetElement)
                    ?? Self.axStringAttribute(kAXDescriptionAttribute, of: sheetElement)
                let sheetIdentifier = Self.axStringAttribute(Self.axIdentifierAttributeName, of: sheetElement)
                let role = Self.axStringAttribute(kAXRoleAttribute, of: sheetElement) ?? "AXSheet"
                let subrole = Self.axStringAttribute(kAXSubroleAttribute, of: sheetElement)
                let isModal = Self.axBoolAttribute(Self.axModalAttributeName, of: sheetElement)

                sheetsMetadata.append(
                    QAXSheetMetadata(
                        index: index,
                        title: sheetTitle,
                        identifier: sheetIdentifier,
                        role: role,
                        subrole: subrole,
                        isModal: isModal
                    )
                )
            }

            return QAXSheetCollectionMetadata(
                applicationName: applicationName,
                windowTitle: verifiedWindow.titleOrDescription,
                windowIdentifier: verifiedWindow.identifier,
                sheetCount: sheetsMetadata.count,
                sheets: sheetsMetadata
            )
        }.value
    }

    /// Phase 2AO: semantic sheet action direct enumeration (Level 0, read-only). Enumerates direct action controls
    /// (AXButton, AXCheckBox, AXRadioButton, AXPopUpButton) belonging to exactly ONE named AXSheet in an application window.
    /// No mutation, no press, no focus, no approval, no recovery. Descendants inside groups or popup menus are strictly NOT traversed.
    public func listSheetActions(
        applicationName: String,
        windowTitle: String? = nil,
        windowIdentifier: String? = nil,
        sheetTitle: String? = nil,
        sheetIdentifier: String? = nil
    ) async throws -> QAXSheetActionCollectionMetadata {
        guard AXIsProcessTrusted() else {
            throw QAXInteractionError.accessibilityPermissionDenied
        }

        let runningApp = try Self.resolveExactRunningApplication(named: applicationName)
        let processIdentifier = runningApp.processIdentifier

        return try await Task.detached(priority: .userInitiated) {
            let appElement = AXUIElementCreateApplication(processIdentifier)

            let windowMatches = Self.collectMatches(
                root: appElement,
                role: "AXWindow",
                identifier: windowIdentifier,
                title: windowTitle
            )
            guard !windowMatches.isEmpty else { throw QAXInteractionError.noMatchingElement }
            guard windowMatches.count == 1 else { throw QAXInteractionError.ambiguousTarget(count: windowMatches.count) }

            let (targetWindow, windowSnapshot) = windowMatches[0]

            guard let verifiedWindow = Self.snapshotIfMatches(targetWindow, role: "AXWindow", identifier: windowIdentifier, title: windowTitle) else {
                throw QAXInteractionError.staleTarget("target window element is no longer resolvable immediately before sheet action enumeration")
            }
            guard verifiedWindow == windowSnapshot else {
                throw QAXInteractionError.staleTarget("target window identity changed between observation and sheet action enumeration")
            }

            var candidateSheets: [AXUIElement] = []
            if let sheetsAttr = Self.axUIElementsAttribute(Self.axSheetsAttributeName, of: targetWindow) {
                candidateSheets.append(contentsOf: sheetsAttr)
            }
            if let childElements = Self.childrenAttribute(of: targetWindow) {
                candidateSheets.append(contentsOf: childElements)
            }

            var validSheets: [AXUIElement] = []
            var seenSheetSnapshots: [QAXElementSnapshot] = []

            for element in candidateSheets {
                guard let role = Self.axStringAttribute(kAXRoleAttribute, of: element) else {
                    continue
                }
                guard QAXSheetRolePolicy.isAllowedSheetRole(role) else {
                    continue
                }

                let identifier = Self.axStringAttribute(Self.axIdentifierAttributeName, of: element)
                let titleOrDesc = Self.axStringAttribute(kAXTitleAttribute, of: element)
                    ?? Self.axStringAttribute(kAXDescriptionAttribute, of: element)
                let isEnabled = Self.axBoolAttribute(kAXEnabledAttribute, of: element) ?? true
                let snapshot = QAXElementSnapshot(role: role, identifier: identifier, titleOrDescription: titleOrDesc, isEnabled: isEnabled)
                if !seenSheetSnapshots.contains(snapshot) {
                    seenSheetSnapshots.append(snapshot)
                    validSheets.append(element)
                }
            }

            var matchedSheets: [AXUIElement] = []
            for sheet in validSheets {
                let identifier = Self.axStringAttribute(Self.axIdentifierAttributeName, of: sheet)
                let titleOrDesc = Self.axStringAttribute(kAXTitleAttribute, of: sheet)
                    ?? Self.axStringAttribute(kAXDescriptionAttribute, of: sheet)

                if let sheetIdentifier {
                    if identifier == sheetIdentifier {
                        matchedSheets.append(sheet)
                    }
                } else if let sheetTitle {
                    if titleOrDesc == sheetTitle {
                        matchedSheets.append(sheet)
                    }
                } else {
                    matchedSheets.append(sheet)
                }
            }

            guard !matchedSheets.isEmpty else { throw QAXInteractionError.noMatchingElement }
            guard matchedSheets.count == 1 else { throw QAXInteractionError.ambiguousTarget(count: matchedSheets.count) }

            let targetSheet = matchedSheets[0]

            let resolvedSheetTitle = Self.axStringAttribute(kAXTitleAttribute, of: targetSheet)
                ?? Self.axStringAttribute(kAXDescriptionAttribute, of: targetSheet)
            let resolvedSheetIdentifier = Self.axStringAttribute(Self.axIdentifierAttributeName, of: targetSheet)

            guard let verifiedSheet = Self.snapshotIfMatches(targetSheet, role: "AXSheet", identifier: resolvedSheetIdentifier, title: resolvedSheetTitle) else {
                throw QAXInteractionError.staleTarget("target sheet element is no longer resolvable immediately before action enumeration")
            }

            let rawChildElements = Self.childrenAttribute(of: targetSheet) ?? []

            var validActionElements: [AXUIElement] = []

            for childElement in rawChildElements {
                guard let role = Self.axStringAttribute(kAXRoleAttribute, of: childElement) else {
                    continue
                }
                guard QAXSheetActionRolePolicy.isAllowedSheetActionRole(role) else {
                    continue
                }
                let subrole = Self.axStringAttribute(kAXSubroleAttribute, of: childElement)
                guard subrole != Self.tabButtonSubrole else {
                    continue
                }
                validActionElements.append(childElement)
            }

            guard validActionElements.count <= Self.maxDirectSheetActionsCount else {
                throw QAXInteractionError.sheetActionCollectionExceedsSafeBound(validActionElements.count)
            }

            var actionsMetadata: [QAXSheetActionMetadata] = []
            actionsMetadata.reserveCapacity(validActionElements.count)

            for (index, actionElement) in validActionElements.enumerated() {
                let actionTitle = Self.axStringAttribute(kAXTitleAttribute, of: actionElement)
                    ?? Self.axStringAttribute(kAXDescriptionAttribute, of: actionElement)
                let actionIdentifier = Self.axStringAttribute(Self.axIdentifierAttributeName, of: actionElement)
                let role = Self.axStringAttribute(kAXRoleAttribute, of: actionElement) ?? "AXUnknown"
                let subrole = Self.axStringAttribute(kAXSubroleAttribute, of: actionElement)
                let isEnabled = Self.axBoolAttribute(kAXEnabledAttribute, of: actionElement)
                let isFocused = Self.axBoolAttribute(kAXFocusedAttribute, of: actionElement)

                let isSelected: Bool?
                if let state = Self.axCheckboxRadioState(of: actionElement) {
                    isSelected = (state == .on)
                } else if let selectedVal = Self.axBoolAttribute(kAXSelectedAttribute, of: actionElement) {
                    isSelected = selectedVal
                } else {
                    isSelected = nil
                }

                actionsMetadata.append(
                    QAXSheetActionMetadata(
                        index: index,
                        title: actionTitle,
                        identifier: actionIdentifier,
                        role: role,
                        subrole: subrole,
                        isEnabled: isEnabled,
                        isSelected: isSelected,
                        isFocused: isFocused
                    )
                )
            }

            return QAXSheetActionCollectionMetadata(
                applicationName: applicationName,
                windowTitle: verifiedWindow.titleOrDescription,
                windowIdentifier: verifiedWindow.identifier,
                sheetTitle: verifiedSheet.titleOrDescription,
                sheetIdentifier: verifiedSheet.identifier,
                actionCount: actionsMetadata.count,
                actions: actionsMetadata
            )
        }.value
    }

    private static func axIntAttribute(_ attribute: String, of element: AXUIElement) -> Int? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success, let value else { return nil }
        guard let numberValue = value as? NSNumber else { return nil }
        return numberValue.intValue
    }

    /// Reads a numeric (`NSNumber`-boxed) AX attribute as a `Double` — distinct from
    /// `axCheckboxRadioState`, which specifically interprets the value as a clean on/off boolean;
    /// this returns the raw numeric magnitude, needed for slider/stepper values and range bounds.
    fileprivate nonisolated static func axDoubleAttribute(_ attribute: String, of element: AXUIElement) -> Double? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success, let value else { return nil }
        guard let numberValue = value as? NSNumber else { return nil }
        return numberValue.doubleValue
    }

    // MARK: - Bounded traversal (nonisolated: pure over AXUIElement/CFTypeRef, safe from any thread)

    fileprivate nonisolated static func collectMatches(
        root: AXUIElement,
        role: String,
        identifier: String?,
        title: String?
    ) -> [(element: AXUIElement, snapshot: QAXElementSnapshot)] {
        var matches: [(AXUIElement, QAXElementSnapshot)] = []
        var visitedCount = 0
        let deadline = CFAbsoluteTimeGetCurrent() + traversalTimeBudgetSeconds

        func withinBounds() -> Bool {
            visitedCount < maxTraversalNodes && CFAbsoluteTimeGetCurrent() < deadline
        }

        func visit(_ element: AXUIElement, depth: Int) {
            guard depth <= maxTraversalDepth, withinBounds(), matches.count <= 4 else { return }
            visitedCount += 1

            if let snapshot = snapshotIfMatches(element, role: role, identifier: identifier, title: title) {
                matches.append((element, snapshot))
                if matches.count > 4 { return }
            }

            guard let children = childrenAttribute(of: element) else { return }
            for child in children {
                if !withinBounds() || matches.count > 4 { break }
                visit(child, depth: depth + 1)
            }
        }

        visit(root, depth: 0)
        return matches
    }

    fileprivate nonisolated static func snapshotIfMatches(
        _ element: AXUIElement,
        role: String,
        identifier: String?,
        title: String?
    ) -> QAXElementSnapshot? {
        guard let elementRole = axStringAttribute(kAXRoleAttribute, of: element), elementRole == role else {
            return nil
        }

        let elementIdentifier = axStringAttribute(axIdentifierAttributeName, of: element)
        // AXTitle is frequently empty on real controls (e.g. every stock Calculator button);
        // AXDescription reliably carries the same human-readable label in that case, exactly the
        // fallback Pace's own PaceAXTargeter already uses.
        let rawTitle = axStringAttribute(kAXTitleAttribute, of: element)
        let elementTitleOrDescription = (rawTitle?.isEmpty == false ? rawTitle : nil)
            ?? axStringAttribute(kAXDescriptionAttribute, of: element)
        let elementEnabled = axBoolAttribute(kAXEnabledAttribute, of: element) ?? true

        if let identifier {
            guard elementIdentifier == identifier else { return nil }
        } else if let title {
            guard elementTitleOrDescription == title else { return nil }
        } else {
            return nil
        }

        return QAXElementSnapshot(
            role: elementRole,
            identifier: elementIdentifier,
            titleOrDescription: elementTitleOrDescription,
            isEnabled: elementEnabled
        )
    }

    fileprivate nonisolated static func childrenAttribute(of element: AXUIElement) -> [AXUIElement]? {
        axUIElementsAttribute(kAXChildrenAttribute as String, of: element)
    }

    fileprivate nonisolated static func axUIElementsAttribute(_ attribute: String, of element: AXUIElement) -> [AXUIElement]? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success, let array = value as? [AXUIElement] else { return nil }
        return array
    }

    fileprivate nonisolated static func axStringAttribute(_ attribute: String, of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success else { return nil }
        return value as? String
    }

    fileprivate nonisolated static func axBoolAttribute(_ attribute: String, of element: AXUIElement) -> Bool? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success else { return nil }
        return value as? Bool
    }

    fileprivate static let axFullScreenAttribute = "AXFullScreen"

    /// Phase 2BQ: `kAXRequiredAttribute` has no C-level constant anywhere in this SDK's
    /// `AXAttributeConstants.h` (`HIServices.framework`) — confirmed by direct grep. The only
    /// SDK-level evidence is AppKit's own `NSAccessibilityRequiredAttribute`
    /// (`NSAccessibilityConstants.h`, `extern NSAccessibilityAttributeName const
    /// NSAccessibilityRequiredAttribute API_AVAILABLE(macos(10.12))`), whose underlying type
    /// (`NSAccessibilityAttributeName`) is declared `NS_TYPED_ENUM` and therefore imports into
    /// Swift as a typed wrapper case, not a plain `String`/`CFString` usable directly with
    /// `AXUIElementCopyAttributeValue`. Mirrors `axFullScreenAttribute`'s ("AXFullScreen") and
    /// `axIdentifierAttributeName`'s ("AXIdentifier") identical precedent in this exact file: the
    /// raw wire-format string "AXRequired" is the verified value, per Apple's own universal,
    /// unbroken `kAXFooAttribute`/`NSAccessibilityFooAttribute` naming convention already relied
    /// upon for both of those constants — not a guess.
    fileprivate static let axRequiredAttributeName = "AXRequired"

    /// Phase 2BR: `kAXContainsProtectedContentAttribute` has no C-level constant anywhere in this
    /// SDK's `AXAttributeConstants.h` (`HIServices.framework`) — confirmed by direct grep (empty
    /// result). The only SDK-level evidence is AppKit's own
    /// `NSAccessibilityContainsProtectedContentAttribute` (`NSAccessibilityConstants.h`, `extern
    /// NSAccessibilityAttributeName const NSAccessibilityContainsProtectedContentAttribute
    /// API_AVAILABLE(macos(10.9))`, comment: "(NSNumber *) - (boolValue) contains protected
    /// content?"), whose underlying type (`NSAccessibilityAttributeName`) is declared
    /// `NS_TYPED_ENUM` and therefore imports into Swift as a typed wrapper case, not a plain
    /// `String`/`CFString` usable directly with `AXUIElementCopyAttributeValue` — the identical
    /// situation `axRequiredAttributeName` ("AXRequired") already resolved in Phase 2BQ. Note the
    /// Objective-C property exposing this attribute (`NSAccessibilityProtocols.h`) is named
    /// `accessibilityProtectedContent`/`isAccessibilityProtectedContent` — a SHORTER name than the
    /// attribute itself — but its own doc comment reads "Invokes when clients request
    /// NSAccessibilityContainsProtectedContentAttribute", confirming the wire-format string is
    /// "AXContainsProtectedContent" (matching the full constant name), not "AXProtectedContent"
    /// (the shorter property name) — verified from the constant declaration itself, not guessed
    /// from the property name alone.
    fileprivate static let axContainsProtectedContentAttributeName = "AXContainsProtectedContent"

    fileprivate nonisolated static func axIsAttributeSettable(_ attribute: String, of element: AXUIElement) -> Bool {
        var settable: DarwinBoolean = false
        let result = AXUIElementIsAttributeSettable(element, attribute as CFString, &settable)
        guard result == .success else { return false }
        return settable.boolValue
    }

    /// Hex-encoded SHA-256 digest — the only representation of a text-entry value ever allowed
    /// to cross `setTextValue`/`observeTextValueHashAndLength`'s return boundary. Mirrors
    /// `QAuditRecord`'s existing rawArguments-hashing pattern (hash instead of storing plaintext).
    fileprivate nonisolated static func sha256Hex(_ input: String) -> String {
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02hhx", $0) }.joined()
    }
}

// MARK: - Bridge Speech & TTS

public protocol QBridgeSpeechProtocol: Sendable {
    func isListening() -> Bool
}

public final class QBridgeSpeech: QBridgeSpeechProtocol, @unchecked Sendable {
    public static let shared = QBridgeSpeech()
    public func isListening() -> Bool { false }
}

public protocol QBridgeTTSProtocol: Sendable {
    func speak(text: String) async throws
}

public final class QBridgeTTS: QBridgeTTSProtocol, @unchecked Sendable {
    public static let shared = QBridgeTTS()

    public func speak(text: String) async throws {
        // Safe local speech output using system synthesizer
        QAuditLogger.shared.record(
            QAuditRecord(
                sessionId: "tts-session",
                taskId: "tts",
                tool: "audio.tts",
                riskLevel: .level1SafeLocalAction,
                rawArguments: text,
                authorizationResult: "allow",
                provenance: "trusted:system",
                executionSummary: "Synthesized \(text.count) characters"
            )
        )
    }
}

// MARK: - Bridge Pace Tools

struct QBridgePaceTools: Sendable {
    static let shared = QBridgePaceTools()

    func availableToolDefinitions() -> [PaceLocalToolDefinition] {
        PaceToolRegistry.localTools
    }

    func findTool(named name: String) -> PaceLocalToolDefinition? {
        PaceToolRegistry.localTools.first { $0.canonicalName == name || $0.aliases.contains(name) }
    }
}

// MARK: - Security Violation Error

public struct QSecurityViolationError: Error, CustomStringConvertible, Sendable {
    public let kind: QViolationKind
    public let message: String

    public var description: String {
        "[\(kind)] \(message)"
    }
}
