//
//  PaceActionExecutorCoordinateConversion.swift
//  leanring-buddy
//
//  Extracted from PaceActionExecutor.swift (Wave 6a split): the
//  screenshot-pixel → display-global CGPoint conversion. Lives as a
//  PaceActionExecutor extension so the original call sites continue
//  to invoke `convertScreenshotPixelToDisplayGlobalPoint(...)`
//  unchanged.
//

import AppKit
import CoreGraphics
import Foundation

extension PaceActionExecutor {

    // MARK: - Coordinate conversion

    /// Maps a screenshot-pixel coordinate to a global CG point (the
    /// coordinate space CGEvent expects: top-left origin, points). The
    /// math mirrors the pointing logic in CompanionManager so what the
    /// user sees the cursor *point at* is exactly where a click would land.
    func convertScreenshotPixelToDisplayGlobalPoint(
        screenshotPixelLocation: ScreenshotPixelLocation,
        screenCaptures: [CompanionScreenCapture]
    ) -> CGPoint? {
        let targetCapture: CompanionScreenCapture? = {
            if let screenNumber = screenshotPixelLocation.screenNumber,
               screenNumber >= 1 && screenNumber <= screenCaptures.count {
                return screenCaptures[screenNumber - 1]
            }
            return screenCaptures.first(where: { $0.isCursorScreen }) ?? screenCaptures.first
        }()

        guard let capture = targetCapture else { return nil }

        let screenshotWidth = CGFloat(capture.screenshotWidthInPixels)
        let screenshotHeight = CGFloat(capture.screenshotHeightInPixels)
        let displayWidth = CGFloat(capture.displayWidthInPoints)
        let displayHeight = CGFloat(capture.displayHeightInPoints)
        let displayFrame = capture.displayFrame

        let clampedScreenshotX = max(0, min(CGFloat(screenshotPixelLocation.xInScreenshotPixels), screenshotWidth))
        let clampedScreenshotY = max(0, min(CGFloat(screenshotPixelLocation.yInScreenshotPixels), screenshotHeight))

        let displayLocalX = clampedScreenshotX * (displayWidth / screenshotWidth)
        let displayLocalY = clampedScreenshotY * (displayHeight / screenshotHeight)

        // CG global coordinates have top-left origin on the main screen.
        // CompanionScreenCapture.displayFrame is in AppKit coords (bottom-left
        // origin), so we need to convert here. The main screen's height in
        // AppKit coords minus the AppKit y of the top of the display gives
        // the CG y of the top of the display.
        guard let mainScreen = NSScreen.screens.first else { return nil }
        let mainScreenHeight = mainScreen.frame.height
        let displayCGTopY = mainScreenHeight - (displayFrame.origin.y + displayHeight)

        let globalCGPoint = CGPoint(
            x: displayLocalX + displayFrame.origin.x,
            y: displayLocalY + displayCGTopY
        )

        return globalCGPoint
    }
}
