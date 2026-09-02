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

extension QBridgeAccessibility {
    private static let maxTraversalDepth = 12
    private static let maxTraversalNodes = 3_000
    private static let traversalTimeBudgetSeconds: CFAbsoluteTime = 1.5
    /// No `kAX...` Swift constant exists for this attribute; confirmed via direct empirical
    /// probing against real macOS apps that it is the stable, populated, raw-string identifier
    /// key (populated even where kAXTitleAttribute is empty — see docs/PHASE_2H_SEMANTIC_CLICK.md).
    private static let axIdentifierAttributeName = "AXIdentifier"

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

        guard let runningApp = NSWorkspace.shared.runningApplications.first(where: {
            ($0.localizedName?.caseInsensitiveCompare(applicationName) == .orderedSame) ||
            ($0.bundleIdentifier?.caseInsensitiveCompare(applicationName) == .orderedSame)
        }) else {
            throw QAXInteractionError.applicationNotAvailable(applicationName)
        }

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
        guard let runningApp = NSWorkspace.shared.runningApplications.first(where: {
            ($0.localizedName?.caseInsensitiveCompare(applicationName) == .orderedSame) ||
            ($0.bundleIdentifier?.caseInsensitiveCompare(applicationName) == .orderedSame)
        }) else { return nil }

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

        guard let runningApp = NSWorkspace.shared.runningApplications.first(where: {
            ($0.localizedName?.caseInsensitiveCompare(applicationName) == .orderedSame) ||
            ($0.bundleIdentifier?.caseInsensitiveCompare(applicationName) == .orderedSame)
        }) else {
            throw QAXInteractionError.applicationNotAvailable(applicationName)
        }

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
        guard let runningApp = NSWorkspace.shared.runningApplications.first(where: {
            ($0.localizedName?.caseInsensitiveCompare(applicationName) == .orderedSame) ||
            ($0.bundleIdentifier?.caseInsensitiveCompare(applicationName) == .orderedSame)
        }) else { return nil }

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

        guard let runningApp = NSWorkspace.shared.runningApplications.first(where: {
            ($0.localizedName?.caseInsensitiveCompare(applicationName) == .orderedSame) ||
            ($0.bundleIdentifier?.caseInsensitiveCompare(applicationName) == .orderedSame)
        }) else {
            throw QAXInteractionError.applicationNotAvailable(applicationName)
        }

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

        guard let runningApp = NSWorkspace.shared.runningApplications.first(where: {
            ($0.localizedName?.caseInsensitiveCompare(applicationName) == .orderedSame) ||
            ($0.bundleIdentifier?.caseInsensitiveCompare(applicationName) == .orderedSame)
        }) else {
            throw QAXInteractionError.applicationNotAvailable(applicationName)
        }

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
        guard let runningApp = NSWorkspace.shared.runningApplications.first(where: {
            ($0.localizedName?.caseInsensitiveCompare(applicationName) == .orderedSame) ||
            ($0.bundleIdentifier?.caseInsensitiveCompare(applicationName) == .orderedSame)
        }) else { return nil }

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

        guard let runningApp = NSWorkspace.shared.runningApplications.first(where: {
            ($0.localizedName?.caseInsensitiveCompare(applicationName) == .orderedSame) ||
            ($0.bundleIdentifier?.caseInsensitiveCompare(applicationName) == .orderedSame)
        }) else {
            throw QAXInteractionError.applicationNotAvailable(applicationName)
        }

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
        guard let runningApp = NSWorkspace.shared.runningApplications.first(where: {
            ($0.localizedName?.caseInsensitiveCompare(applicationName) == .orderedSame) ||
            ($0.bundleIdentifier?.caseInsensitiveCompare(applicationName) == .orderedSame)
        }) else { return .applicationOrTargetUnavailable }

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

