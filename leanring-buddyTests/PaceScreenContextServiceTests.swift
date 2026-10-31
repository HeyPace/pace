import AppKit
import Testing
@testable import Pace

@MainActor
struct PaceScreenContextServiceTests {
    @Test func tinyPixelChangeRefreshesAXLabelsAndClickCoordinates() async throws {
        let originalCapture = try makeCapture(changedPixel: false)
        let changedCapture = try makeCapture(changedPixel: true)
        try expectChangeBelowWatchThreshold(originalCapture, changedCapture)
        let axFixture = ScreenContextAXFixture()
        axFixture.elements = [element(label: "Before", boundingBox: [4, 6, 8, 4])]
        let ocrFixture = ScreenContextOCRFixture()
        let analyzer = ScreenContextAnalysisFixture()
        let service = makeService(analyzer: analyzer, ocrFixture: ocrFixture, axFixture: axFixture)

        let originalPrompt = await service.buildUserPromptWithLocalVLMContextIfEnabled(
            transcript: "Point at the button", screenCaptures: [originalCapture]
        )
        axFixture.elements = [element(label: "After", boundingBox: [30, 20, 8, 4])]
        let changedPrompt = await service.buildUserPromptWithLocalVLMContextIfEnabled(
            transcript: "Point at the button", screenCaptures: [changedCapture]
        )

        #expect(originalPrompt.contains("button|8,8|Before"))
        #expect(changedPrompt.contains("button|34,22|After"))
        #expect(!changedPrompt.contains("Before"))
        #expect(service.cachedAnalysisIfFresh(screenLabel: changedCapture.label)?.elements.first?.bbox == [30, 20, 8, 4])
        #expect(axFixture.readCount == 2)
        #expect(analyzer.callCount == 0)
    }

    @Test func tinyPixelChangeRefreshesOCRTextAndCoordinates() async throws {
        let originalCapture = try makeCapture(changedPixel: false)
        let changedCapture = try makeCapture(changedPixel: true)
        try expectChangeBelowWatchThreshold(originalCapture, changedCapture)
        let ocrFixture = ScreenContextOCRFixture()
        await ocrFixture.setBoxes([textBox("Old value", boundingBox: [4, 6, 8, 4])])
        let service = makeService(ocrFixture: ocrFixture)
        let originalPrompt = await service.buildUserPromptWithLocalVLMContextIfEnabled(
            transcript: "Read this", screenCaptures: [originalCapture], allowsLocalVLM: false
        )
        await ocrFixture.setBoxes([textBox("New value", boundingBox: [30, 20, 8, 4])])
        let changedPrompt = await service.buildUserPromptWithLocalVLMContextIfEnabled(
            transcript: "Read this", screenCaptures: [changedCapture], allowsLocalVLM: false
        )

        #expect(originalPrompt.contains("static_text|8,8|Old value"))
        #expect(changedPrompt.contains("static_text|34,22|New value"))
        #expect(!changedPrompt.contains("Old value"))
        #expect(await ocrFixture.callCount == 2)
    }

    @Test func identicalImageReusesAnalysisWithoutAnotherAXOCRorVLMRead() async throws {
        let capture = try makeCapture()
        let axFixture = ScreenContextAXFixture()
        axFixture.elements = [element(label: "Send", boundingBox: [4, 6, 8, 4])]
        let ocrFixture = ScreenContextOCRFixture()
        let analyzer = ScreenContextAnalysisFixture()
        let service = makeService(analyzer: analyzer, ocrFixture: ocrFixture, axFixture: axFixture)
        let firstPrompt = await service.buildUserPromptWithLocalVLMContextIfEnabled(
            transcript: "Read this", screenCaptures: [capture]
        )
        let repeatedPrompt = await service.buildUserPromptWithLocalVLMContextIfEnabled(
            transcript: "Read this", screenCaptures: [capture]
        )

        #expect(repeatedPrompt == firstPrompt)
        #expect(repeatedPrompt.contains("button|8,8|Send"))
        #expect(axFixture.readCount == 1)
        #expect(await ocrFixture.callCount == 1)
        #expect(analyzer.callCount == 0)
    }

