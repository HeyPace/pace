import AppKit
import Foundation
import Testing
import WebKit

@testable import Pace

@MainActor @Suite(.serialized)
struct PaceGeneratedSVGTests {
    private let drawing =
        #"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 240 320"><style>@keyframes bounce{from{transform:translateY(0px)}to{transform:translateY(180px)}}.ball{animation:bounce .7s linear infinite alternate}</style><circle class="ball" cx="120" cy="40" r="20" fill="rgb(99,197,255)"/></svg>"#

    private func source(_ svg: String) throws -> String {
        let serialized = try #require(String(data: JSONEncoder().encode(svg), encoding: .utf8))
        return "pace.presentSVG(" + serialized + ", {durationSeconds:8});"
    }

    private func program(_ source: String) -> PaceProgramDefinition {
        .init(
            schemaVersion: 2, identifier: "generated-bouncing-ball", name: "Bouncing Ball",
            description: "Draw and animate a ball", category: "custom", invocationPhrases: ["bounce the ball"],
            requiredPreferences: [], nodes: [.javascript(source: source)])
    }

    @Test func parsesCanonicalXMLWithAnimationAndLocalGradientReferences() throws {
        let svg = try #require(PaceGeneratedSVG.parse(drawing))
        #expect(svg.markup.contains("@keyframes bounce"))
        #expect(svg.markup.contains("<circle"))
        #expect(PaceGeneratedSVG.parse(svg.markup) == svg)
        #expect(
            PaceGeneratedSVG.parse(
                #"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 240 320"><defs><linearGradient id="paint"><stop offset="0" stop-color="red"/></linearGradient></defs><rect width="100" height="100" fill="url(#paint)"/></svg>"#
            ) != nil)
    }

    @Test func rejectsActiveMarkupExternalResourcesMalformedXMLAndResourceExhaustion() {
        let bodies = [
            "<script>alert(1)</script>", "<foreignObject><div/></foreignObject>",
            "<image href='https://example.com/a.png'/>",
            "<a href='https://example.com'>link</a>", "<circle onload='alert(1)'/>",
            "<circle href='file:///tmp/private'/>",
            "<circle style='fill:url(https://example.com/a)'/>", "<style>@import 'https://example.com/a';</style>",
            "<style>.shape{fill:u<![CDATA[rl(https://example.com/a)]]>}</style>",
            #"<style>.shape{fill:u\72l(https://example.com/a)}</style>"#,
            "<style>.shape{filter:blur(1000px)}</style>", "<filter><feGaussianBlur stdDeviation='99999'/></filter>",
            "<use href='#recursive'/>", "<animate attributeName='x'/>", "<g xmlns='http://www.w3.org/1999/xhtml'/>",
            "<circle xml:base='https://example.com'/>", "<circle r='Infinity'/>", "<circle r='9999999999'/>",
            "<path d='M 1e999 0'/>",
            "<svg viewBox='0 junk 0 240 320'/>", "<style>.ball{transform:scale(999999)}</style>",
            "<circle>", String(repeating: "<g>", count: 24) + String(repeating: "</g>", count: 24),
            String(repeating: "<circle/>", count: 512),
        ]
        for body in bodies {
            #expect(
                PaceGeneratedSVG.parse(
                    "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 240 320'>" + body + "</svg>") == nil,
                "Accepted unsafe SVG: \(body.prefix(100))")
        }
        #expect(PaceGeneratedSVG.parse("<!DOCTYPE svg><svg xmlns='http://www.w3.org/2000/svg'/>") == nil)
        #expect(
            PaceGeneratedSVG.parse(
                "<!DOCTYPE svg [<!ENTITY leak SYSTEM 'file:///tmp/private'>]><svg xmlns='http://www.w3.org/2000/svg'>&leak;</svg>"
            ) == nil)
        #expect(
            PaceGeneratedSVG.parse(
                "<?xml-stylesheet href='https://example.com/a'?><svg xmlns='http://www.w3.org/2000/svg'/>") == nil)
        #expect(PaceGeneratedSVG.parse("<svg/>") == nil)
        #expect(PaceGeneratedSVG.parse("<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 junk 0 240 320'/>") == nil)
        #expect(
            PaceGeneratedSVG.parse(
                "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 240 320'><text>"
                    + String(repeating: "\"", count: 7000) + "</text></svg>") == nil)
        #expect(PaceGeneratedSVG.parse(String(repeating: "a", count: 32769)) == nil)
        #expect(
            PaceGeneratedSVG.parse(
                "<svg xmlns='http://www.w3.org/2000/svg'><text>" + String(repeating: "\"", count: 10000)
                    + "</text></svg>") == nil)
        #expect(
            PaceGeneratedSVG.parse(
                "<svg xmlns='http://www.w3.org/2000/svg'><text>" + String(repeating: "&amp;", count: 7000)
                    + "</text></svg>") == nil)
    }

    @Test func typedMediaRequestRejectsMixedSourcesAndKeepsCatalogCompatibility() throws {
        let arguments: [String: PaceMCPJSONValue] = ["svg": .string(drawing), "durationSeconds": .number(8)]
        let request = try #require(PaceMediaPresentationRequest.parse(arguments: arguments))
        guard case .generatedSVG = request.source else {
            Issue.record("Expected a generated source")
            return
        }
        #expect(request.motion == nil)
        #expect(
            PaceMediaPresentationRequest.parse(
                arguments: arguments.merging(["assetID": .string("thank-you-dance")]) { _, new in new }) == nil)
        #expect(
            PaceMediaPresentationRequest.parse(
                arguments: arguments.merging(["motion": .string("bob")]) { _, new in new }) == nil)
        #expect(
            PaceMediaPresentationRequest.parse(arguments: ["svg": .string(drawing), "durationSeconds": .number(.nan)])
                == nil)
        #expect(
            PaceMediaPresentationRequest.parse(arguments: [
                "assetID": .string("thank-you-dance"), "durationSeconds": .number(4),
            ]) == .init(assetID: "thank-you-dance", durationSeconds: 4, motion: nil))
    }

    @Test func actualWorkerQueuesGeneratedSVGAndHostRejectsEntireInvalidPlan() async throws {
        let context = PaceProgramContext(weekday: 2, localHour: 10, frontmostApplicationBundleIdentifier: nil)
        let result = try await PaceJavaScriptPowerRuntime.compile(program(try source(drawing)), context: context)
        guard case .executionPlan(let plan) = result, case .presentMedia(let request) = plan.flattenedActions.first,
            case .generatedSVG(let svg) = request.source
        else {
            Issue.record("Worker lost generated SVG")
            return
        }
        #expect(svg == PaceGeneratedSVG.parse(drawing))
        #expect(request.durationSeconds == 8)
        for invalid in ["<svg/>", "<svg xmlns='http://www.w3.org/2000/svg'><script/></svg>"] {
            do {
                _ = try await PaceJavaScriptPowerRuntime.compile(
                    program("pace.speak('must not speak');" + (try source(invalid))), context: context)
                Issue.record("Invalid final SVG produced an executable partial plan")
            } catch {}
        }
    }

    @Test func failedIllustrationReplacementKeepsTheCurrentPresentationUsable() async throws {
        let controller = PaceMediaOverlayController(showsWindows: false)
        let request = PaceMediaPresentationRequest(
            svg: try #require(PaceGeneratedSVG.parse(drawing)), durationSeconds: 8)
        var closedOriginal = false
        controller.prepareGeneratedRenderer = { _, _ in }
        let original = await controller.presentGenerated(
            request, mayPresent: { true }, onDismiss: { _ in closedOriginal = true })
        #expect(!original.stopsActionPlan)
        let generation = controller.presentationGeneration
        controller.prepareGeneratedRenderer = { _, _ in throw CancellationError() }
        let replacement = await controller.presentGenerated(
            request, mayPresent: { true }, onDismiss: { _ in Issue.record("Replacement was never visible") })
        #expect(replacement.stopsActionPlan)
        #expect(controller.presentationGeneration == generation)
        #expect(controller.isVisible)
        controller.dismissPresentation(ifGenerationMatches: generation, cancelOwnedRun: true)
        #expect(closedOriginal)
    }

    @Test func cancellationAuthorizationAndReplacementDuringPreparationCannotShowLateVisuals() async throws {
        let controller = PaceMediaOverlayController(showsWindows: false)
        let request = PaceMediaPresentationRequest(
            svg: try #require(PaceGeneratedSVG.parse(drawing)), durationSeconds: 8)
        var suspended: CheckedContinuation<Void, Never>?
        controller.prepareGeneratedRenderer = { _, _ in await withCheckedContinuation { suspended = $0 } }
        var authorized = true
        var dismissed = 0
        let pending = Task {
            await controller.presentGenerated(request, mayPresent: { authorized }, onDismiss: { _ in dismissed += 1 })
        }
        for _ in 0..<100 {
            if suspended != nil { break }
            await Task.yield()
        }
        #expect(suspended != nil)
        controller.dismiss(cancelOwnedRun: true)
        authorized = false
        suspended?.resume()
        _ = await pending.value
        #expect(!controller.isVisible)
        #expect(dismissed == 0)
        controller.prepareGeneratedRenderer = { _, _ in }
        authorized = true
        _ = await controller.presentGenerated(request, mayPresent: { authorized }, onDismiss: { _ in dismissed += 1 })
        #expect(controller.isVisible)
        let generation = controller.presentationGeneration
        controller.finishPresentation(ifGenerationMatches: generation)
        #expect(!controller.isVisible)
        #expect(dismissed == 0)
        _ = await controller.presentGenerated(request, mayPresent: { authorized }, onDismiss: { _ in dismissed += 1 })
        controller.dismiss(cancelOwnedRun: true)
        #expect(!controller.isVisible)
        #expect(dismissed == 1)
    }

    @Test func managerSavesGeneratedPowerWithoutRenderingThenRunsAndStopsItsOwnVisual() async throws {
        let helpers = PacePowerManagerTests()
        let (root, manager, _, speech) = try helpers.fixture()
        defer {
            manager.cancelActiveTurnTasks()
            try? FileManager.default.removeItem(at: root)
        }
        let author = PacePowerManagerTests.Author()
        author.response = try #require(
            String(data: JSONEncoder().encode(program(try source(drawing))), encoding: .utf8))
        manager.reusableWorkAuthoringPlannerOverride = author
        var preparations = 0
        manager.mediaOverlayController.prepareGeneratedRenderer = { _, _ in preparations += 1 }
        helpers.begin("Add a power which bounces the ball on the screen.", manager: manager)
        await manager.handlePowerCommand(
            .add("which bounces the ball on the screen"),
            transcript: "Add a power which bounces the ball on the screen.")
        await manager.currentResponseTask?.value
        #expect(preparations == 0)
        #expect(!manager.mediaOverlayController.isVisible)
        #expect(
            PaceUserProgramStore(directoryURL: manager.managedPowerStore.programDirectoryURL).listValidPrograms().count
                == 1)
        helpers.begin("run power Bouncing Ball", manager: manager)
        await manager.handlePowerCommand(.run("Bouncing Ball"), transcript: "run power Bouncing Ball")
        await manager.currentResponseTask?.value
        #expect(preparations == 1)
        #expect(manager.mediaOverlayController.isVisible)
        manager.mediaOverlayController.dismiss(cancelOwnedRun: true)
        #expect(!manager.mediaOverlayController.isVisible)
        #expect(!speech.spokenTexts.contains("must not speak"))
        #expect(author.calls == 1)
    }

    @Test func invalidGeneratedSourceNeverSpeaksOrSavesEvenAfterQueuedSpeech() async throws {
        let helpers = PacePowerManagerTests()
        let (root, manager, _, speech) = try helpers.fixture()
        defer {
            manager.cancelActiveTurnTasks()
            try? FileManager.default.removeItem(at: root)
        }
        let invalid = program(
            "pace.speak('must not speak');" + (try source("<svg xmlns='http://www.w3.org/2000/svg'><script/></svg>")))
        helpers.begin("add a power Invalid Drawing", manager: manager)
        await manager.commitPowerDraft(
            .program(invalid), replacing: nil, transcript: "add a power Invalid Drawing",
            turnLease: manager.turnLeaseRegistry.currentLease)
        #expect(
            PaceUserProgramStore(directoryURL: manager.managedPowerStore.programDirectoryURL).listValidPrograms()
                .isEmpty)
        #expect(!speech.spokenTexts.contains("must not speak"))
        #expect(!manager.mediaOverlayController.isVisible)
    }

    @Test func actualWebKitPreparesWithoutScriptsOrPersistentStorageAndReleasesOnStop() async throws {
        let renderer = PaceGeneratedSVGRenderer()
        let panel = NSPanel(
            contentRect: CGRect(x: 40, y: 40, width: 240, height: 320),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        defer {
            renderer.stop()
            panel.orderOut(nil)
            panel.close()
        }
        try await renderer.prepare(try #require(PaceGeneratedSVG.parse(drawing)))
        panel.contentView = renderer.view
        panel.orderFrontRegardless()
        #expect(!renderer.configuration.defaultNavigationPreferences.allowsContentJavaScript)
        #expect(!renderer.configuration.websiteDataStore.isPersistent)
        #expect(renderer.configuration.userContentController.userScripts.isEmpty)
        #expect(renderer.page.url?.absoluteString == "about:blank")
        try await Task.sleep(for: .milliseconds(150))
        let imageData = try await renderer.page.exported(as: .image(allowTransparentBackground: true))
        let bitmap = try #require(NSBitmapImageRep(data: imageData))
        var coloredPixels = 0
        for pixelY in stride(from: 0, to: bitmap.pixelsHigh, by: 2) {
            for pixelX in stride(from: 0, to: bitmap.pixelsWide, by: 2) {
                if let color = bitmap.colorAt(x: pixelX, y: pixelY)?.usingColorSpace(.deviceRGB),
                    color.alphaComponent > 0.5, color.blueComponent > 0.7, color.redComponent < 0.6
                {
                    coloredPixels += 1
                }
            }
        }
        #expect(coloredPixels > 100, "The data-image must actually draw the requested blue circle")
        var replacementCommitted = false
        let blockedBefore = renderer.blockedNavigationCount
        let replacementURL = try #require(URL(string: "data:text/html,unexpected-replacement"))
        let rejectedLoad = Task { @MainActor in
            do {
                for try await event in renderer.page.load(replacementURL) {
                    if event == .committed || event == .finished { replacementCommitted = true }
                }
            } catch {}
        }
        for _ in 0..<100 {
            if renderer.blockedNavigationCount > blockedBefore || replacementCommitted { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        rejectedLoad.cancel()
        #expect(renderer.blockedNavigationCount > blockedBefore)
        #expect(!replacementCommitted, "Only the initial host document may navigate")
        #expect(renderer.page.url?.absoluteString == "about:blank")
        renderer.stop()
        #expect(renderer.isStopped)
        #expect(renderer.view.superview == nil)
    }
}
