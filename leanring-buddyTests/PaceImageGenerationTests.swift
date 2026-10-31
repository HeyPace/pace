import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import Pace

struct PaceImageGenerationTests {
    private static let request = PaceImageGenerationRequest(prompt: "A blue ceramic mug on white", title: "Blue mug")

    private static func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(
            "pace-image-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func writePNG(to url: URL) throws {
        let pixels = Data([0, 80, 220, 255, 0, 80, 220, 255, 0, 80, 220, 255, 0, 80, 220, 255])
        let provider = try #require(CGDataProvider(data: pixels as CFData))
        let image = try #require(
            CGImage(
                width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 8,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let destination = try #require(
            CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    private static func artifact(_ title: String = "Blue mug") -> PaceGeneratedImageArtifact {
        .init(
            id: UUID(), fileURL: URL(fileURLWithPath: "/owned/image.png"), width: 2, height: 2,
            request: .init(prompt: "A blue mug", title: title))
    }

    @Test func typedRequestRequiresBoundedPromptAndTitleAndBooleanEdit() throws {
        let valid: [String: PaceMCPJSONValue] = [
            "prompt": .string("A mug"), "title": .string("Mug"), "edit": .bool(true),
        ]
        #expect(PaceImageGenerationRequest.parse(arguments: valid)?.edit == true)
        #expect(PaceImageGenerationRequest.parse(arguments: ["prompt": .string("A mug")]) == nil)
        #expect(PaceImageGenerationRequest.parse(arguments: ["prompt": .string(" "), "title": .string("Mug")]) == nil)
        #expect(
            PaceImageGenerationRequest.parse(
                arguments: valid.merging(["edit": .string("true")]) { _, replacement in replacement }) == nil)
        #expect(
            PaceImageGenerationRequest.parse(
                arguments: valid.merging(["prompt": .string(String(repeating: "x", count: 8_001))]) { _, replacement in
                    replacement
                }) == nil)
    }

    @Test func standaloneRegistryImageRequestDispatchesInsteadOfBecomingSpeech() throws {
        let response =
            #"{"tool":"generate_image","prompt":"A labeled turbofan cutaway","title":"Turbofan","edit":false}"#
        let parsed = PaceActionTagParser.parseActions(from: response)
        try #require(parsed.actions.count == 1)
        guard case .generateImage(let request) = parsed.actions[0] else {
            Issue.record("Expected a native image request")
            return
        }
        #expect(request.title == "Turbofan")
        #expect(parsed.spokenText.isEmpty)
        #expect(
            PaceActionTagParser.parseActions(from: #"{"tool":"generate_image","title":"Missing prompt"}"#).actions
                .isEmpty)
        #expect(
            !PaceActionTagParser.parseActions(from: #"{"tool":"generate_image","title":"Missing prompt"}"#).spokenText
                .contains("{"))
        #expect(PaceActionTagParser.parseActions(from: #"{"tool":"open_app","app":"Music"}"#).actions.isEmpty)
        let plannerArguments = PaceLocalCLIPlannerClient.codexArguments(modelIdentifier: nil, isResearchTurn: false)
        #expect(plannerArguments.contains("image_generation"))
    }

    @Test func toolParsesSingleAndConjoinedActionsAndRejectsInvalidRequestAtomically() throws {
        let response =
            #"{"spokenText":"I'll generate it.","intent":"action","payload":{"calls":[{"name":"generate_image","args":{"prompt":"A blue mug","title":"Blue mug","edit":false}},{"name":"open_app","args":{"name":"Music"}}]}}"#
        let parsed = PaceActionTagParser.parseActions(from: response)
        try #require(parsed.actions.count == 2)
        guard case .generateImage(let request) = parsed.actions[0] else {
            Issue.record("Expected typed image request")
            return
        }
        #expect(request.title == "Blue mug")
        let invalid = PaceActionTagParser.parseActions(
            from: response.replacingOccurrences(of: #""edit":false"#, with: #""edit":"false""#))
        #expect(invalid.actions.isEmpty)
        #expect(invalid.spokenText.contains("couldn't generate"))
        let definition = try #require(PaceToolRegistry.definition(forToolName: "generate_image"))
        #expect(definition.riskLevel == .readOnly)
    }

    @Test func isolationRetainsNativeImageHostAndDisablesUnrelatedCapabilities() {
        let arguments = PaceCodexImageGenerationClient.arguments()
        #expect(arguments.contains("--ignore-user-config"))
        #expect(arguments.contains("--ignore-rules"))
        #expect(arguments.contains("project_doc_max_bytes=0"))
        #expect(arguments.contains("features.image_generation=true"))
        for feature in [
            "shell_tool", "unified_exec", "hooks", "apps", "browser_use", "browser_use_external", "computer_use",
            "multi_agent", "multi_agent_v2", "plugins", "memories", "skill_search", "code_mode", "view_image",
        ] {
            #expect(
                arguments.indices.contains {
                    arguments[$0] == "--disable" && $0 + 1 < arguments.count && arguments[$0 + 1] == feature
                })
        }
        #expect(
            arguments.indices.contains {
                arguments[$0] == "--enable" && $0 + 1 < arguments.count && arguments[$0 + 1] == "code_mode_host"
            })
        #expect(!arguments.contains("--image"))
        let prompt = PaceCodexImageGenerationClient.authoringPrompt(request: Self.request, previous: nil)
        #expect(prompt.contains("Ignore file paths"))
        #expect(prompt.contains("Create one new image"))
    }

