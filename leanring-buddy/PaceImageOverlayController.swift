import AppKit
import Combine
import Foundation

@MainActor
final class PaceImageOverlayController: ObservableObject {
    @Published private(set) var state: PaceImageGenerationState = .idle
    @Published private(set) var lastSuccessfulArtifact: PaceGeneratedImageArtifact?
    private(set) var dismissalGeneration = 0
    var authorizationCheck: () -> Bool = { false }
    var onWillGenerate: (() -> Void)?
    var onGenerationProgress: ((String) -> Void)?
    private let discardArtifact: (PaceGeneratedImageArtifact) -> Void
    private let showsWindows: Bool
    private let generateImage:
        @MainActor (PaceImageGenerationRequest, PaceGeneratedImageArtifact?) async throws -> PaceGeneratedImageArtifact
    private var generationTask: Task<PaceGeneratedImageArtifact, Error>?
    private var generationIdentifier: UUID?
    private var explicitlySavedWorkingArtifactIdentifiers: Set<UUID> = []
    private var overlay: PaceImageOverlayManager?

    init(
        showsWindows: Bool = true,
        discardArtifact: @escaping (PaceGeneratedImageArtifact) -> Void = PaceGeneratedImageStore
            .discardWorkingArtifact,
        generateImage: (
            @MainActor (PaceImageGenerationRequest, PaceGeneratedImageArtifact?) async throws ->
                PaceGeneratedImageArtifact
        )? = nil
    ) {
        self.showsWindows = showsWindows
        self.discardArtifact = discardArtifact
        self.generateImage =
            generateImage ?? { request, previous in
                try await PaceCodexImageGenerationClient().generate(request: request, previous: previous)
            }
    }

    var statusText: String? {
        switch state {
        case .idle: return nil
        case .generating(let request): return "Generating \(request.title) with Codex…"
        case .ready(let artifact): return "\(artifact.request.title) · \(artifact.width) × \(artifact.height)"
        case .failed(let message): return message
        }
    }

    func dismiss() {
        dismissalGeneration += 1
        hideForDiagramReplacement()
    }

    // Ordered visual replacement does not revoke later image actions in the
    // same plan. The job identity still fences any earlier in-flight result.
    func hideForDiagramReplacement() {
        generationIdentifier = nil
        generationTask?.cancel()
        generationTask = nil
        if let lastSuccessfulArtifact { discardWorkingArtifactIfUnsaved(lastSuccessfulArtifact) }
        lastSuccessfulArtifact = nil
        state = .idle
        overlay?.hide()
    }

    func preserveExplicitlySavedArtifact(_ artifact: PaceGeneratedImageArtifact, at destination: URL) {
        if destination.resolvingSymlinksInPath().standardizedFileURL
            == artifact.fileURL.resolvingSymlinksInPath().standardizedFileURL
        {
            explicitlySavedWorkingArtifactIdentifiers.insert(artifact.id)
        }
    }

    private func discardWorkingArtifactIfUnsaved(_ artifact: PaceGeneratedImageArtifact) {
        if explicitlySavedWorkingArtifactIdentifiers.remove(artifact.id) != nil { return }
        discardArtifact(artifact)
    }

    func show() {
        guard state != .idle, showsWindows else { return }
        if overlay == nil { overlay = PaceImageOverlayManager(controller: self) }
        overlay?.show()
    }

    func appendingPlannerContext(to prompt: String) -> String {
        guard let artifact = lastSuccessfulArtifact else { return prompt }
        // JSON encoding keeps image descriptions delimited as data, never instructions or paths.
        let description = ["title": artifact.request.title, "prompt": String(artifact.request.prompt.prefix(8_000))]
        guard let data = try? JSONEncoder().encode(description), let context = String(data: data, encoding: .utf8)
        else { return prompt }
        return prompt + """


            <active_pace_image>
            The user is viewing a Pace-generated raster image. Description data: \(context)
            For requested edits call generate_image with edit:true and the precise change. Pace attaches only this image. For a new subject use edit:false and a complete brief. The image cannot rotate or expose physical 3D parts. Do not claim to see unrelated screen content.
            </active_pace_image>
            """
    }

