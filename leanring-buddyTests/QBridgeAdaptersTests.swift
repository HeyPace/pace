//
//  QBridgeAdaptersTests.swift
//  leanring-buddyTests
//
//  Unit tests for QBridge Adapters (Phase 1D.5)
//

import Testing
import Foundation
import AppKit
@testable import Pace

@Suite("QBridgeAdaptersTests")
struct QBridgeAdaptersTests {

    @Test("Bridge ScreenCapture captures a frame under Level 0 authorization when Screen Recording permission is granted, else fails closed deterministically")
    func screenCaptureExecution() async throws {
        // Phase 2G: real ScreenCaptureKit capture. Screen Recording TCC permission cannot be
        // assumed inside an isolated-DerivedData XCTest runner — assert the correct deterministic
        // outcome for whichever permission state is actually live, never assume success.
        let capture = QBridgeScreenCapture.shared
        if CGPreflightScreenCaptureAccess() {
            let frames = try await capture.captureScreens()
            #expect(!frames.isEmpty)
            #expect(frames.first?.screenNumber == 1)
            #expect(frames.first?.image != nil)
        } else {
            do {
                _ = try await capture.captureScreens()
                Issue.record("Expected captureScreens() to throw when Screen Recording permission is absent")
            } catch let error as QScreenCaptureError {
                #expect(error == .permissionDenied)
            }
        }
    }

    @Test("Bridge Vision OCR recognizes real text in a synthetic image (no ScreenCaptureKit/TCC dependency)")
    func visionOCRAnalysis() async throws {
        // Phase 2G: real Vision.framework recognition. Fed a locally-rendered synthetic image
        // (not a live screen capture) so this test is fully deterministic regardless of Screen
        // Recording permission — QScreenCaptureFrame's image can come from any real CGImage.
        let size = NSSize(width: 400, height: 100)
        let nsImage = NSImage(size: size)
        nsImage.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 24), .foregroundColor: NSColor.black]
        ("BRIDGE VISION TEST" as NSString).draw(at: NSPoint(x: 10, y: 35), withAttributes: attrs)
        nsImage.unlockFocus()
        var rect = NSRect(origin: .zero, size: size)
        let cgImage = nsImage.cgImage(forProposedRect: &rect, context: nil, hints: nil)!

        let vision = QBridgeVision.shared
        let frame = QScreenCaptureFrame(screenNumber: 1, width: cgImage.width, height: cgImage.height, image: cgImage)
        let ocrResult = try await vision.performOCR(on: frame)

        #expect(ocrResult.confidence > 0.0)
        #expect(!ocrResult.detectedText.isEmpty)
        #expect(ocrResult.detectedText.uppercased().contains("BRIDGE"))
    }

    @Test("Bridge Accessibility reads UI element info")
    func accessibilityRead() async throws {
        let ax = QBridgeAccessibility.shared
        let info = try await ax.readFocusedElement()
        #expect(info != nil)
        #expect(info?.role == "AXWindow")
    }

    @Test("Bridge PaceTools exposes tool registry catalog")
    func paceToolsRegistry() {
        let bridgeTools = QBridgePaceTools.shared
        let tools = bridgeTools.availableToolDefinitions()
        #expect(tools.count >= 20)

        let finderTool = bridgeTools.findTool(named: "finder")
        #expect(finderTool != nil)
        #expect(finderTool?.canonicalName == "finder")
    }
}
