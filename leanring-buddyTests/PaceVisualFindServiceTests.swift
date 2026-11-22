//
//  PaceVisualFindServiceTests.swift
//  leanring-buddyTests
//
//  Pure geometry / match / wording helper tests for the visual-find
//  service. No OCR, no screenshot capture, no TCC — only the nonisolated
//  helpers that back `findAndMark`.
//

import CoreGraphics
import Foundation
import Testing
@testable import Pace

struct PaceVisualFindServiceTests {

    // MARK: - Substring matching

    @Test func matchIsCaseInsensitiveSubstring() async throws {
        let recognizedBoxes = [
            RecognizedTextBox(text: "Account Balance", pixelBoundingBox: [0, 0, 100, 20]),
            RecognizedTextBox(text: "TOTAL ACCOUNT", pixelBoundingBox: [0, 30, 100, 20]),
            RecognizedTextBox(text: "Settings", pixelBoundingBox: [0, 60, 100, 20]),
        ]
        let matches = PaceVisualFindService.matchBoxes(query: "account", in: recognizedBoxes)
        #expect(matches.count == 2)
        #expect(matches.contains { $0.text == "Account Balance" })
        #expect(matches.contains { $0.text == "TOTAL ACCOUNT" })
    }

    @Test func matchFindsQueryAnywhereInBoxText() async throws {
        let recognizedBoxes = [
            RecognizedTextBox(text: "your total is $42.00", pixelBoundingBox: [0, 0, 200, 20]),
        ]
        #expect(PaceVisualFindService.matchBoxes(query: "total", in: recognizedBoxes).count == 1)
        #expect(PaceVisualFindService.matchBoxes(query: "$42", in: recognizedBoxes).count == 1)
        #expect(PaceVisualFindService.matchBoxes(query: "nope", in: recognizedBoxes).isEmpty)
    }

    @Test func emptyQueryMatchesNothing() async throws {
        let recognizedBoxes = [
            RecognizedTextBox(text: "anything", pixelBoundingBox: [0, 0, 50, 20]),
        ]
        #expect(PaceVisualFindService.matchBoxes(query: "", in: recognizedBoxes).isEmpty)
        #expect(PaceVisualFindService.matchBoxes(query: "   ", in: recognizedBoxes).isEmpty)
    }

    @Test func matchIsUnicodeNormalizationInsensitive() async throws {
        // Decomposed "é" (e + combining acute) in the OCR box vs. a
        // composed "é" in the query must still match after canonical
        // mapping.
        let decomposedE = "caf\u{0065}\u{0301}"
        let composedQuery = "caf\u{00E9}"
        let recognizedBoxes = [
            RecognizedTextBox(text: decomposedE, pixelBoundingBox: [0, 0, 50, 20]),
        ]
        #expect(PaceVisualFindService.matchBoxes(query: composedQuery, in: recognizedBoxes).count == 1)
    }

    // MARK: - Padding math

    @Test func paddingGrowsBoxOnEverySide() async throws {
        // Box well away from the origin — no clamping.
        let padded = PaceVisualFindService.paddedPixelBoundingBox([100, 200, 40, 10], paddingPixels: 4)
        #expect(padded == [96, 196, 48, 18])
    }

    @Test func paddingClampsOriginAtZeroWithoutOvergrowing() async throws {
        // Box at the very top-left: origin can't go negative, and the
        // width/height only add back the padding actually applied on the
        // clamped side, so the box stays snug against the edge.
        let padded = PaceVisualFindService.paddedPixelBoundingBox([2, 0, 40, 10], paddingPixels: 4)
        // x: 2 - 4 clamps to 0, applied-left = 2, width = 40 + 2 + 4 = 46
        // y: 0 - 4 clamps to 0, applied-top  = 0, height = 10 + 0 + 4 = 14
        #expect(padded == [0, 0, 46, 14])
    }

