//
//  PaceScreenContextScalerTests.swift
//  leanring-buddyTests
//
//  Reproduces the multi-monitor coordinate bug observed in the field
//  (element at AX point (1405, 165) → executor clicked at (1728, 445))
//  and locks in the correct math so it doesn't regress.
//
//  The bug was: AX reader scaled AX points by Retina factor (2.0),
//  producing coords against a hypothetical native-resolution
//  screenshot. But the actual screenshot is downsampled to 1280px
//  wide. Coords ≥1280 got clamped at the screen edge.
//
//  These tests use ONLY the pure scaler — no AXUIElement, no
//  NSScreen — so the math is verifiable without launching the app.
//

import Testing
import Foundation
import CoreGraphics
@testable import Pace

@MainActor
struct PaceScreenContextScalerTests {

    @Test func readerBoundaryScalesUnmodifiedAXPointsAcrossMixedDensityDisplays() throws {
        let fixtures: [(primaryHeight: CGFloat, frame: CGRect, pixels: CGSize, axFrame: CGRect, expected: [Int])] = [
            (
                982, CGRect(x: 0, y: 0, width: 1512, height: 982), CGSize(width: 3024, height: 1964),
                CGRect(x: 600, y: 200, width: 80, height: 24), [1200, 400, 160, 48]
            ),
            (
                982, CGRect(x: 0, y: 0, width: 1512, height: 982), CGSize(width: 1280, height: 831),
                CGRect(x: 600, y: 200, width: 80, height: 24), [507, 169, 67, 20]
            ),
            // A 1x display right of the 2x primary, top edges aligned.
            (
                982, CGRect(x: 1512, y: -98, width: 1920, height: 1080), CGSize(width: 1280, height: 720),
                CGRect(x: 1600, y: 200, width: 80, height: 24), [58, 133, 53, 16]
            ),
            // Inverse density: a 2x display right of a 1x primary.
            (
                1080, CGRect(x: 1920, y: 98, width: 1512, height: 982), CGSize(width: 3024, height: 1964),
                CGRect(x: 2000, y: 200, width: 80, height: 24), [160, 400, 160, 48]
            ),
            (
                982, CGRect(x: 0, y: 982, width: 1920, height: 1080), CGSize(width: 1280, height: 720),
                CGRect(x: 100, y: -880, width: 80, height: 24), [66, 133, 53, 16]
            ),
            (
                982, CGRect(x: -1920, y: -98, width: 1920, height: 1080), CGSize(width: 1280, height: 720),
                CGRect(x: -1800, y: 200, width: 80, height: 24), [80, 133, 53, 16]
            ),
        ]
        for fixture in fixtures {
            let rawElement = LocalVLMScreenElement(
                label: "Target", role: "button",
                bbox: PaceAXScreenReader.axPointBoundingBox(for: fixture.axFrame), text: nil)
            let outsideElement = LocalVLMScreenElement(
                label: "Other display", role: "button", bbox: [-9000, -9000, 80, 24], text: nil)
            let reader = PaceAXScreenReader(
                readAXPointElements: { [rawElement, outsideElement] }, primaryScreenHeight: { fixture.primaryHeight })
            let capture = CompanionScreenCapture(
                imageData: Data(), label: "Fixture", isCursorScreen: true,
                displayWidthInPoints: Int(fixture.frame.width), displayHeightInPoints: Int(fixture.frame.height),
                displayFrame: fixture.frame, screenshotWidthInPixels: Int(fixture.pixels.width),
                screenshotHeightInPixels: Int(fixture.pixels.height))
            #expect(
                reader.readFocusedWindow().first?.bbox == [
                    Int(fixture.axFrame.minX), Int(fixture.axFrame.minY), 80, 24,
                ])
            let elements = reader.readFocusedWindow(scalingToScreenshot: capture)
            #expect(elements.count == 1)
            let boundingBox = try #require(elements.first?.bbox)
            #expect(boundingBox == fixture.expected)
            let screenshotCenter = CGPoint(
                x: CGFloat(boundingBox[0]) + CGFloat(boundingBox[2]) / 2,
                y: CGFloat(boundingBox[1]) + CGFloat(boundingBox[3]) / 2)
            let globalCenter = PaceAnnotationCoordinateMapper.convertScreenshotPixelToAppKitGlobal(
                screenshotPixelPoint: screenshotCenter, on: capture)
            #expect(abs(globalCenter.x - fixture.axFrame.midX) < 2)
            #expect(abs(globalCenter.y - (fixture.primaryHeight - fixture.axFrame.midY)) < 2)
            let overlayCenter = PaceAnnotationCoordinateMapper.convertAppKitGlobalToOverlayLocal(
                globalCenter, screenFrame: fixture.frame)
            #expect(abs(overlayCenter.x - (fixture.axFrame.midX - fixture.frame.minX)) < 2)
            let axScreenOriginY = fixture.primaryHeight - fixture.frame.maxY
            #expect(abs(overlayCenter.y - (fixture.axFrame.midY - axScreenOriginY)) < 2)
        }
    }

    @Test func exactReticleCoordinatesRemainUnclampedAtDisplayEdges() {
        let frame = CGRect(x: -1920, y: 982, width: 1920, height: 1080)
        #expect(
            PaceAnnotationCoordinateMapper.convertAppKitGlobalToOverlayLocal(
                CGPoint(x: -1919, y: 2061), screenFrame: frame) == CGPoint(x: 1, y: 1))
        #expect(
            PaceAnnotationCoordinateMapper.convertAppKitGlobalToOverlayLocal(CGPoint(x: -1, y: 983), screenFrame: frame)
                == CGPoint(x: 1919, y: 1079))
    }

    // MARK: - The bug reproduction

    /// User's field log: button at AX-points (1405, 165) on a primary
    /// MacBook Pro 16" display (1728x1117 points, screenshot
    /// downsampled to 1280x827 px) → click landed at executor coord
    /// (1728, 445). With the correct scaler, the element's screenshot-
    /// pixel center should be ~ (1040, 122), and the executor's
    /// inverse should round-trip back to AX point (~1405, ~165).
    @Test func sixteenInchMacBookProDownsampledScreenshotScalesCorrectly() async throws {
        // Element bbox in AX points: 80x24 button at (1405, 165).
        let axBoundingBox = [1405, 165, 80, 24]
        let scaled = PaceScreenContextScaler.scaleAXBoundingBoxToScreenshotPixels(
            axPointBoundingBox: axBoundingBox,
            screenLocalOriginInAXPoints: CGPoint(x: 0, y: 0),
            displayWidthInPoints: 1728,
            displayHeightInPoints: 1117,
            screenshotWidthInPixels: 1280,
            screenshotHeightInPixels: 827
        )
        let unwrappedScaled = try #require(scaled)
        #expect(unwrappedScaled.count == 4)
        // Expected: 1405 * 1280/1728 ≈ 1040, 165 * 827/1117 ≈ 122
        #expect(abs(unwrappedScaled[0] - 1040) <= 1)
        #expect(abs(unwrappedScaled[1] - 122) <= 1)
        // Width: 80 * 1280/1728 ≈ 59, Height: 24 * 827/1117 ≈ 17
        #expect(abs(unwrappedScaled[2] - 59) <= 1)
        #expect(abs(unwrappedScaled[3] - 17) <= 1)
    }

    /// The previous (buggy) behavior of multiplying by Retina scale
    /// 2.0 would put this same element at (2810, 330) — past the
    /// 1280-wide screenshot's right edge. The correct scaler keeps
    /// it inside the screenshot.
    @Test func correctScalerKeepsElementInsideDownsampledScreenshot() async throws {
        let axBoundingBox = [1405, 165, 80, 24]
        let scaled = PaceScreenContextScaler.scaleAXBoundingBoxToScreenshotPixels(
            axPointBoundingBox: axBoundingBox,
            screenLocalOriginInAXPoints: CGPoint(x: 0, y: 0),
            displayWidthInPoints: 1728,
            displayHeightInPoints: 1117,
            screenshotWidthInPixels: 1280,
            screenshotHeightInPixels: 827
        )
        let unwrappedScaled = try #require(scaled)
        #expect(unwrappedScaled[0] < 1280, "scaled X should be inside the screenshot, got \(unwrappedScaled[0])")
        #expect(unwrappedScaled[1] < 827, "scaled Y should be inside the screenshot, got \(unwrappedScaled[1])")
    }

    // MARK: - Multi-monitor

    /// Element on a secondary monitor at AX-global point (3133, 165)
    /// — secondary's top-left is at (1728, 0) in the AX global plane.
    /// When we scale FOR the secondary screen we subtract its origin
    /// first, then apply that screen's points→pixels ratio.
    @Test func secondaryMonitorElementSubtractsScreenOriginBeforeScaling() async throws {
        // Element at AX-global (3133, 165) = secondary-local (1405, 165).
        let axBoundingBox = [3133, 165, 80, 24]
        let scaled = PaceScreenContextScaler.scaleAXBoundingBoxToScreenshotPixels(
            axPointBoundingBox: axBoundingBox,
            // Secondary is to the right of primary at offset (1728, 0).
            screenLocalOriginInAXPoints: CGPoint(x: 1728, y: 0),
            // Imagine secondary is a Studio Display: 1728 × 1117 logical,
            // screenshot downsampled to 1280 × 827.
            displayWidthInPoints: 1728,
            displayHeightInPoints: 1117,
            screenshotWidthInPixels: 1280,
            screenshotHeightInPixels: 827
        )
        let unwrappedScaled = try #require(scaled)
        // Expect SAME pixel position as the equivalent primary-screen
        // case — coordinates inside secondary's own screenshot space.
        #expect(abs(unwrappedScaled[0] - 1040) <= 1)
        #expect(abs(unwrappedScaled[1] - 122) <= 1)
    }

    // MARK: - axPointFallsWithinScreen

    @Test func pointOnPrimaryFallsWithinPrimary() async throws {
        #expect(PaceScreenContextScaler.axPointFallsWithinScreen(
            axPointX: 800,
            axPointY: 600,
            screenLocalOriginInAXPoints: CGPoint(x: 0, y: 0),
            displayWidthInPoints: 1728,
            displayHeightInPoints: 1117
        ))
    }

    @Test func pointOnSecondaryDoesNotFallWithinPrimary() async throws {
        // Element on secondary at AX-global (3133, 165) when primary
        // is the only screen we're filtering for: should be rejected.
        #expect(!PaceScreenContextScaler.axPointFallsWithinScreen(
            axPointX: 3133,
            axPointY: 165,
            screenLocalOriginInAXPoints: CGPoint(x: 0, y: 0),
            displayWidthInPoints: 1728,
            displayHeightInPoints: 1117
        ))
    }

    @Test func pointOnSecondaryFallsWithinSecondary() async throws {
        // Same point, this time filtering against the secondary
        // screen at origin (1728, 0).
        #expect(PaceScreenContextScaler.axPointFallsWithinScreen(
            axPointX: 3133,
            axPointY: 165,
            screenLocalOriginInAXPoints: CGPoint(x: 1728, y: 0),
            displayWidthInPoints: 1728,
            displayHeightInPoints: 1117
        ))
    }

    @Test func degenerateInputsReturnSafely() async throws {
        let wrongShape = PaceScreenContextScaler.scaleAXBoundingBoxToScreenshotPixels(
            axPointBoundingBox: [10, 20],
            screenLocalOriginInAXPoints: .zero,
            displayWidthInPoints: 1728,
            displayHeightInPoints: 1117,
            screenshotWidthInPixels: 1280,
            screenshotHeightInPixels: 827
        )
        #expect(wrongShape == nil)

        let zeroDisplay = PaceScreenContextScaler.scaleAXBoundingBoxToScreenshotPixels(
            axPointBoundingBox: [10, 20, 30, 40],
            screenLocalOriginInAXPoints: .zero,
            displayWidthInPoints: 0,
            displayHeightInPoints: 1117,
            screenshotWidthInPixels: 1280,
            screenshotHeightInPixels: 827
        )
        #expect(zeroDisplay == nil)
    }
}