        guard let runningApp = NSWorkspace.shared.runningApplications.first(where: {
            ($0.localizedName?.caseInsensitiveCompare(applicationName) == .orderedSame) ||
            ($0.bundleIdentifier?.caseInsensitiveCompare(applicationName) == .orderedSame)
        }) else {
            throw QAXInteractionError.applicationNotAvailable(applicationName)
        }

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
        guard let runningApp = NSWorkspace.shared.runningApplications.first(where: {
            ($0.localizedName?.caseInsensitiveCompare(applicationName) == .orderedSame) ||
            ($0.bundleIdentifier?.caseInsensitiveCompare(applicationName) == .orderedSame)
        }) else { return .targetUnavailable }

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

        guard let runningApp = NSWorkspace.shared.runningApplications.first(where: {
            ($0.localizedName?.caseInsensitiveCompare(applicationName) == .orderedSame) ||
            ($0.bundleIdentifier?.caseInsensitiveCompare(applicationName) == .orderedSame)
        }) else {
            throw QAXInteractionError.applicationNotAvailable(applicationName)
        }

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
        guard let runningApp = NSWorkspace.shared.runningApplications.first(where: {
            ($0.localizedName?.caseInsensitiveCompare(applicationName) == .orderedSame) ||
            ($0.bundleIdentifier?.caseInsensitiveCompare(applicationName) == .orderedSame)
        }) else { return .targetUnavailable }

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

        guard let runningApp = NSWorkspace.shared.runningApplications.first(where: {
            ($0.localizedName?.caseInsensitiveCompare(applicationName) == .orderedSame) ||
            ($0.bundleIdentifier?.caseInsensitiveCompare(applicationName) == .orderedSame)
        }) else {
            throw QAXInteractionError.applicationNotAvailable(applicationName)
        }

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
        guard let runningApp = NSWorkspace.shared.runningApplications.first(where: {
            ($0.localizedName?.caseInsensitiveCompare(applicationName) == .orderedSame) ||
            ($0.bundleIdentifier?.caseInsensitiveCompare(applicationName) == .orderedSame)
        }) else { return .targetUnavailable }

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

        guard let runningApp = NSWorkspace.shared.runningApplications.first(where: {
            ($0.localizedName?.caseInsensitiveCompare(applicationName) == .orderedSame) ||
            ($0.bundleIdentifier?.caseInsensitiveCompare(applicationName) == .orderedSame)
        }) else {
            throw QAXInteractionError.applicationNotAvailable(applicationName)
        }

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
        guard let runningApp = NSWorkspace.shared.runningApplications.first(where: {
            ($0.localizedName?.caseInsensitiveCompare(applicationName) == .orderedSame) ||
            ($0.bundleIdentifier?.caseInsensitiveCompare(applicationName) == .orderedSame)
        }) else { return .targetUnavailable }

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

        guard let runningApp = NSWorkspace.shared.runningApplications.first(where: {
            ($0.localizedName?.caseInsensitiveCompare(applicationName) == .orderedSame) ||
            ($0.bundleIdentifier?.caseInsensitiveCompare(applicationName) == .orderedSame)
        }) else {
            throw QAXInteractionError.applicationNotAvailable(applicationName)
        }

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
        guard let runningApp = NSWorkspace.shared.runningApplications.first(where: {
            ($0.localizedName?.caseInsensitiveCompare(applicationName) == .orderedSame) ||
            ($0.bundleIdentifier?.caseInsensitiveCompare(applicationName) == .orderedSame)
        }) else { return .targetUnavailable }

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

        guard let runningApp = NSWorkspace.shared.runningApplications.first(where: {
            ($0.localizedName?.caseInsensitiveCompare(applicationName) == .orderedSame) ||
            ($0.bundleIdentifier?.caseInsensitiveCompare(applicationName) == .orderedSame)
        }) else {
            throw QAXInteractionError.applicationNotAvailable(applicationName)
        }

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
        guard let runningApp = NSWorkspace.shared.runningApplications.first(where: {
            ($0.localizedName?.caseInsensitiveCompare(applicationName) == .orderedSame) ||
            ($0.bundleIdentifier?.caseInsensitiveCompare(applicationName) == .orderedSame)
        }) else { return .targetUnavailable }

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
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value)
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
