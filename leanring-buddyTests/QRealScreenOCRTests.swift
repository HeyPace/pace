//
//  QRealScreenOCRTests.swift
//  leanring-buddyTests
//
//  Q Security Architecture — Real Screen OCR Tests (Phase 2G).
//  QBridgeVision now performs genuine on-device Vision.framework text recognition and
//  QBridgeScreenCapture performs genuine ScreenCaptureKit capture. Screen Recording TCC
//  permission cannot be assumed inside an isolated-DerivedData XCTest runner, so these tests
//  split along that boundary: Vision recognition is exercised directly and deterministically
//  against synthetic rendered images (no TCC dependency at all), while the ScreenCaptureKit
//  capture path is tested for correct fail-closed behavior under whatever the live permission
//  state actually is in this environment — never mocked, never assumed. See
//  docs/PHASE_2G_REAL_SCREEN_OCR.md for the full TCC test strategy and its documented limitation.
//

import Testing
import AppKit
import Foundation
@testable import Pace

// MARK: - Synthetic image rendering helpers (no ScreenCaptureKit / TCC dependency)

private func renderTextImage(_ lines: [String], width: Int = 700, height: Int? = nil) -> CGImage {
    let lineHeight = 40
    let resolvedHeight = height ?? max(lineHeight * lines.count + 20, lineHeight + 20)
    let size = NSSize(width: width, height: resolvedHeight)
    let image = NSImage(size: size)
    image.lockFocus()
    NSColor.white.setFill()
    NSRect(origin: .zero, size: size).fill()

    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 24),
        .foregroundColor: NSColor.black
    ]
    // Draw top-to-bottom in AppKit's bottom-left-origin coordinate space.
    for (index, line) in lines.enumerated() {
        let yFromTop = 10 + index * lineHeight
        let y = resolvedHeight - yFromTop - lineHeight
        (line as NSString).draw(at: NSPoint(x: 12, y: CGFloat(y)), withAttributes: attrs)
    }
    image.unlockFocus()

    var rect = NSRect(origin: .zero, size: size)
    guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
        fatalError("Failed to render synthetic OCR test image")
    }
    return cgImage
}

private func renderBlankImage(width: Int = 200, height: Int = 200) -> CGImage {
    let size = NSSize(width: width, height: height)
    let image = NSImage(size: size)
    image.lockFocus()
    NSColor.white.setFill()
    NSRect(origin: .zero, size: size).fill()
    image.unlockFocus()
    var rect = NSRect(origin: .zero, size: size)
    guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
        fatalError("Failed to render synthetic OCR test image")
    }
    return cgImage
}

// MARK: - Hybrid execution provider: real Vision on a synthetic image, real everything else

/// Substitutes ONLY the ScreenCaptureKit capture step (the one step that structurally requires
/// Screen Recording TCC permission this test environment cannot assume) with a synthetic,
/// locally-rendered image. Every other tool — including a real screen.ocr's Vision recognition —
/// dispatches through the REAL QExecutionService, so this is the closest deterministic
/// approximation of the full production pipeline achievable inside an automated test.
final class HybridRealVisionExecutionProvider: QExecutionProvider, @unchecked Sendable {
    let syntheticImage: CGImage
    init(syntheticImage: CGImage) { self.syntheticImage = syntheticImage }

    func executeAction(_ request: QActionRequest, context: QTaskContext) async throws -> QActionResult {
        guard request.toolName == "screen.ocr" else {
            return try await QExecutionService.shared.executeAction(request, context: context)
        }
        let frame = QScreenCaptureFrame(screenNumber: 1, width: syntheticImage.width, height: syntheticImage.height, image: syntheticImage)
        let ocr = try await QBridgeVision.shared.performOCR(on: frame)
        guard !ocr.detectedText.isEmpty else {
            return QActionResult(actionId: request.actionId, success: true, summary: "Captured screen 1 — no text was recognized.")
        }
        return QActionResult(
            actionId: request.actionId,
            success: true,
            summary: "Captured screen 1 and recognized: \(ocr.detectedText)",
            outputData: ["detectedText": ocr.detectedText, "confidence": "\(ocr.confidence)"]
        )
    }
}

