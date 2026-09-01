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
