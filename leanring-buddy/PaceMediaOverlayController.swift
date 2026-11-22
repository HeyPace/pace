import AppKit
import SwiftUI

nonisolated struct PaceMediaPresentationRequest: Equatable, Sendable {
    enum Source: Equatable, Sendable {
        case catalogAsset(String)
        case generatedSVG(PaceGeneratedSVG)
        case interactiveCard(PacePowerCard)
    }
    let source: Source
    let durationSeconds: Double
    let motion: String?

    // Existing catalog callers retain their original identifier accessor.
    var assetID: String {
        switch source {
        case .catalogAsset(let identifier): return identifier
        case .generatedSVG: return "generated-svg"
        case .interactiveCard: return "generated-card"
        }
    }
    var presentationSummary: String {
        switch source {
        case .catalogAsset: return "local media " + assetID
        case .generatedSVG: return "generated drawing"
        case .interactiveCard(let card): return "interactive card “" + card.title + "”"
        }
    }
    var maximumDurationSeconds: Double {
        if case .interactiveCard = source { return 300 }
        return 30
    }
    var card: PacePowerCard? {
        if case .interactiveCard(let card) = source { return card }
        return nil
    }
    var illustration: PaceGeneratedSVG? {
        switch source {
        case .generatedSVG(let svg): return svg
        case .interactiveCard(let card): return card.illustration
        case .catalogAsset: return nil
        }
    }

    init(assetID: String, durationSeconds: Double, motion: String?) {
        source = .catalogAsset(assetID)
        self.durationSeconds = durationSeconds
        self.motion = motion
    }

    init(svg: PaceGeneratedSVG, durationSeconds: Double) {
        source = .generatedSVG(svg)
        self.durationSeconds = durationSeconds
        motion = nil
    }

    init(card: PacePowerCard, durationSeconds: Double) {
        source = .interactiveCard(card)
        self.durationSeconds = durationSeconds
        motion = nil
    }

    static func parse(arguments: [String: PaceMCPJSONValue]) -> Self? {
        guard Set(arguments.keys).isSubset(of: ["assetID", "svg", "card", "durationSeconds", "motion"]),
            case .number(let durationSeconds)? = arguments["durationSeconds"],
            durationSeconds.isFinite
        else { return nil }
        if let cardValue = arguments["card"] {
            guard arguments["assetID"] == nil, arguments["svg"] == nil, arguments["motion"] == nil,
                (1...300).contains(durationSeconds), case .string(let source) = cardValue,
                let card = PacePowerCard.parse(source)
            else { return nil }
            return Self(card: card, durationSeconds: durationSeconds)
        }
        guard (1...30).contains(durationSeconds) else { return nil }
        if let svgValue = arguments["svg"] {
            guard arguments["assetID"] == nil, arguments["motion"] == nil,
                case .string(let source) = svgValue, let svg = PaceGeneratedSVG.parse(source)
            else { return nil }
            return Self(svg: svg, durationSeconds: durationSeconds)
        }
        guard case .string(let assetID)? = arguments["assetID"], !assetID.isEmpty, assetID.count <= 80,
            PaceManagedPowerStore.safeIdentifier(assetID)
        else { return nil }
        let motion: String?
        if let motionValue = arguments["motion"] {
            guard case .string(let value) = motionValue, ["none", "bob", "dance"].contains(value) else { return nil }
            motion = value
        } else {
            motion = nil
        }
        return Self(assetID: assetID, durationSeconds: durationSeconds, motion: motion)
    }
}

@MainActor
final class PaceMediaOverlayController {
    var onUserDismiss: ((UUID) -> Void)?
    private let showsWindows: Bool
    private let resolveImage: (String) -> NSImage?

    init(
        showsWindows: Bool = true,
        resolveImage: @escaping (String) -> NSImage? = { identifier in
            PaceLocalMediaCatalog().resourceURL(for: identifier).flatMap(NSImage.init(contentsOf:))
        }
    ) {
        self.showsWindows = showsWindows
        self.resolveImage = resolveImage
    }
    private(set) var presentationGeneration = UUID()
    private(set) var isVisible = false
    private var imagePanel: NSPanel?
    private var controlsPanel: NSPanel?
    private var dismissalTask: Task<Void, Never>?
    private var generatedRenderer: PaceGeneratedSVGRenderer?
    private var pendingRenderer: PaceGeneratedSVGRenderer?
    private var authorizeCardInteraction: ((PacePowerCardInteraction) -> Bool)?
    var prepareGeneratedRenderer: (PaceGeneratedSVGRenderer, PaceGeneratedSVG) async throws -> Void = { renderer, svg in
        try await renderer.prepare(svg)
    }

    func presentGenerated(
        _ request: PaceMediaPresentationRequest, mayPresent: () -> Bool,
        onDismiss: @escaping (UUID) -> Void
    ) async -> PaceActionExecutionObservation {
        guard case .generatedSVG(let svg) = request.source else { return present(request) }
        return await prepareVisual(request, svg: svg, mayPresent: mayPresent, onDismiss: onDismiss)
    }

