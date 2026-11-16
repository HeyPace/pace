import AppKit
import SwiftUI

nonisolated struct PaceMediaPresentationRequest: Equatable, Sendable {
    let assetID: String
    let durationSeconds: Double
    let motion: String?

    static func parse(arguments: [String: PaceMCPJSONValue]) -> Self? {
        guard Set(arguments.keys).isSubset(of: ["assetID", "durationSeconds", "motion"]),
              case .string(let assetID)? = arguments["assetID"],
              !assetID.isEmpty, assetID.count <= 80,
              assetID.range(of: "^[a-z0-9]+(?:-[a-z0-9]+)*$", options: .regularExpression) != nil,
              case .number(let durationSeconds)? = arguments["durationSeconds"],
              durationSeconds.isFinite, (1...30).contains(durationSeconds) else { return nil }
        let motion: String?
        if let motionValue = arguments["motion"] {
            guard case .string(let value) = motionValue, ["none", "bob", "dance"].contains(value) else { return nil }
            motion = value
        } else { motion = nil }
        return Self(assetID: assetID, durationSeconds: durationSeconds, motion: motion)
    }
}

@MainActor
final class PaceMediaOverlayController {
    var onUserDismiss: ((UUID) -> Void)?
    private let showsWindows: Bool
    private let resolveImage: (String) -> NSImage?

    init(showsWindows: Bool = true, resolveImage: @escaping (String) -> NSImage? = { identifier in
        PaceLocalMediaCatalog().resourceURL(for: identifier).flatMap(NSImage.init(contentsOf:))
    }) {
        self.showsWindows = showsWindows
        self.resolveImage = resolveImage
    }
    private(set) var presentationGeneration = UUID()
    private(set) var isVisible = false
    private var imagePanel: NSPanel?
    private var controlsPanel: NSPanel?
    private var dismissalTask: Task<Void, Never>?

    @discardableResult
    func present(_ request: PaceMediaPresentationRequest) -> PaceActionExecutionObservation {
        guard request.durationSeconds.isFinite, (1...30).contains(request.durationSeconds),
              let image = resolveImage(request.assetID), image.isValid else {
            return .init(toolName: "present_media", summary: "Could not load the requested local media asset.", terminalReason: .managedWorkflowUnavailable)
        }
        dismiss(cancelOwnedRun: false)
        let generation = UUID()
        presentationGeneration = generation
        if showsWindows {
            guard let screen = NSScreen.main ?? NSScreen.screens.first else {
                return .init(toolName: "present_media", summary: "No display available for local media.", terminalReason: .managedWorkflowUnavailable)
            }
            let visibleFrame = screen.visibleFrame
            let imageSize = CGSize(width: 240, height: 320)
            let origin = CGPoint(x: visibleFrame.maxX - imageSize.width - 36, y: visibleFrame.minY + 110)
            let imagePanel = makePanel(frame: CGRect(origin: origin, size: imageSize))
            imagePanel.identifier = NSUserInterfaceItemIdentifier("pace.power.media")
            imagePanel.title = "Pace power animation"
            imagePanel.setAccessibilityLabel("Pace power animation")
            imagePanel.ignoresMouseEvents = true
            imagePanel.contentView = NSHostingView(rootView: MediaImageView(image: image, motion: request.motion))
            self.imagePanel = imagePanel

            let controlsPanel = makePanel(frame: CGRect(x: origin.x, y: origin.y - 40, width: imageSize.width, height: 34))
            controlsPanel.identifier = NSUserInterfaceItemIdentifier("pace.power.media.controls")
            controlsPanel.title = "Pace power animation controls"
            controlsPanel.setAccessibilityLabel("Pace power animation controls")
            controlsPanel.contentView = NSHostingView(rootView: MediaControlsView {
                self.dismissPresentation(ifGenerationMatches: generation, cancelOwnedRun: true)
            })
            self.controlsPanel = controlsPanel
            imagePanel.orderFrontRegardless()
            controlsPanel.orderFrontRegardless()
            isVisible = imagePanel.isVisible && controlsPanel.isVisible
        } else { isVisible = true }
        guard isVisible else {
            dismiss(cancelOwnedRun: false)
            return .init(toolName: "present_media", summary: "Could not show local media.", terminalReason: .managedWorkflowUnavailable)
        }
        dismissalTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(request.durationSeconds))
            guard !Task.isCancelled, let self, self.presentationGeneration == generation else { return }
            self.finishPresentation(ifGenerationMatches: generation)
        }
        return .init(toolName: "present_media", summary: "Presented local media \(request.assetID) for \(request.durationSeconds) seconds.")
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
        if cancelOwnedRun && hadPresentation { onUserDismiss?(dismissedGeneration) }
    }

    private func makePanel(frame: CGRect) -> NSPanel {
        let panel = PassiveMediaPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
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

private struct AnimatedMediaImage: NSViewRepresentable {
    let image: NSImage
    func makeNSView(context: Context) -> NSImageView {
        let imageView = NSImageView()
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
            Button(action: dismiss) { Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).frame(width: 24, height: 24) }
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