@Suite("QRealScreenOCRTests")
struct QRealScreenOCRTests {

    // MARK: - A. Deterministic Vision tests (no TCC dependency)

    @Test("A1. Vision OCR recognizes known text rendered into a synthetic image")
    func syntheticImageRecognizesKnownText() async throws {
        let image = renderTextImage(["HELLO PACE TESTING"])
        let frame = QScreenCaptureFrame(screenNumber: 1, width: image.width, height: image.height, image: image)

        let result = try await QBridgeVision.shared.performOCR(on: frame)

        #expect(result.detectedText.uppercased().contains("HELLO"))
        #expect(result.elementCount > 0)
        #expect(result.confidence > 0)
    }

    @Test("A2. A blank image produces an empty, successful result — never a fabricated one")
    func blankImageProducesEmptyResult() async throws {
        let image = renderBlankImage()
        let frame = QScreenCaptureFrame(screenNumber: 1, width: image.width, height: image.height, image: image)

        let result = try await QBridgeVision.shared.performOCR(on: frame)

        #expect(result.detectedText.isEmpty)
        #expect(result.elementCount == 0)
        #expect(result.confidence == 0.0)
    }

    @Test("A3. performOCR fails closed with a deterministic error when the frame carries no image data")
    func noImageDataFailsClosed() async throws {
        let frame = QScreenCaptureFrame(screenNumber: 1, width: 100, height: 100, image: nil)

        await #expect(throws: QScreenCaptureError.self) {
            _ = try await QBridgeVision.shared.performOCR(on: frame)
        }
    }

    @Test("A4. Multiple text lines are recognized and joined in top-to-bottom reading order (partial/multi-region handling)")
    func multiLineImageRecognizesAndOrdersText() async throws {
        let image = renderTextImage(["FIRST LINE ALPHA", "SECOND LINE BRAVO", "THIRD LINE CHARLIE"])
        let frame = QScreenCaptureFrame(screenNumber: 1, width: image.width, height: image.height, image: image)

        let result = try await QBridgeVision.shared.performOCR(on: frame)
        let upper = result.detectedText.uppercased()

        #expect(upper.contains("FIRST"))
        #expect(upper.contains("SECOND"))
        #expect(upper.contains("THIRD"))
        #expect(result.elementCount >= 3)

        guard let firstRange = upper.range(of: "FIRST"),
              let secondRange = upper.range(of: "SECOND"),
              let thirdRange = upper.range(of: "THIRD") else {
            Issue.record("Expected all three lines to be recognized")
            return
        }
        #expect(firstRange.lowerBound < secondRange.lowerBound)
        #expect(secondRange.lowerBound < thirdRange.lowerBound)
    }

    // MARK: - C. Permission tests (live environment, never mocked)

    @Test("C1. QBridgeScreenCapture fails closed with a deterministic permission error when Screen Recording access is not granted, never fabricating a frame")
    func screenCaptureFailsClosedOnMissingPermission() async throws {
        guard !CGPreflightScreenCaptureAccess() else {
            // Permission is live in this environment — the success path is covered by
            // QPlanExecutionTests.testUntrustedProvenanceTaintPropagation's permission-granted
            // branch instead; nothing to assert about denial here.
            return
        }
        do {
            _ = try await QBridgeScreenCapture.shared.captureScreens()
            Issue.record("Expected captureScreens() to throw when Screen Recording permission is absent")
        } catch let error as QScreenCaptureError {
            #expect(error == .permissionDenied)
        } catch {
            Issue.record("Expected QScreenCaptureError.permissionDenied, got: \(error)")
        }
    }

    // MARK: - B/E2E. Real Vision recognition through the full real security pipeline

    @Test("B/E2E. Real Vision-recognized secret-pattern text -> untrustedScreen taint -> forced Level 2 approval -> real resolution -> execution -> verification -> goal evaluation, with no plaintext secret in durable state")
    @MainActor
    func realVisionThroughApprovalAndExecutionPipeline() async throws {
        let secret = "sk-e2erealvision0123456789012345678"
        let image = renderTextImage(["Recovered credentials:", secret], width: 900)

        let mockModel = MockAutonomousModelProvider()
        mockModel.structuredPlansToReturn = [
            """
            {
              "taskPrompt": "Read the screen then write a note to clipboard",
              "steps": [
                {
                  "actionName": "screen.ocr",
                  "toolFamily": "perception",
                  "description": "Capture and recognize on-screen text"
                },
                {
                  "actionName": "system.clipboard.write",
                  "toolFamily": "system",
                  "description": "Write a summary note",
                  "parameters": {"text": "screen read complete"}
                }
              ]
            }
            """
        ]

        let hybridExec = HybridRealVisionExecutionProvider(syntheticImage: image)
        let store = try QDurableTaskStore(inMemory: true)
        let observer = MockQPlanUIObserver()
        let runtime = QCoreRuntime(
            modelProvider: mockModel,
            memoryProvider: try QSQLiteMemoryStore(inMemory: true),
            executionProvider: hybridExec,
            durableStore: store,
            endpointName: "phase2g-e2e-\(UUID().uuidString)"
        )

        let task = try await runtime.submitIntent(prompt: "Read the screen then write a note to clipboard", observer: observer)

        // The real Vision-recognized text (containing the secret pattern) taints the context,
        // which must force the subsequent Level 2 clipboard step to require fresh approval —
        // proving real OCR content cannot bypass approval via taint the way it's designed to.
        guard case .awaitingApproval = task.state else {
            Issue.record("Expected the Level 2 clipboard step to halt for approval after the tainted OCR step, got: \(task.state)")
            return
        }

        guard let snapshot = observer.recordedSnapshots.last(where: { $0.pendingApproval != nil }) else {
            Issue.record("Expected a snapshot carrying a reconstructable pending approval")
            return
        }
        #expect(snapshot.pendingApproval?.toolName == "system.clipboard.write")
        #expect(snapshot.pendingApproval?.riskLevel == .level2UserApproval)

        // Real approval resolution — the actual production API, not a shortcut.
        let resolved = try await runtime.resolveApproval(
            taskId: task.taskId,
            approvalId: snapshot.pendingApproval!.id,
            decision: .approved
        )
        guard case .completed = resolved.state else {
            Issue.record("Expected the plan to complete after approval, got: \(resolved.state)")
            return
        }

        // Real execution happened for real (verified via the live macOS pasteboard, not a mock).
        #expect(NSPasteboard.general.string(forType: .string) == "screen read complete")

        // The OCR step's DURABLE record (persisted before the halt, via the real QPlanExecutor ->
        // QDurablePlanSnapshot path) carries no plaintext secret anywhere.
        let durableTask = try store.getTask(taskId: task.taskId)
        #expect(durableTask != nil)
        guard let planId = durableTask?.currentPlanId, let durablePlan = try store.getPlan(planId: planId) else {
            Issue.record("Expected a persisted plan snapshot for the durable task")
            return
        }
        let anyStepLeaksSecret = durablePlan.steps.contains { step in
            (step.resultSummary ?? "").contains(secret) || (step.verifiedEvidence ?? "").contains(secret)
        }
        #expect(anyStepLeaksSecret == false)

        // The real recognized text WAS captured (not silently dropped) — it just arrived redacted.
        let ocrStepSummary = durablePlan.steps.first(where: { $0.actionName == "screen.ocr" })?.resultSummary ?? ""
        #expect(ocrStepSummary.contains("[REDACTED_SECRET]"))
        #expect(ocrStepSummary.localizedCaseInsensitiveContains("credentials"))
    }
}