    @Test func successfulOCRSurvivesVLMFailure() async throws {
        let capture = try makeCapture()
        let ocrFixture = ScreenContextOCRFixture()
        await ocrFixture.setBoxes([textBox("Invoice total", boundingBox: [10, 12, 20, 4])])
        let analyzer = ScreenContextAnalysisFixture(shouldFail: true)
        let service = makeService(analyzer: analyzer, ocrFixture: ocrFixture)
        let prompt = await service.buildUserPromptWithLocalVLMContextIfEnabled(
            transcript: "Read this", screenCaptures: [capture]
        )

        #expect(prompt.contains("static_text|20,14|Invoice total"))
        #expect(prompt.contains("User said: Read this"))
        #expect(service.cachedAnalysisIfFresh(screenLabel: capture.label)?.elements.first?.text == "Invoice total")
        #expect(analyzer.callCount == 1)
        #expect(await ocrFixture.callCount == 1)
    }

    @Test func textOnlyCLIUsesNativeOCRWithoutInvokingVLM() async throws {
        let capture = try makeCapture()
        let ocrFixture = ScreenContextOCRFixture()
        await ocrFixture.setBoxes([textBox("Canvas label", boundingBox: [10, 12, 20, 4])])
        let analyzer = ScreenContextAnalysisFixture(shouldFail: true)
        let service = makeService(analyzer: analyzer, ocrFixture: ocrFixture)
        let prompt = await service.buildUserPromptWithLocalVLMContextIfEnabled(
            transcript: "Read this", screenCaptures: [capture],
            allowsLocalVLM: false, allowsNativeOCR: true
        )

        #expect(prompt.contains("static_text|20,14|Canvas label"))
        #expect(analyzer.callCount == 0)
        #expect(await ocrFixture.callCount == 1)
    }

    @Test func switchingImageInputCapabilityDoesNotReuseOCRFreeOrOCRBackedCache() async throws {
        let capture = try makeCapture()
        let ocrFixture = ScreenContextOCRFixture()
        await ocrFixture.setBoxes([textBox("Canvas label", boundingBox: [10, 12, 20, 4])])
        let analyzer = ScreenContextAnalysisFixture()
        let service = makeService(analyzer: analyzer, ocrFixture: ocrFixture)
        let imageCapablePrompt = await service.buildUserPromptWithLocalVLMContextIfEnabled(
            transcript: "Read this", screenCaptures: [capture],
            allowsLocalVLM: false, allowsNativeOCR: false
        )
        #expect(!imageCapablePrompt.contains("Canvas label"))
        #expect(await ocrFixture.callCount == 0)
        let textOnlyPrompt = await service.buildUserPromptWithLocalVLMContextIfEnabled(
            transcript: "Read this", screenCaptures: [capture],
            allowsLocalVLM: false, allowsNativeOCR: true
        )
        #expect(textOnlyPrompt.contains("Canvas label"))
        #expect(await ocrFixture.callCount == 1)
        let imageCapableAgainPrompt = await service.buildUserPromptWithLocalVLMContextIfEnabled(
            transcript: "Read this", screenCaptures: [capture],
            allowsLocalVLM: false, allowsNativeOCR: false
        )
        #expect(!imageCapableAgainPrompt.contains("Canvas label"))
        #expect(await ocrFixture.callCount == 1)
        #expect(analyzer.callCount == 0)
    }

    @Test func enablingLocalVLMDoesNotReuseTextOnlyCache() async throws {
        let capture = try makeCapture()
        let analyzer = ScreenContextAnalysisFixture()
        let service = makeService(analyzer: analyzer)
        _ = await service.buildUserPromptWithLocalVLMContextIfEnabled(
            transcript: "Describe this image", screenCaptures: [capture], allowsLocalVLM: false
        )
        let prompt = await service.buildUserPromptWithLocalVLMContextIfEnabled(
            transcript: "Describe this image", screenCaptures: [capture], allowsLocalVLM: true
        )

        #expect(prompt.contains("Visual scene from VLM"))
        #expect(analyzer.callCount == 1)
    }