    @Test func paddingLeavesMalformedBoxUntouched() async throws {
        #expect(PaceVisualFindService.paddedPixelBoundingBox([1, 2, 3], paddingPixels: 4) == [1, 2, 3])
    }

    // MARK: - Label truncation

    @Test func labelTruncatesAtSixtyCharacters() async throws {
        let shortText = "Save"
        #expect(PaceVisualFindService.truncatedMatchLabel(for: shortText) == "Save")

        let longText = String(repeating: "x", count: 80)
        let truncated = PaceVisualFindService.truncatedMatchLabel(for: longText)
        #expect(truncated == String(repeating: "x", count: 60) + "…")
    }

    @Test func labelTrimsSurroundingWhitespace() async throws {
        #expect(PaceVisualFindService.truncatedMatchLabel(for: "  hello  ") == "hello")
    }

    // MARK: - Pixel box → AppKit-global rect

    @Test func pixelBoxConvertsToAppKitGlobalRect() async throws {
        // 2x retina display at the origin: 3024×1964 px → 1512×982 pts.
        let capture = CompanionScreenCapture(
            imageData: Data(),
            label: "primary",
            isCursorScreen: true,
            displayWidthInPoints: 1512,
            displayHeightInPoints: 982,
            displayFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            screenshotWidthInPixels: 3024,
            screenshotHeightInPixels: 1964
        )
        // Pixel box top-left (0,0), size 3024×1964 (full screen). Scale is
        // 0.5, so display-local top-left = (0,0), bottom-right = (1512,982).
        // AppKit y-flip: pixel top-left (0,0) → AppKit (0, 982); pixel
        // bottom-right (3024,1964) → AppKit (1512, 0). Rect origin is the
        // min of both corners → (0, 0), size 1512×982.
        let rect = PaceVisualFindService.convertPixelBoxToAppKitGlobalRect(
            [0, 0, 3024, 1964],
            on: capture
        )
        #expect(rect.origin.x == 0)
        #expect(rect.origin.y == 0)
        #expect(rect.size.width == 1512)
        #expect(rect.size.height == 982)
    }

    @Test func malformedPixelBoxConvertsToZeroRect() async throws {
        let capture = CompanionScreenCapture(
            imageData: Data(),
            label: "primary",
            isCursorScreen: true,
            displayWidthInPoints: 1512,
            displayHeightInPoints: 982,
            displayFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            screenshotWidthInPixels: 3024,
            screenshotHeightInPixels: 1964
        )
        #expect(PaceVisualFindService.convertPixelBoxToAppKitGlobalRect([1, 2], on: capture) == .zero)
    }

    // MARK: - Capture ordering

    @Test func cursorScreenIsOrderedFirst() async throws {
        let secondaryCapture = CompanionScreenCapture(
            imageData: Data(), label: "secondary", isCursorScreen: false,
            displayWidthInPoints: 1512, displayHeightInPoints: 982,
            displayFrame: CGRect(x: 1512, y: 0, width: 1512, height: 982),
            screenshotWidthInPixels: 3024, screenshotHeightInPixels: 1964
        )
        let cursorCapture = CompanionScreenCapture(
            imageData: Data(), label: "cursor", isCursorScreen: true,
            displayWidthInPoints: 1512, displayHeightInPoints: 982,
            displayFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            screenshotWidthInPixels: 3024, screenshotHeightInPixels: 1964
        )
        let ordered = PaceVisualFindService.orderCapturesCursorScreenFirst([secondaryCapture, cursorCapture])
        #expect(ordered.first?.label == "cursor")
        #expect(ordered.count == 2)
    }

    // MARK: - Render cap constant

    @Test func renderCapIsTwenty() async throws {
        #expect(PaceVisualFindService.maximumRenderedMatches == 20)
    }

    // MARK: - Spoken confirmation wording