    func presentCard(
        _ request: PaceMediaPresentationRequest, mayPresent: () -> Bool,
        authorizeInteraction: @escaping (PacePowerCardInteraction) -> Bool,
        onDismiss: @escaping (UUID) -> Void
    ) async -> PaceActionExecutionObservation {
        guard request.card != nil else {
            return .init(
                toolName: "present_media", summary: "Invalid Power card.", terminalReason: .managedWorkflowUnavailable)
        }
        let result = await prepareVisual(
            request, svg: request.illustration, mayPresent: mayPresent, onDismiss: onDismiss)
        if result.terminalReason == nil { authorizeCardInteraction = authorizeInteraction }
        return result
    }

    private func prepareVisual(
        _ request: PaceMediaPresentationRequest, svg: PaceGeneratedSVG?, mayPresent: () -> Bool,
        onDismiss: @escaping (UUID) -> Void
    ) async -> PaceActionExecutionObservation {
        guard request.durationSeconds.isFinite, (1...request.maximumDurationSeconds).contains(request.durationSeconds)
        else {
            return .init(
                toolName: "present_media", summary: "Generated drawing duration is invalid.",
                terminalReason: .managedWorkflowUnavailable)
        }
        dismiss(cancelOwnedRun: false)
        let preparationGeneration = presentationGeneration
        guard let svg else {
            guard !Task.isCancelled, mayPresent() else {
                return .init(
                    toolName: "present_media", summary: "Power card stopped before presentation.",
                    terminalReason: .managedWorkflowUnavailable)
            }
            onUserDismiss = onDismiss
            return show(request, image: nil, renderer: nil)
        }
        let renderer = PaceGeneratedSVGRenderer(
            viewportSize: request.card == nil ? CGSize(width: 240, height: 320) : CGSize(width: 376, height: 180))
        pendingRenderer = renderer
        do {
            try await prepareGeneratedRenderer(renderer, svg)
            guard !Task.isCancelled, presentationGeneration == preparationGeneration, mayPresent() else {
                throw CancellationError()
            }
            pendingRenderer = nil
            onUserDismiss = onDismiss
            return show(request, image: nil, renderer: renderer)
        } catch {
            renderer.stop()
            if pendingRenderer === renderer { pendingRenderer = nil }
            return .init(
                toolName: "present_media", summary: "Generated drawing stopped or could not render.",
                terminalReason: .managedWorkflowUnavailable)
        }
    }

    @discardableResult
    func present(_ request: PaceMediaPresentationRequest) -> PaceActionExecutionObservation {
        guard case .catalogAsset(let identifier) = request.source,
            request.durationSeconds.isFinite, (1...30).contains(request.durationSeconds),
            let image = resolveImage(identifier), image.isValid
        else {
            return .init(
                toolName: "present_media", summary: "Could not load the requested local media asset.",
                terminalReason: .managedWorkflowUnavailable)
        }
        return show(request, image: image, renderer: nil)
    }

