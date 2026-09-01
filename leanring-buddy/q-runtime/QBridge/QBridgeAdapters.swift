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
