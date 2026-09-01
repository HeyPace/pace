//
//  QBridgeAdaptersTests.swift
//  leanring-buddyTests
//
//  Unit tests for QBridge Adapters (Phase 1D.5)
//

import Testing
import Foundation
@testable import Pace

@Suite("QBridgeAdaptersTests")
struct QBridgeAdaptersTests {

    @Test("Bridge ScreenCapture captures frame under Level 0 authorization")
    func screenCaptureExecution() async throws {
        let capture = QBridgeScreenCapture.shared
        let frames = try await capture.captureScreens()
        #expect(!frames.isEmpty)
        #expect(frames.first?.screenNumber == 1)
    }

    @Test("Bridge Vision OCR analyzes capture frame")
    func visionOCRAnalysis() async throws {
        let vision = QBridgeVision.shared
        let dummyFrame = QScreenCaptureFrame(screenNumber: 1, width: 1920, height: 1080)
        let ocrResult = try await vision.performOCR(on: dummyFrame)
        #expect(ocrResult.confidence > 0.0)
        #expect(!ocrResult.detectedText.isEmpty)
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