    private func show(_ request: PaceMediaPresentationRequest, image: NSImage?, renderer: PaceGeneratedSVGRenderer?)
        -> PaceActionExecutionObservation
    {
        dismiss(cancelOwnedRun: false)
        generatedRenderer = renderer
        let generation = UUID()
        presentationGeneration = generation
        renderer?.onRenderFailure = { [weak self] in
            self?.dismissPresentation(ifGenerationMatches: generation, cancelOwnedRun: true)
        }
        if showsWindows {
            guard
                let screen = PaceActiveDisplayCoordinator.shared.targetScreen ?? NSScreen.main ?? NSScreen.screens.first
            else {
                dismiss(cancelOwnedRun: false)
                return .init(
                    toolName: "present_media", summary: "No display available for local media.",
                    terminalReason: .managedWorkflowUnavailable)
            }
            let visibleFrame = screen.visibleFrame
            let imageSize =
                request.card == nil
                ? CGSize(width: 240, height: 320)
                : CGSize(width: min(420, visibleFrame.width - 72), height: min(580, visibleFrame.height - 100))
            let origin = CGPoint(
                x: visibleFrame.maxX - imageSize.width - 36,
                y: request.card == nil ? visibleFrame.minY + 110 : visibleFrame.maxY - imageSize.height - 50)
            let imagePanel = makePanel(frame: CGRect(origin: origin, size: imageSize))
            imagePanel.identifier = NSUserInterfaceItemIdentifier("pace.power.media")
            imagePanel.title = request.card == nil ? "Pace power animation" : "Pace Power card"
            imagePanel.setAccessibilityLabel(imagePanel.title)
            imagePanel.ignoresMouseEvents = request.card == nil
            if let card = request.card {
                let host = NSHostingView(
                    rootView: PacePowerCardView(
                        card: card, illustrationView: renderer?.view,
                        authorizeInteraction: { [weak self] interaction in
                            self?.handleCardInteraction(ifGenerationMatches: generation, interaction: interaction)
                                == true
                        },
                        dismiss: { [weak self] in
                            self?.dismissPresentation(ifGenerationMatches: generation, cancelOwnedRun: true)
                        }
                    ).frame(width: imageSize.width, height: imageSize.height))
                host.sizingOptions = []
                imagePanel.contentView = host
            } else if let renderer {
                renderer.view.frame = CGRect(origin: .zero, size: imageSize)
                imagePanel.contentView = renderer.view
            } else if let image {
                let imageHostView = NSHostingView(
                    rootView: MediaImageView(image: image, motion: request.motion)
                        .frame(width: imageSize.width, height: imageSize.height))
                imageHostView.sizingOptions = []
                imagePanel.contentView = imageHostView
            }
            self.imagePanel = imagePanel

            if request.card == nil {
                let controlsPanel = makePanel(
                    frame: CGRect(x: origin.x, y: origin.y - 40, width: imageSize.width, height: 34))
                controlsPanel.identifier = NSUserInterfaceItemIdentifier("pace.power.media.controls")
                controlsPanel.title = "Pace power animation controls"
                controlsPanel.setAccessibilityLabel("Pace power animation controls")
                controlsPanel.contentView = NSHostingView(
                    rootView: MediaControlsView {
                        self.dismissPresentation(ifGenerationMatches: generation, cancelOwnedRun: true)
                    })
                self.controlsPanel = controlsPanel
                controlsPanel.orderFrontRegardless()
            }
            imagePanel.orderFrontRegardless()
            isVisible = imagePanel.isVisible && (request.card != nil || controlsPanel?.isVisible == true)
        } else {
            isVisible = true
        }
        guard isVisible else {
            dismiss(cancelOwnedRun: false)
            return .init(
                toolName: "present_media", summary: "Could not show local media.",
                terminalReason: .managedWorkflowUnavailable)
        }
        dismissalTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(request.durationSeconds))
            guard !Task.isCancelled, let self, self.presentationGeneration == generation else { return }
            self.finishPresentation(ifGenerationMatches: generation)
        }
        return .init(
            toolName: "present_media",
            summary: "Presented \(request.presentationSummary) for \(request.durationSeconds) seconds.")
    }

    @discardableResult
    func handleCardInteraction(ifGenerationMatches generation: UUID, interaction: PacePowerCardInteraction) -> Bool {
        guard isVisible, presentationGeneration == generation else { return false }
        guard authorizeCardInteraction?(interaction) == true else {
            dismissPresentation(ifGenerationMatches: generation, cancelOwnedRun: true)
            return false
        }
        return true
    }

    func dismissPresentation(ifGenerationMatches expectedGeneration: UUID, cancelOwnedRun: Bool) {
        guard presentationGeneration == expectedGeneration else { return }
        dismiss(cancelOwnedRun: cancelOwnedRun)
    }

    func finishPresentation(ifGenerationMatches expectedGeneration: UUID) {
        guard presentationGeneration == expectedGeneration else { return }
        dismiss(cancelOwnedRun: false)
    }

    func dismiss(cancelOwnedRun: Bool) {
        let hadPresentation = isVisible
        let dismissedGeneration = presentationGeneration
        presentationGeneration = UUID()
        pendingRenderer?.stop()
        pendingRenderer = nil
        generatedRenderer?.stop()
        generatedRenderer = nil
        dismissalTask?.cancel()
        dismissalTask = nil
        imagePanel?.orderOut(nil)
        controlsPanel?.orderOut(nil)
        imagePanel?.contentView = nil
        controlsPanel?.contentView = nil
        imagePanel?.close()
        controlsPanel?.close()
        imagePanel = nil
        controlsPanel = nil
        isVisible = false
        authorizeCardInteraction = nil
        if cancelOwnedRun && hadPresentation { onUserDismiss?(dismissedGeneration) }
    }

    private func makePanel(frame: CGRect) -> NSPanel {
        let panel = PassiveMediaPanel(
            contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        return panel
    }
}

private final class PassiveMediaPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class BoundedMediaImageView: NSImageView {
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }
}

private struct AnimatedMediaImage: NSViewRepresentable {
    let image: NSImage
    func makeNSView(context: Context) -> NSImageView {
        let imageView = BoundedMediaImageView()
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.animates = true
        imageView.image = image
        return imageView
    }
    func updateNSView(_ view: NSImageView, context: Context) { view.image = image }
}

private struct MediaImageView: View {
    let image: NSImage
    let motion: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animated = false
    var body: some View {
        AnimatedMediaImage(image: image)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .rotationEffect(.degrees(motion == "dance" && animated ? 4 : 0))
            .offset(y: ["bob", "dance"].contains(motion ?? "") && animated ? -10 : 0)
            .padding(12)
            .onAppear {
                guard !reduceMotion, motion == "bob" || motion == "dance" else { return }
                withAnimation(.easeInOut(duration: 0.35).repeatForever(autoreverses: true)) { animated = true }
            }
            .allowsHitTesting(false)
    }
}

private struct MediaControlsView: View {
    let dismiss: () -> Void
    var body: some View {
        HStack(spacing: 10) {
            Text("Pace").font(.system(size: 12, weight: .medium))
            Spacer()
            Button(action: dismiss) {
                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop media and speech")
            .onHover { hovered in if hovered { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black, in: RoundedRectangle(cornerRadius: 10))
    }
}