    @Test func spokenConfirmationCoversEachCase() async throws {
        // No matches.
        #expect(
            PaceVisualFindService.spokenConfirmation(query: "account", totalMatches: 0, renderedMatches: 0)
                == "i couldn't find 'account' on your screen."
        )
        // Exactly one.
        #expect(
            PaceVisualFindService.spokenConfirmation(query: "account", totalMatches: 1, renderedMatches: 1)
                == "marked 1 match for 'account'."
        )
        // Several, all rendered.
        #expect(
            PaceVisualFindService.spokenConfirmation(query: "account", totalMatches: 3, renderedMatches: 3)
                == "marked 3 matches for 'account'."
        )
        // Capped: more matches than rendered.
        #expect(
            PaceVisualFindService.spokenConfirmation(query: "e", totalMatches: 57, renderedMatches: 20)
                == "found 57 matches for 'e' — marked the first 20."
        )
    }
}


private actor SuspendedVisualFindOCR {
    private var continuation: CheckedContinuation<[RecognizedTextBox], any Error>?
    var isWaiting: Bool { continuation != nil }

    func wait() async throws -> [RecognizedTextBox] {
        try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func finish(_ result: Result<[RecognizedTextBox], any Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }
}

@MainActor
struct PaceVisualFindOwnershipTests {
    private func capture(identifier: UInt32 = 42, origin: CGPoint = CGPoint(x: -1000, y: -200)) -> CompanionScreenCapture {
        CompanionScreenCapture(displayIdentifier: identifier, imageData: Data(), label: "target",
            isCursorScreen: true, displayWidthInPoints: 1000, displayHeightInPoints: 800,
            displayFrame: CGRect(origin: origin, size: CGSize(width: 1000, height: 800)),
            screenshotWidthInPixels: 2000, screenshotHeightInPixels: 1600)
    }

    @Test func supersededOCRCannotSetOrClearNewerAnnotations() async throws {
        for result in [
            Result<[RecognizedTextBox], any Error>.success([RecognizedTextBox(text: "target", pixelBoundingBox: [20, 40, 100, 20])]),
            .success([]), .failure(CancellationError())
        ] {
            let gate = SuspendedVisualFindOCR()
            let overlay = PaceAnnotationOverlayController()
            var ownsTurn = true
            let source = capture()
            let task = Task { @MainActor in
                try await PaceVisualFindService.findAndMark(query: "target", overlayController: overlay,
                    visionOCRClient: PaceVisionOCRClient(recognizeTextOperation: { _, _, _ in try await gate.wait() }),
                    isCurrentTurn: { ownsTurn }, captureScreens: { [source] })
            }
            while !(await gate.isWaiting) { await Task.yield() }
            ownsTurn = false
            let newer = PaceRenderedAnnotation(geometry: .rect(.zero), style: .default, screenIndex: 1)
            overlay.setAnnotations([newer])
            await gate.finish(result)
            do { _ = try await task.value; Issue.record("obsolete find must cancel") }
            catch { #expect(error is CancellationError) }
            #expect(overlay.activeAnnotations == [newer])
        }
    }

    @Test func cancelledCaptureCannotBeginOCRorChangeLayer() async throws {
        let gate = SuspendedVisualFindOCR()
        let overlay = PaceAnnotationOverlayController()
        let source = capture()
        let task = Task { @MainActor in
            try await PaceVisualFindService.findAndMark(query: "target", overlayController: overlay,
                visionOCRClient: PaceVisionOCRClient(recognizeTextOperation: { _, _, _ in
                    Issue.record("OCR must not begin after cancelled capture"); return []
                }), isCurrentTurn: { true }, captureScreens: { _ = try await gate.wait(); return [source] })
        }
        while !(await gate.isWaiting) { await Task.yield() }
        task.cancel()
        let newer = PaceRenderedAnnotation(geometry: .rect(.zero), style: .default, screenIndex: 1)
        overlay.setAnnotations([newer])
        await gate.finish(.success([]))
        do { _ = try await task.value; Issue.record("cancelled find must throw") }
        catch { #expect(error is CancellationError) }
        #expect(overlay.activeAnnotations == [newer])
    }

    @Test func sourceDisplaySurvivesCaptureOrderAndNegativeScaledOrigins() async throws {
        let overlay = PaceAnnotationOverlayController()
        let source = capture()
        _ = try await PaceVisualFindService.findAndMark(query: "target", overlayController: overlay,
            visionOCRClient: PaceVisionOCRClient(recognizeTextOperation: { _, _, _ in
                [RecognizedTextBox(text: "target", pixelBoundingBox: [20, 40, 100, 20])]
            }), isCurrentTurn: { true }, captureScreens: { [source] })
        let rendered = try #require(overlay.activeAnnotations.first)
        #expect(rendered.sourceDisplayIdentifier == 42)
        #expect(rendered.belongsToDisplay(identifier: 42, frame: source.displayFrame, legacyScreenIndex: 2))
        #expect(!rendered.belongsToDisplay(identifier: 42, frame: .zero, legacyScreenIndex: 1))
        #expect(!rendered.belongsToDisplay(identifier: 99, frame: source.displayFrame, legacyScreenIndex: 1))
        if case .rect(let rectangle) = rendered.geometry {
            #expect(rectangle.minX == -992)
            #expect(rectangle.minY == 568)
        } else { Issue.record("expected a rectangle") }
    }
    @Test func plannerCaptureNumberKeepsSourceDisplayWhenCaptureOrderDiffersFromOverlayOrder() throws {
        let target = capture(identifier: 42)
        let primary = capture(identifier: 99, origin: .zero)
        let parsed = PaceActionTagParser.parseActions(from: #"{"spokenText":"Marked","intent":"action","payload":{"name":"draw_annotation","args":{"screen":1,"shapes":[{"kind":"rect","x":20,"y":40,"width":100,"height":20}]}}}"#)
        let overlay = PaceAnnotationOverlayController()
        _ = PaceAnnotationActionDrainer.drain(parseResult: parsed, into: overlay, screenCaptures: [target, primary])
        let annotation = try #require(overlay.activeAnnotations.first)
        #expect(annotation.sourceDisplayIdentifier == 42)
        #expect(annotation.screenIndex == 1)
        #expect(annotation.belongsToDisplay(identifier: 42, frame: target.displayFrame, legacyScreenIndex: 2))
        #expect(!annotation.belongsToDisplay(identifier: 99, frame: primary.displayFrame, legacyScreenIndex: 1))
        if case .rect(let rectangle) = annotation.geometry {
            #expect(rectangle.minX == -990)
            #expect(rectangle.minY == 570)
        } else { Issue.record("expected a rectangle") }
    }

    @Test func oneDisplayOCRFailureKeepsMatchesFromAnotherDisplay() async throws {
        var broken = capture(identifier: 99, origin: .zero)
        broken = CompanionScreenCapture(displayIdentifier: broken.displayIdentifier, imageData: Data([0]), label: "broken", isCursorScreen: false,
            displayWidthInPoints: broken.displayWidthInPoints, displayHeightInPoints: broken.displayHeightInPoints, displayFrame: broken.displayFrame,
            screenshotWidthInPixels: broken.screenshotWidthInPixels, screenshotHeightInPixels: broken.screenshotHeightInPixels)
        let good = capture(identifier: 42)
        let overlay = PaceAnnotationOverlayController()
        let outcome = try await PaceVisualFindService.findAndMark(query: "target", overlayController: overlay,
            visionOCRClient: PaceVisionOCRClient(recognizeTextOperation: { data, _, _ in
                if data == Data([0]) { throw CocoaError(.fileReadCorruptFile) }
                return [RecognizedTextBox(text: "target", pixelBoundingBox: [20, 40, 100, 20])]
            }), isCurrentTurn: { true }, captureScreens: { [broken, good] })
        #expect(outcome.totalMatches == 1)
        #expect(overlay.activeAnnotations.first?.sourceDisplayIdentifier == 42)
    }

}