    func generate(_ request: PaceImageGenerationRequest, expectedDismissalGeneration: Int) async -> String {
        guard expectedDismissalGeneration == dismissalGeneration, !Task.isCancelled else {
            return "I kept the image closed."
        }
        guard authorizationCheck() else {
            let message = PaceImageGenerationError.unavailable.localizedDescription
            state = .failed(message)
            show()
            return message
        }
        if request.edit && lastSuccessfulArtifact == nil {
            let message = PaceImageGenerationError.missingEditImage.localizedDescription
            state = .failed(message)
            show()
            return message
        }
        generationTask?.cancel()
        let identifier = UUID()
        generationIdentifier = identifier
        let previous = lastSuccessfulArtifact
        onWillGenerate?()
        state = .generating(request)
        onGenerationProgress?("Generating \(request.title) with Codex")
        show()
        let task = Task { try await generateImage(request, request.edit ? previous : nil) }
        generationTask = task
        // Consent may be revoked while the CLI is waiting on the provider.
        let consentMonitor = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled, let self, self.generationIdentifier == identifier else { return }
                if !self.authorizationCheck() {
                    self.dismiss()
                    return
                }
            }
        }
        defer { consentMonitor.cancel() }
        do {
            let artifact = try await withTaskCancellationHandler(
                operation: { try await task.value }, onCancel: { task.cancel() })
            let stillAuthorized = authorizationCheck()
            guard !Task.isCancelled, generationIdentifier == identifier,
                dismissalGeneration == expectedDismissalGeneration, stillAuthorized
            else {
                discardWorkingArtifactIfUnsaved(artifact)
                if generationIdentifier == identifier && !stillAuthorized {
                    dismiss()
                } else if generationIdentifier == identifier {
                    generationTask = nil
                    generationIdentifier = nil
                    state = lastSuccessfulArtifact.map { .ready($0) } ?? .idle
                    if state == .idle { overlay?.hide() }
                }
                return "Image generation was cancelled."
            }
            generationTask = nil
            generationIdentifier = nil
            if let previous, previous.id != artifact.id { discardWorkingArtifactIfUnsaved(previous) }
            lastSuccessfulArtifact = artifact
            state = .ready(artifact)
            return "Your image is ready: \(request.title)."
        } catch {
            guard generationIdentifier == identifier, dismissalGeneration == expectedDismissalGeneration else {
                return "Image generation was cancelled."
            }
            generationTask = nil
            generationIdentifier = nil
            if error is CancellationError || Task.isCancelled {
                state = lastSuccessfulArtifact.map { .ready($0) } ?? .idle
                if state == .idle { overlay?.hide() }
                return "Image generation was cancelled."
            }
            // Keep the previous image visible when a follow-up fails.
            let message = "I couldn't generate the image. \(error.localizedDescription)"
            state = .failed(message)
            return message
        }
    }
}

@MainActor
enum PaceVisualActionDrainer {
    static func drain(
        parseResult: PaceActionTagParseResult,
        diagramOverlayController: PaceDiagramOverlayController,
        imageOverlayController: PaceImageOverlayController,
        expectedDiagramDismissalGeneration: inout Int,
        expectedImageDismissalGeneration: Int,
        generateImage: (@MainActor (PaceImageGenerationRequest, Int) async -> String)? = nil
    ) async -> PaceActionTagParseResult {
        var imageMessages: [String] = []
        var spokenText = parseResult.spokenText
        var remainingSteps: [PaceActionExecutionStep] = []
        for step in parseResult.executionPlan.steps {
            var remainingActions: [PaceParsedAction] = []
            for action in step.actions {
                let permitsVisualOutput = !Task.isCancelled
                    && expectedDiagramDismissalGeneration == diagramOverlayController.dismissalGeneration
                    && expectedImageDismissalGeneration == imageOverlayController.dismissalGeneration
                switch action {
                case .showDiagram, .dismissDiagram:
                    guard permitsVisualOutput else {
                        spokenText = diagramOverlayController.document == nil
                            ? "I kept the diagram closed." : "I kept the current diagram unchanged."
                        continue
                    }
                    let diagramResult = diagramOverlayController.drain(
                        parseResult: .init(
                            spokenText: spokenText, actions: [action], executionPlan: .serial(actions: [action]),
                            firstClickVisualisationLocation: nil),
                        expectedDismissalGeneration: &expectedDiagramDismissalGeneration)
                    spokenText = diagramResult.spokenText
                case .generateImage(let request):
                    guard permitsVisualOutput else {
                        imageMessages.append("I kept the image closed.")
                        continue
                    }
                    // Keep the original leases across the await. User dismissal must
                    // revoke later visuals, while owned replacements preserve them.
                    let message: String
                    if let generateImage {
                        message = await generateImage(request, expectedImageDismissalGeneration)
                    } else {
                        message = await imageOverlayController.generate(
                            request, expectedDismissalGeneration: expectedImageDismissalGeneration)
                    }
                    imageMessages.append(message)
                default:
                    remainingActions.append(action)
                }
            }
            if !remainingActions.isEmpty { remainingSteps.append(.init(actions: remainingActions)) }
        }
        let remainingActions = parseResult.actions.filter { action in
            switch action {
            case .showDiagram, .dismissDiagram, .generateImage: return false
            default: return true
            }
        }
        return .init(
            spokenText: imageMessages.isEmpty
                ? spokenText
                : ((remainingActions.isEmpty ? [] : [spokenText]) + imageMessages).joined(separator: " "),
            actions: remainingActions,
            executionPlan: .init(steps: remainingSteps),
            firstClickVisualisationLocation: parseResult.firstClickVisualisationLocation)
    }
}