    private func makeService(
        analyzer: ScreenContextAnalysisFixture? = nil,
        ocrFixture: ScreenContextOCRFixture? = nil,
        axFixture: ScreenContextAXFixture? = nil
    ) -> PaceScreenContextService {
        let analyzer = analyzer ?? ScreenContextAnalysisFixture()
        let ocrFixture = ocrFixture ?? ScreenContextOCRFixture()
        let axFixture = axFixture ?? ScreenContextAXFixture()
        return PaceScreenContextService(
            screenAnalysisClient: analyzer,
            visionOCRClient: PaceVisionOCRClient(recognizeTextOperation: { _, _, _ in
                await ocrFixture.recognizeText()
            }),
            axScreenReader: PaceAXScreenReader(
                readAXPointElements: { axFixture.readElements() }, primaryScreenHeight: { 36 }
            ),
            isReadMyScreenEnabled: { true }
        )
    }

    private func element(label: String, boundingBox: [Int]) -> LocalVLMScreenElement {
        LocalVLMScreenElement(label: label, role: "button", bbox: boundingBox, text: nil)
    }

    private func textBox(_ text: String, boundingBox: [Int]) -> RecognizedTextBox {
        RecognizedTextBox(text: text, pixelBoundingBox: boundingBox)
    }

    private func expectChangeBelowWatchThreshold(
        _ originalCapture: CompanionScreenCapture, _ changedCapture: CompanionScreenCapture
    ) throws {
        let originalFingerprint = try #require(PaceScreenImageDiffer.fingerprint(for: originalCapture.imageData))
        let changedFingerprint = try #require(PaceScreenImageDiffer.fingerprint(for: changedCapture.imageData))
        let diff = try #require(PaceScreenImageDiffer.diff(from: originalFingerprint, to: changedFingerprint))
        #expect(originalCapture.imageData != changedCapture.imageData)
        #expect(!diff.isMeaningful)
    }

    private func makeCapture(changedPixel: Bool = false) throws -> CompanionScreenCapture {
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 36,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        let bitmapData = try #require(bitmap.bitmapData)
        for verticalPosition in 0..<36 {
            for horizontalPosition in 0..<64 {
                let byteOffset = verticalPosition * bitmap.bytesPerRow + horizontalPosition * 4
                let pixelValue: UInt8 = changedPixel && horizontalPosition == 10 && verticalPosition == 10 ? 255 : 20
                bitmapData[byteOffset] = pixelValue
                bitmapData[byteOffset + 1] = pixelValue
                bitmapData[byteOffset + 2] = pixelValue
                bitmapData[byteOffset + 3] = 255
            }
        }
        return CompanionScreenCapture(
            imageData: try #require(bitmap.representation(using: .png, properties: [:])),
            label: "test screen", isCursorScreen: true,
            displayWidthInPoints: 64, displayHeightInPoints: 36,
            displayFrame: CGRect(x: 0, y: 0, width: 64, height: 36),
            screenshotWidthInPixels: 64, screenshotHeightInPixels: 36
        )
    }
}

@MainActor
private final class ScreenContextAXFixture {
    var elements: [LocalVLMScreenElement] = []
    private(set) var readCount = 0

    func readElements() -> [LocalVLMScreenElement] {
        readCount += 1
        return elements
    }
}

private actor ScreenContextOCRFixture {
    private var boxes: [RecognizedTextBox] = []
    private(set) var callCount = 0

    func setBoxes(_ boxes: [RecognizedTextBox]) { self.boxes = boxes }

    func recognizeText() -> [RecognizedTextBox] {
        callCount += 1
        return boxes
    }
}

@MainActor
private final class ScreenContextAnalysisFixture: PaceScreenAnalysisClient {
    nonisolated let displayName = "Synthetic screen analyzer"
    private let shouldFail: Bool
    private(set) var callCount = 0

    init(shouldFail: Bool = false) { self.shouldFail = shouldFail }

    func analyzeScreenshot(screenshotImageData: Data, userIntent: String) async throws -> LocalVLMScreenAnalysis {
        callCount += 1
        if shouldFail { throw ScreenContextFixtureError.analysisFailed }
        return LocalVLMScreenAnalysis(elements: [], description: "Visual scene from VLM")
    }
}

private enum ScreenContextFixtureError: Error {
    case analysisFailed
}