    @Test func acceptsOnlyProcessThreadEventAndNeverProsePaths() {
        let identifier = UUID().uuidString.lowercased()
        #expect(
            PaceCodexImageGenerationClient.threadID(
                from: "{\"type\":\"thread.started\",\"thread_id\":\"\(identifier)\"}") == identifier)
        #expect(
            PaceCodexImageGenerationClient.threadID(from: #"{"type":"thread.started","thread_id":"../../outside"}"#)
                == nil)
        #expect(
            PaceCodexImageGenerationClient.threadID(
                from: #"{"type":"item.completed","item":{"type":"agent_message","text":"/tmp/image.png"}}"#) == nil)
    }

    @Test func importsThreadPNGWithoutTextResponseAndPreservesPrivateCopy() throws {
        let root = try Self.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let threadID = UUID().uuidString.lowercased()
        let thread = root.appendingPathComponent(threadID, isDirectory: true)
        try FileManager.default.createDirectory(at: thread, withIntermediateDirectories: true)
        let image = thread.appendingPathComponent("exec-result.png")
        try Self.writePNG(to: image)
        let destination = root.appendingPathComponent("owned", isDirectory: true)
        let artifact = try PaceGeneratedImageStore.importArtifact(
            threadID: threadID,
            generatedImagesDirectory: root, request: Self.request, destinationDirectory: destination)
        #expect(artifact.width == 2 && artifact.height == 2)
        #expect(artifact.fileURL.deletingLastPathComponent() == destination)
        try FileManager.default.removeItem(at: thread)
        #expect(try PaceGeneratedImageStore.validatedImageData(at: artifact.fileURL).width == 2)
        let permissions =
            try FileManager.default.attributesOfItem(atPath: artifact.fileURL.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
    }

    @Test func workingCopyDiscardRequiresTheExactOwnedArtifactAndPreservesSavedCopies() throws {
        let directory = PaceGeneratedImageStore.defaultDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let identifier = UUID()
        let workingCopy = directory.appendingPathComponent(identifier.uuidString).appendingPathExtension("png")
        defer { try? FileManager.default.removeItem(at: workingCopy) }
        try Self.writePNG(to: workingCopy)
        let savedDirectory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: savedDirectory) }
        let savedCopy = savedDirectory.appendingPathComponent("saved.png")
        try FileManager.default.copyItem(at: workingCopy, to: savedCopy)
        let savedArtifact = PaceGeneratedImageArtifact(
            id: identifier, fileURL: savedCopy, width: 2, height: 2, request: Self.request)
        PaceGeneratedImageStore.discardWorkingArtifact(savedArtifact)
        #expect(FileManager.default.fileExists(atPath: savedCopy.path))
        let mismatchedArtifact = PaceGeneratedImageArtifact(
            id: UUID(), fileURL: workingCopy, width: 2, height: 2, request: Self.request)
        PaceGeneratedImageStore.discardWorkingArtifact(mismatchedArtifact)
        #expect(FileManager.default.fileExists(atPath: workingCopy.path))
        let ownedArtifact = PaceGeneratedImageArtifact(
            id: identifier, fileURL: workingCopy, width: 2, height: 2, request: Self.request)
        PaceGeneratedImageStore.discardWorkingArtifact(ownedArtifact)
        #expect(!FileManager.default.fileExists(atPath: workingCopy.path))
        #expect(FileManager.default.fileExists(atPath: savedCopy.path))
    }

    @Test func rejectsWrongThreadSymlinksNonImageAndOversizedFiles() throws {
        let root = try Self.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let threadID = UUID().uuidString.lowercased()
        let thread = root.appendingPathComponent(threadID, isDirectory: true)
        try FileManager.default.createDirectory(at: thread, withIntermediateDirectories: true)
        let image = root.appendingPathComponent("outside.png")
        try Self.writePNG(to: image)
        let linked = thread.appendingPathComponent("exec-result.png")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: image)
        #expect(throws: (any Error).self) {
            try PaceGeneratedImageStore.importArtifact(
                threadID: threadID, generatedImagesDirectory: root, request: Self.request,
                destinationDirectory: root.appendingPathComponent("owned"))
        }
        try FileManager.default.removeItem(at: linked)
        try Data("not an image".utf8).write(to: linked)
        #expect(throws: (any Error).self) { try PaceGeneratedImageStore.validatedImageData(at: linked) }
        let file = try FileHandle(forWritingTo: linked)
        try file.truncate(atOffset: UInt64(PaceGeneratedImageStore.maximumEncodedBytes + 1))
        try file.close()
        #expect(throws: (any Error).self) { try PaceGeneratedImageStore.validatedImageData(at: linked) }
        #expect(throws: (any Error).self) {
            try PaceGeneratedImageStore.importArtifact(
                threadID: UUID().uuidString, generatedImagesDirectory: root, request: Self.request,
                destinationDirectory: root.appendingPathComponent("owned"))
        }
        #expect(throws: (any Error).self) {
            try PaceGeneratedImageStore.importArtifact(
                threadID: "../outside", generatedImagesDirectory: root, request: Self.request)
        }
    }

    @Test func rejectsSymlinkedThreadAndAmbiguousMultipleOutputs() throws {
        let root = try Self.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let threadID = UUID().uuidString
        let actual = root.appendingPathComponent("actual", isDirectory: true)
        try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: true)
        try Self.writePNG(to: actual.appendingPathComponent("one.png"))
        let thread = root.appendingPathComponent(threadID)
        try FileManager.default.createSymbolicLink(at: thread, withDestinationURL: actual)
        #expect(throws: (any Error).self) {
            try PaceGeneratedImageStore.importArtifact(
                threadID: threadID, generatedImagesDirectory: root, request: Self.request)
        }
        try FileManager.default.removeItem(at: thread)
        try FileManager.default.moveItem(at: actual, to: thread)
        try Self.writePNG(to: thread.appendingPathComponent("two.png"))
        #expect(throws: (any Error).self) {
            try PaceGeneratedImageStore.importArtifact(
                threadID: threadID, generatedImagesDirectory: root, request: Self.request)
        }
    }

    @Test func routesExplicitImagesAndEditsWithoutDroppingConjoinedActions() {
        #expect(PaceImageGenerationRequest.canUseImageOnlyFastPath("generate an image of a mug", hasActiveImage: false))
        #expect(
            !PaceImageGenerationRequest.canUseImageOnlyFastPath(
                "generate an image of a mug and open Music", hasActiveImage: false))
        #expect(PaceImageGenerationRequest.requestsImage("add labels", hasActiveImage: true))
        #expect(!PaceImageGenerationRequest.requestsImage("add labels", hasActiveImage: false))
        #expect(!PaceImageGenerationRequest.requiresScreenContext("make this image blue", hasActiveImage: true))
        #expect(PaceImageGenerationRequest.requiresScreenContext("draw this image", hasActiveImage: false))
        #expect(
            PaceImageGenerationRequest.requiresScreenContext("generate an image from this page", hasActiveImage: true))
        #expect(!PaceImageGenerationRequest.requestsImage("show a rotatable 3D airplane", hasActiveImage: false))
        #expect(!PaceImageGenerationRequest.requestsImage("Explain how to create an image", hasActiveImage: false))
        #expect(!PaceImageGenerationRequest.requestsImage("Do not generate an image", hasActiveImage: true))
        #expect(
            !PaceImageGenerationRequest.requestsImage(
                "Can you explain how to generate an image?", hasActiveImage: false))
        #expect(
            PaceImageGenerationRequest.requestsImage(
                "Could you please draw an illustration of a mug?", hasActiveImage: false))
    }

    @Test func ambiguousImageMentionsRemainGeneralPlannerRequests() {
        for transcript in [
            "draw a diagram of how a camera captures a photo",
            "create a flowchart of image processing",
            "create a reminder to buy a picture frame",
            "make this image my desktop wallpaper",
            "draw a circle around the image", "make it louder", "change it to dark mode",
        ] {
            #expect(!PaceImageGenerationRequest.requestsImage(transcript, hasActiveImage: false), "\(transcript)")
            #expect(!PaceImageGenerationRequest.requestsImage(transcript, hasActiveImage: true), "\(transcript)")
        }
        #expect(PaceImageGenerationRequest.requestsImage("make it blue", hasActiveImage: true))
        #expect(
            PaceImageGenerationRequest.requestsImage(
                "create a detailed illustration of a camera", hasActiveImage: false))
    }

    @Test @MainActor func localModelWarmupUsesTheActualFactoryFallbackWithoutLoadingModels() {
        let dispatch = BuddyPlannerClientFactory.cliDirectDispatchDecision(
            hasAcceptedDirectSpawnConsent: false, canRunDirectSpawnTurn: false)
        #expect(dispatch == .fallBackToLocal(reason: "direct-spawn consent not accepted"))
        let localFallback = LocalPlannerClient(
            baseURL: URL(string: "http://127.0.0.1:1234/v1")!, modelIdentifier: "fixture")
        let directCLI = PaceLocalCLIPlannerClient(upstream: .codex, modelIdentifier: nil)
        #expect(BuddyPlannerClientFactory.requiresLMStudioPlannerWarmup(for: localFallback))
        #expect(!BuddyPlannerClientFactory.requiresLMStudioPlannerWarmup(for: directCLI))
        #expect(
            PaceLMStudioModelLoader.shouldKeepVLMWarm(
                effectivePlannerAllowsLocalVLM: true, screenContextEnabled: true, usesMLX: false))
        #expect(
            !PaceLMStudioModelLoader.shouldKeepVLMWarm(
                effectivePlannerAllowsLocalVLM: false, screenContextEnabled: true, usesMLX: false))
        #expect(
            !PaceLMStudioModelLoader.shouldKeepVLMWarm(
                effectivePlannerAllowsLocalVLM: true, screenContextEnabled: true, usesMLX: true))
        #expect(
            !PaceLMStudioModelLoader.shouldKeepVLMWarm(
                effectivePlannerAllowsLocalVLM: true, screenContextEnabled: false, usesMLX: false))
    }

    @Test @MainActor func replacedAndStoppedWarmupsCannotLoadOrStartLateKeepalive() async {
        defer { PaceLMStudioModelLoader.stopKeepaliveLoop() }
        var firstResume: CheckedContinuation<Void, Never>?
        var firstGeneration: Int?
        var firstWasCancelled = false
        var events: [String] = []
        let firstTask = PaceLMStudioModelLoader.startOwnedWarmup(
            operation: { generation in
                firstGeneration = generation
                await withCheckedContinuation { firstResume = $0 }
                firstWasCancelled = Task.isCancelled
                if PaceLMStudioModelLoader.warmupIsCurrent(generation) { events.append("stale load") }
            }, completion: { events.append("stale keepalive") })
        while firstResume == nil { await Task.yield() }
        let currentTask = PaceLMStudioModelLoader.startOwnedWarmup(
            operation: { generation in
                if PaceLMStudioModelLoader.warmupIsCurrent(generation) { events.append("current load") }
            }, completion: { events.append("current keepalive") })
        await currentTask.value
        #expect(firstGeneration.map { !PaceLMStudioModelLoader.warmupIsCurrent($0) } == true)
        firstResume?.resume()
        await firstTask.value
        #expect(firstWasCancelled)
        #expect(events == ["current load", "current keepalive"])

        var stoppedResume: CheckedContinuation<Void, Never>?
        let stoppedTask = PaceLMStudioModelLoader.startOwnedWarmup(
            operation: { generation in
                await withCheckedContinuation { stoppedResume = $0 }
                if PaceLMStudioModelLoader.warmupIsCurrent(generation) { events.append("stopped load") }
            }, completion: { events.append("stopped keepalive") })
        while stoppedResume == nil { await Task.yield() }
        PaceLMStudioModelLoader.stopKeepaliveLoop()
        stoppedResume?.resume()
        await stoppedTask.value
        #expect(events == ["current load", "current keepalive"])
    }

    @Test func commonImageCreationAndSpecificEditsStayInsideTheirDirectObjectBoundary() {
        for transcript in [
            "draw me a picture of a cat", "can you make me an image of a fox",
            "create a cute image of a dog", "make a cat picture", "paint us a watercolor illustration of the sea",
            "create a profile picture", "draw us a profile picture",
        ] {
            #expect(
                PaceImageGenerationRequest.canUseImageOnlyFastPath(transcript, hasActiveImage: false), "\(transcript)")
        }
        for transcript in [
            "change it to blue", "make it more colorful", "change the image", "add labels to the image",
            "add text on it", "remove the background from the image", "change the image background to blue",
        ] {
            #expect(PaceImageGenerationRequest.requestsImage(transcript, hasActiveImage: true), "\(transcript)")
            #expect(!PaceImageGenerationRequest.requestsImage(transcript, hasActiveImage: false), "\(transcript)")
        }
        for transcript in [
            "pace, add text to my reminder", "add labels to my calendar", "add text to my note",
            "draw me a diagram of a photo", "create a reminder to buy a picture frame",
            "draw a circle around the image", "make this image my desktop wallpaper", "change it to dark mode",
            "make it louder", "make this my profile picture", "make it my lock screen photo",
            "make this image my background", "make the image my lock screen",
        ] {
            #expect(!PaceImageGenerationRequest.requestsImage(transcript, hasActiveImage: true), "\(transcript)")
            #expect(!PaceImageGenerationRequest.requestsImage(transcript, hasActiveImage: false), "\(transcript)")
        }
        #expect(
            !PaceImageGenerationRequest.canUseImageOnlyFastPath(
                "draw me a picture of a cat and open Music", hasActiveImage: false))
    }

    @Test func activeImageWallpaperAndDesktopOperationsRemainWithGeneralPlanner() {
        for transcript in [
            "make the image my new wallpaper", "make this image my mac wallpaper",
            "make this image my new desktop background", "make this image wallpaper",
            "change the image on my desktop",
        ] {
            #expect(!PaceImageGenerationRequest.requestsImage(transcript, hasActiveImage: true), "\(transcript)")
            #expect(
                !PaceImageGenerationRequest.canUseImageOnlyFastPath(transcript, hasActiveImage: true), "\(transcript)")
        }
        #expect(PaceImageGenerationRequest.requestsImage("remove the background from the image", hasActiveImage: true))
        #expect(PaceImageGenerationRequest.requestsImage("change the image background to blue", hasActiveImage: true))
    }

    @Test func possessiveAndSetAsImagePrefixesRemainWithGeneralPlanner() {
        for transcript in [
            "make the image my new background", "make this image my new profile picture",
            "make the image my brand new bright playful summer profile picture",
            "make it your next profile picture", "update this image our carefully chosen new profile picture",
            "make the image as my new avatar", "make the image for a bright new background",
            "make the image into a new background", "make the image to be a new profile picture",
            "make the image be my preferred background", "change it to my favorite new profile picture",
            "make the image the background", "make the image a background", "make this image a new profile picture",
            "make the image as a painting", "make this image to an illustration",
        ] {
            #expect(!PaceImageGenerationRequest.requestsImage(transcript, hasActiveImage: true), "\(transcript)")
            #expect(
                !PaceImageGenerationRequest.canUseImageOnlyFastPath(transcript, hasActiveImage: true), "\(transcript)")
        }
        for transcript in [
            "change it to blue", "make this image blue", "make it more colorful",
            "change the image background to blue", "remove the background from the image",
        ] {
            #expect(
                PaceImageGenerationRequest.canUseImageOnlyFastPath(transcript, hasActiveImage: true), "\(transcript)")
        }
    }

    @Test @MainActor func pendingSaveSnapshotSurvivesWorkingCopyDismissal() async throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let workingCopy = directory.appendingPathComponent("working.png")
        try Self.writePNG(to: workingCopy)
        let originalData = try Data(contentsOf: workingCopy)
        let artifact = PaceGeneratedImageArtifact(
            id: UUID(), fileURL: workingCopy, width: 2, height: 2, request: Self.request)
        let controller = PaceImageOverlayController(
            showsWindows: false,
            discardArtifact: { artifact in
                try? FileManager.default.removeItem(at: artifact.fileURL)
            }, generateImage: { _, _ in artifact })
        controller.authorizationCheck = { true }
        _ = await controller.generate(Self.request, expectedDismissalGeneration: 0)
        let snapshot = try PaceGeneratedImageSaveSnapshot(artifact: artifact)
        controller.dismiss()
        #expect(!FileManager.default.fileExists(atPath: workingCopy.path))
        let selectedDestination = directory.appendingPathComponent("saved.png")
        try snapshot.write(to: selectedDestination)
        #expect(try Data(contentsOf: selectedDestination) == originalData)
        #expect(try PaceGeneratedImageStore.validatedImageData(at: selectedDestination).width == 2)
    }

    @Test @MainActor func lateParentCancellationRestoresIdleAndDiscardsOnlyLateArtifact() async {
        var continuation: CheckedContinuation<PaceGeneratedImageArtifact, Never>?
        var discarded: [UUID] = []
        let artifact = Self.artifact()
        let controller = PaceImageOverlayController(
            showsWindows: false, discardArtifact: { discarded.append($0.id) },
            generateImage: {
                _, _ in
                await withCheckedContinuation { continuation = $0 }
            })
        controller.authorizationCheck = { true }
        let task = Task { await controller.generate(Self.request, expectedDismissalGeneration: 0) }
        while continuation == nil { await Task.yield() }
        task.cancel()
        continuation?.resume(returning: artifact)
        #expect(await task.value == "Image generation was cancelled.")
        #expect(controller.state == .idle)
        #expect(controller.lastSuccessfulArtifact == nil)
        #expect(discarded == [artifact.id])
    }

    @Test @MainActor func orderedDiagramReplacementPreservesPlanLeaseButManualCloseRevokesIt() async {
        var discarded: [UUID] = []
        let first = Self.artifact()
        let second = Self.artifact()
        var calls = 0
        let controller = PaceImageOverlayController(
            showsWindows: false, discardArtifact: { discarded.append($0.id) },
            generateImage: {
                _, _ in
                calls += 1
                return calls == 1 ? first : second
            })
        controller.authorizationCheck = { true }
        let lease = controller.dismissalGeneration
        _ = await controller.generate(Self.request, expectedDismissalGeneration: lease)
        controller.hideForDiagramReplacement()
        #expect(controller.dismissalGeneration == lease)
        #expect(discarded == [first.id])
        #expect(
            await controller.generate(Self.request, expectedDismissalGeneration: lease).contains("Your image is ready:")
        )
        controller.dismiss()
        #expect(discarded == [first.id, second.id])
        #expect(
            await controller.generate(Self.request, expectedDismissalGeneration: lease) == "I kept the image closed.")
        #expect(calls == 2)
    }

    @Test @MainActor func consentRevokedAtProviderReturnClosesPriorImageAndDiscardsLateCopy() async {
        var authorized = true
        var discarded: [UUID] = []
        let first = Self.artifact()
        let late = Self.artifact()
        var calls = 0
        let controller = PaceImageOverlayController(
            showsWindows: false, discardArtifact: { discarded.append($0.id) },
            generateImage: {
                _, _ in
                calls += 1
                if calls == 1 { return first }
                authorized = false
                return late
            })
        controller.authorizationCheck = { authorized }
        _ = await controller.generate(Self.request, expectedDismissalGeneration: 0)
        #expect(
            await controller.generate(Self.request, expectedDismissalGeneration: 0) == "Image generation was cancelled."
        )
        #expect(controller.state == .idle)
        #expect(controller.lastSuccessfulArtifact == nil)
        #expect(Set(discarded) == [first.id, late.id])
    }

    @Test @MainActor func savingAtTheWorkingURLProtectsThatExplicitUserDestination() async {
        var discarded: [UUID] = []
        let artifact = Self.artifact()
        let controller = PaceImageOverlayController(
            showsWindows: false, discardArtifact: { discarded.append($0.id) },
            generateImage: {
                _, _ in artifact
            })
        controller.authorizationCheck = { true }
        _ = await controller.generate(Self.request, expectedDismissalGeneration: 0)
        controller.preserveExplicitlySavedArtifact(artifact, at: artifact.fileURL)
        controller.dismiss()
        #expect(discarded.isEmpty)
        #expect(controller.lastSuccessfulArtifact == nil)
    }

    @Test @MainActor func successfulReplacementDiscardsPriorCopyAndFailedEditKeepsCurrentCopy() async {
        var discarded: [UUID] = []
        let first = Self.artifact()
        let second = Self.artifact()
        var calls = 0
        let controller = PaceImageOverlayController(
            showsWindows: false, discardArtifact: { discarded.append($0.id) },
            generateImage: {
                request, _ in
                calls += 1
                if request.edit { throw PaceImageGenerationError.missingArtifact }
                return calls == 1 ? first : second
            })
        controller.authorizationCheck = { true }
        _ = await controller.generate(Self.request, expectedDismissalGeneration: 0)
        _ = await controller.generate(Self.request, expectedDismissalGeneration: 0)
        #expect(discarded == [first.id])
        _ = await controller.generate(
            .init(prompt: "Add labels", title: "Labels", edit: true), expectedDismissalGeneration: 0)
        #expect(discarded == [first.id])
        #expect(controller.lastSuccessfulArtifact == second)
    }

    @Test @MainActor func successEditAndFailurePreserveOnlyActiveImageContext() async throws {
        var receivedPrevious: [PaceGeneratedImageArtifact?] = []
        let artifact = Self.artifact()
        let controller = PaceImageOverlayController(showsWindows: false) { request, previous in
            receivedPrevious.append(previous)
            if request.edit { throw PaceImageGenerationError.missingArtifact }
            return artifact
        }
        controller.authorizationCheck = { true }
        let message = await controller.generate(Self.request, expectedDismissalGeneration: 0)
        #expect(message.contains("ready"))
        #expect(controller.lastSuccessfulArtifact == artifact)
        let context = controller.appendingPlannerContext(to: "add labels")
        #expect(context.contains("active_pace_image"))
        #expect(!context.contains(artifact.fileURL.path))
        let failure = await controller.generate(
            .init(prompt: "Add labels", title: "Labeled mug", edit: true), expectedDismissalGeneration: 0)
        #expect(failure.contains("couldn't generate"))
        #expect(receivedPrevious.count == 2 && receivedPrevious[1] == artifact)
        #expect(controller.lastSuccessfulArtifact == artifact)
        controller.dismiss()
        #expect(controller.appendingPlannerContext(to: "hello") == "hello")
        #expect(controller.lastSuccessfulArtifact == nil)
        let stale = await controller.generate(Self.request, expectedDismissalGeneration: 0)
        #expect(stale.contains("closed"))
        #expect(receivedPrevious.count == 2)
    }

    @Test @MainActor func closeCancelsProcessWorkAndLateResultCannotReopen() async throws {
        var continuation: CheckedContinuation<PaceGeneratedImageArtifact, Never>?
        let controller = PaceImageOverlayController(showsWindows: false) { _, _ in
            await withCheckedContinuation { continuation = $0 }
        }
        controller.authorizationCheck = { true }
        let task = Task { await controller.generate(Self.request, expectedDismissalGeneration: 0) }
        while continuation == nil { await Task.yield() }
        controller.dismiss()
        continuation?.resume(returning: Self.artifact())
        let message = await task.value
        #expect(message.contains("cancelled"))
        #expect(controller.state == .idle)
        #expect(controller.lastSuccessfulArtifact == nil)
    }

    @Test @MainActor func deniedConsentAndMissingEditReferenceNeverLaunchGenerator() async {
        var calls = 0
        let controller = PaceImageOverlayController(showsWindows: false) { _, _ in
            calls += 1
            return Self.artifact()
        }
        let denied = await controller.generate(Self.request, expectedDismissalGeneration: 0)
        #expect(denied.contains("Select Codex"))
        controller.authorizationCheck = { true }
        let missing = await controller.generate(
            .init(prompt: "Add labels", title: "Mug", edit: true), expectedDismissalGeneration: 0)
        #expect(missing.contains("Open a Pace-generated"))
        #expect(calls == 0)
    }

    @Test @MainActor func drainAwaitsRealResultAndKeepsOtherActions() async throws {
        let controller = PaceImageOverlayController(showsWindows: false) { _, _ in Self.artifact() }
        controller.authorizationCheck = { true }
        let actions: [PaceParsedAction] = [.generateImage(Self.request), .openApplication("Music")]
        let parsed = PaceActionTagParseResult(
            spokenText: "Opening Music.", actions: actions, executionPlan: .serial(actions: actions),
            firstClickVisualisationLocation: nil)
        var diagramDismissalGeneration = 0
        let drained = await PaceVisualActionDrainer.drain(
            parseResult: parsed, diagramOverlayController: PaceDiagramOverlayController(showsWindows: false),
            imageOverlayController: controller, expectedDiagramDismissalGeneration: &diagramDismissalGeneration,
            expectedImageDismissalGeneration: 0)
        #expect(drained.actions.count == 1 && drained.executionPlan.steps.count == 1)
        #expect(drained.spokenText.contains("Opening Music") && drained.spokenText.contains("image is ready"))
        guard case .openApplication("Music") = drained.actions[0] else {
            Issue.record("Lost conjoined action")
            return
        }
    }

    private static func diagram(_ title: String) -> PaceDiagramDocument {
        .init(
            title: title, summary: "Water changes state.",
            nodes: [
                .init(
                    id: "water", label: "Water", detail: "Heat turns water into vapor.", x: 60, y: 220,
                    width: 230, height: 140, shape: .rectangle, role: .process, subtitle: "Liquid becomes vapor")
            ], connections: [])
    }

    @MainActor private static func wireVisualReplacement(
        diagramOverlayController: PaceDiagramOverlayController,
        imageOverlayController: PaceImageOverlayController
    ) {
        diagramOverlayController.onDidPresent = { [weak imageOverlayController] in
            imageOverlayController?.hideForDiagramReplacement()
        }
        imageOverlayController.onWillGenerate = { [weak diagramOverlayController] in
            diagramOverlayController?.hideForImageReplacement()
        }
        imageOverlayController.authorizationCheck = { true }
    }

    @Test(arguments: [true, false])
    @MainActor func orderedVisualActionsFinishOnLastRequestedSurface(imageFirst: Bool) async {
        let diagramOverlayController = PaceDiagramOverlayController(showsWindows: false)
        let artifact = Self.artifact()
        var discarded: [UUID] = []
        let imageOverlayController = PaceImageOverlayController(
            showsWindows: false, discardArtifact: { discarded.append($0.id) }, generateImage: { _, _ in artifact })
        Self.wireVisualReplacement(
            diagramOverlayController: diagramOverlayController, imageOverlayController: imageOverlayController)
        let diagram = Self.diagram("Water cycle")
        let actions: [PaceParsedAction] = imageFirst
            ? [.generateImage(Self.request), .showDiagram(diagram)]
            : [.showDiagram(diagram), .generateImage(Self.request)]
        let parsed = PaceActionTagParseResult(
            spokenText: "Heat turns water into vapor.", actions: actions, executionPlan: .serial(actions: actions),
            firstClickVisualisationLocation: nil)
        var diagramDismissalGeneration = diagramOverlayController.dismissalGeneration
        let imageDismissalGeneration = imageOverlayController.dismissalGeneration
        let drained = await PaceVisualActionDrainer.drain(
            parseResult: parsed, diagramOverlayController: diagramOverlayController,
            imageOverlayController: imageOverlayController,
            expectedDiagramDismissalGeneration: &diagramDismissalGeneration,
            expectedImageDismissalGeneration: imageDismissalGeneration)
        #expect(drained.actions.isEmpty && drained.executionPlan.steps.isEmpty)
        #expect(drained.spokenText.contains("Your image is ready:"))
        #expect(drained.spokenText.contains("Heat turns water into vapor."))
        #expect(diagramOverlayController.document?.title == (imageFirst ? "Water cycle" : nil))
        #expect(imageOverlayController.lastSuccessfulArtifact?.id == (imageFirst ? nil : artifact.id))
        #expect(imageOverlayController.state == (imageFirst ? .idle : .ready(artifact)))
        #expect(discarded == (imageFirst ? [artifact.id] : []))
        #expect(diagramOverlayController.dismissalGeneration == 0)
        #expect(imageOverlayController.dismissalGeneration == imageDismissalGeneration)
    }

    @Test @MainActor func orderedVisualReplacementsAndOwnedDismissalsKeepLaterActionsAuthorized() async {
        let diagramOverlayController = PaceDiagramOverlayController(showsWindows: false)
        var generatedTitles: [String] = []
        var discardedTitles: [String] = []
        let imageOverlayController = PaceImageOverlayController(
            showsWindows: false, discardArtifact: { discardedTitles.append($0.request.title) },
            generateImage: { request, _ in
                generatedTitles.append(request.title)
                return Self.artifact(request.title)
            })
        Self.wireVisualReplacement(
            diagramOverlayController: diagramOverlayController, imageOverlayController: imageOverlayController)
        let actions: [PaceParsedAction] = [
            .showDiagram(Self.diagram("First")), .generateImage(Self.request), .dismissDiagram,
            .showDiagram(Self.diagram("Second")),
            .generateImage(.init(prompt: "A red mug", title: "Red mug")),
            .showDiagram(Self.diagram("Last")),
        ]
        let parsed = PaceActionTagParseResult(
            spokenText: "Updated.", actions: actions, executionPlan: .serial(actions: actions),
            firstClickVisualisationLocation: nil)
        var diagramDismissalGeneration = 0
        let drained = await PaceVisualActionDrainer.drain(
            parseResult: parsed, diagramOverlayController: diagramOverlayController,
            imageOverlayController: imageOverlayController,
            expectedDiagramDismissalGeneration: &diagramDismissalGeneration, expectedImageDismissalGeneration: 0)
        #expect(diagramOverlayController.document?.title == "Last")
        #expect(imageOverlayController.state == .idle)
        #expect(generatedTitles == ["Blue mug", "Red mug"])
        #expect(discardedTitles == generatedTitles)
        #expect(diagramDismissalGeneration == 1)
        #expect(diagramOverlayController.dismissalGeneration == 1)
        #expect(drained.actions.isEmpty)
        #expect(drained.spokenText == "Updated. Your image is ready: Blue mug. Your image is ready: Red mug.")
    }

    @Test @MainActor func visualDrainRetainsUnrelatedActionValuesAndParallelStepGrouping() async throws {
        let diagramOverlayController = PaceDiagramOverlayController(showsWindows: false)
        let imageOverlayController = PaceImageOverlayController(
            showsWindows: false, discardArtifact: { _ in }, generateImage: { _, _ in Self.artifact() })
        Self.wireVisualReplacement(
            diagramOverlayController: diagramOverlayController, imageOverlayController: imageOverlayController)
        let steps: [PaceActionExecutionStep] = [
            .init(actions: [.type("First input"), .generateImage(Self.request), .openApplication("Music")]),
            .init(actions: [.showDiagram(Self.diagram("Water cycle"))]),
            .init(actions: [.openApplication("Notes"), .type("Last input")]),
        ]
        let parsed = PaceActionTagParseResult(
            spokenText: "Opening your apps.", actions: steps.flatMap(\.actions), executionPlan: .init(steps: steps),
            firstClickVisualisationLocation: nil)
        var diagramDismissalGeneration = 0
        let drained = await PaceVisualActionDrainer.drain(
            parseResult: parsed, diagramOverlayController: diagramOverlayController,
            imageOverlayController: imageOverlayController,
            expectedDiagramDismissalGeneration: &diagramDismissalGeneration, expectedImageDismissalGeneration: 0)
        #expect(drained.spokenText == "Opening your apps. Your image is ready: Blue mug.")
        #expect(drained.actions.map(\.auditOperationName) == ["type", "open_app", "open_app", "type"])
        try #require(drained.executionPlan.steps.count == 2)
        let firstStep = drained.executionPlan.steps[0].actions
        let lastStep = drained.executionPlan.steps[1].actions
        try #require(firstStep.count == 2 && lastStep.count == 2)
        guard case .type("First input") = firstStep[0], case .openApplication("Music") = firstStep[1],
            case .openApplication("Notes") = lastStep[0], case .type("Last input") = lastStep[1]
        else {
            Issue.record("Visual draining changed unrelated actions or their groups")
            return
        }
        #expect(!PaceActionApprovalPolicy.permitsObservationOnly(drained.executionPlan))
    }

    @Test(arguments: [true, false])
    @MainActor func userCancellationDuringImageGenerationCannotPresentLaterVisuals(dismissImage: Bool) async {
        let diagramOverlayController = PaceDiagramOverlayController(showsWindows: false)
        var continuation: CheckedContinuation<PaceGeneratedImageArtifact, Never>?
        var generationCount = 0
        var discarded: [UUID] = []
        let artifact = Self.artifact()
        let imageOverlayController = PaceImageOverlayController(
            showsWindows: false, discardArtifact: { discarded.append($0.id) },
            generateImage: { _, _ in
                generationCount += 1
                return await withCheckedContinuation { continuation = $0 }
            })
        Self.wireVisualReplacement(
            diagramOverlayController: diagramOverlayController, imageOverlayController: imageOverlayController)
        let actions: [PaceParsedAction] = [
            .generateImage(Self.request), .showDiagram(Self.diagram("Stale diagram")), .dismissDiagram,
            .generateImage(.init(prompt: "A red mug", title: "Stale image")),
        ]
        let parsed = PaceActionTagParseResult(
            spokenText: "Here it is.", actions: actions, executionPlan: .serial(actions: actions),
            firstClickVisualisationLocation: nil)
        let task = Task {
            var diagramDismissalGeneration = 0
            return await PaceVisualActionDrainer.drain(
                parseResult: parsed, diagramOverlayController: diagramOverlayController,
                imageOverlayController: imageOverlayController,
                expectedDiagramDismissalGeneration: &diagramDismissalGeneration, expectedImageDismissalGeneration: 0)
        }
        while continuation == nil { await Task.yield() }
        if dismissImage {
            imageOverlayController.dismiss()
        } else {
            task.cancel()
        }
        continuation?.resume(returning: artifact)
        let drained = await task.value
        #expect(generationCount == 1)
        #expect(discarded == [artifact.id])
        #expect(imageOverlayController.state == .idle)
        #expect(imageOverlayController.lastSuccessfulArtifact == nil)
        #expect(diagramOverlayController.document == nil)
        #expect(diagramOverlayController.dismissalGeneration == 0)
        #expect(drained.actions.isEmpty)
        #expect(!drained.spokenText.contains("Your image is ready:"))
    }

    @Test @MainActor func externalDiagramDismissalDuringImageGenerationKeepsNewerDiagramUnchanged() async {
        let diagramOverlayController = PaceDiagramOverlayController(showsWindows: false)
        var continuation: CheckedContinuation<PaceGeneratedImageArtifact, Never>?
        var generationCount = 0
        let imageOverlayController = PaceImageOverlayController(
            showsWindows: false, discardArtifact: { _ in },
            generateImage: { _, _ in
                generationCount += 1
                return await withCheckedContinuation { continuation = $0 }
            })
        Self.wireVisualReplacement(
            diagramOverlayController: diagramOverlayController, imageOverlayController: imageOverlayController)
        let actions: [PaceParsedAction] = [
            .generateImage(Self.request), .dismissDiagram, .showDiagram(Self.diagram("Stale")),
            .generateImage(.init(prompt: "A red mug", title: "Stale image")),
        ]
        let parsed = PaceActionTagParseResult(
            spokenText: "Here it is.", actions: actions, executionPlan: .serial(actions: actions),
            firstClickVisualisationLocation: nil)
        let task = Task {
            var diagramDismissalGeneration = 0
            let drained = await PaceVisualActionDrainer.drain(
                parseResult: parsed, diagramOverlayController: diagramOverlayController,
                imageOverlayController: imageOverlayController,
                expectedDiagramDismissalGeneration: &diagramDismissalGeneration, expectedImageDismissalGeneration: 0)
            return (drained, diagramDismissalGeneration)
        }
        while continuation == nil { await Task.yield() }
        diagramOverlayController.dismiss()
        diagramOverlayController.present(Self.diagram("Newer user request"))
        continuation?.resume(returning: Self.artifact())
        let (_, expectedDiagramDismissalGeneration) = await task.value
        #expect(generationCount == 1)
        #expect(expectedDiagramDismissalGeneration == 0)
        #expect(diagramOverlayController.dismissalGeneration == 1)
        #expect(diagramOverlayController.document?.title == "Newer user request")
        #expect(imageOverlayController.state == .idle)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PACE_RUN_CODEX_IMAGE_INTEGRATION"] == "1"))
    @MainActor func actualCodexGeneratesImageAndEditsOnlyItsOwnArtifact() async throws {
        let planner = PaceLocalCLIPlannerClient(upstream: .codex, modelIdentifier: nil)
        let response = try await planner.generateResponseStreaming(
            images: [], systemPrompt: CompanionSystemPrompt.buildTextOnly(includeInteractiveDiagrams: true),
            conversationHistory: [],
            userPrompt: "Generate an image of one blue ceramic mug on a plain white background. No text.",
            onTextChunk: { _ in })
        let plan = PaceActionTagParser.parseActions(from: response.text)
        try #require(
            plan.actions.count == 1, "The real planner must dispatch an image request rather than speak tool JSON.")
        guard case .generateImage(let request) = plan.actions[0] else {
            Issue.record("The planner did not request image generation.")
            return
        }
        let client = PaceCodexImageGenerationClient()
        let original = try await client.generate(request: request, previous: nil)
        #expect(FileManager.default.fileExists(atPath: original.fileURL.path))
        #expect(original.width > 0 && original.height > 0)
        print(
            "PACE_IMAGE_INTEGRATION original=\(original.fileURL.path) dimensions=\(original.width)x\(original.height)")
        let updated = try await client.generate(
            request: .init(
                prompt: "Change the ceramic mug to yellow. Preserve its composition.", title: "Yellow mug", edit: true),
            previous: original)
        #expect(updated.id != original.id)
        #expect(updated.width > 0 && updated.height > 0)
        #expect(FileManager.default.fileExists(atPath: original.fileURL.path))
        print("PACE_IMAGE_INTEGRATION edited=\(updated.fileURL.path) dimensions=\(updated.width)x\(updated.height)")
    }
}
