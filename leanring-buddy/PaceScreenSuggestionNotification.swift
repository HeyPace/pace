import AppKit
import QuartzCore
import SwiftUI

nonisolated enum PaceScreenSuggestionNotificationAction: Equatable {
    case explain
    case draw
    case dismiss

    func request(for suggestion: PaceScreenSuggestion) -> String? {
        let context = "Your offer was “\(suggestion.offer)”. The page said “\(suggestion.evidence)”."
        switch self {
        case .explain:
            return "Please explain “\(suggestion.subject)” with a detailed, labeled, interactive visual and brief step-by-step narration. Show the visual early, highlight the part you are explaining, and reuse it as the explanation progresses. \(context)"
        case .draw:
            return "Please draw a detailed, labeled, interactive diagram explaining “\(suggestion.subject)”. Use an illustrative figure suited to the topic, with selectable parts; use a rotatable 3D model for a physical object when useful. \(context)"
        case .dismiss:
            return nil
        }
    }
}

@MainActor
protocol PaceScreenSuggestionNotificationPresenting: AnyObject {
    func show(_ suggestion: PaceScreenSuggestion, onAction: @escaping (PaceScreenSuggestionNotificationAction) -> Void)
    func hide(animated: Bool)
    func playArrivalSound()
    func stopArrivalSound()
}

@MainActor
final class PaceScreenSuggestionNotificationController {
    private(set) var currentSuggestion: PaceScreenSuggestion?
    private var presentedSuggestionIdentifiers: Set<UUID> = []
    private let presenter: any PaceScreenSuggestionNotificationPresenting
    private let onAction: (PaceScreenSuggestion, PaceScreenSuggestionNotificationAction) -> Void

    init(presenter: any PaceScreenSuggestionNotificationPresenting,
         onAction: @escaping (PaceScreenSuggestion, PaceScreenSuggestionNotificationAction) -> Void) {
        self.presenter = presenter
        self.onAction = onAction
    }

    @discardableResult
    func present(_ suggestion: PaceScreenSuggestion) -> Bool {
        guard presentedSuggestionIdentifiers.insert(suggestion.identifier).inserted else { return false }
        currentSuggestion = suggestion
        presenter.show(suggestion) { [weak self] action in
            self?.respond(to: suggestion.identifier, action: action)
        }
        presenter.playArrivalSound()
        return true
    }

    func hasPresented(suggestionIdentifier: UUID) -> Bool {
        presentedSuggestionIdentifiers.contains(suggestionIdentifier)
    }

    func discard(animated: Bool = false) {
        guard currentSuggestion != nil else { return }
        currentSuggestion = nil
        presenter.stopArrivalSound()
        presenter.hide(animated: animated)
    }

    func dismissAcknowledgedOffer(eventIdentifier: String) {
        guard currentSuggestion?.conversationEventIdentifier == eventIdentifier else { return }
        discard(animated: true)
    }

    func respond(to suggestionIdentifier: UUID, action: PaceScreenSuggestionNotificationAction) {
        guard let suggestion = currentSuggestion, suggestion.identifier == suggestionIdentifier else { return }
        discard(animated: true)
        onAction(suggestion, action)
    }
}

@MainActor
final class PaceScreenSuggestionNotificationPanel: PaceScreenSuggestionNotificationPresenting {
    private var panel: PaceSuggestionPanel?
    private var animationGeneration = 0
    private var arrivalSound: NSSound?

    func show(_ suggestion: PaceScreenSuggestion, onAction: @escaping (PaceScreenSuggestionNotificationAction) -> Void) {
        animationGeneration += 1
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let hostingView = NSHostingView(rootView: PaceScreenSuggestionNotificationView(suggestion: suggestion, onAction: onAction))
        panel.contentView = hostingView
        let display = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32) == suggestion.sceneIdentity.displayIdentifier
        } ?? NSScreen.main ?? NSScreen.screens.first
        guard let display else { return }
        let size = hostingView.fittingSize
        let visibleFrame = display.visibleFrame
        let destination = NSRect(x: visibleFrame.maxX - size.width - 20,
            y: visibleFrame.maxY - size.height - 16, width: size.width, height: size.height)
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        panel.alphaValue = 0
        panel.setFrame(destination.offsetBy(dx: reduceMotion ? 0 : 12, dy: 0), display: false)
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduceMotion ? 0.12 : 0.2
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(destination, display: true)
        }
    }

    func hide(animated: Bool) {
        guard let panel, panel.isVisible else { return }
        animationGeneration += 1
        guard animated else {
            panel.orderOut(nil)
            return
        }
        let generation = animationGeneration
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let destination = panel.frame.offsetBy(dx: reduceMotion ? 0 : 12, dy: 0)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduceMotion ? 0.12 : 0.18
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
            panel.animator().alphaValue = 0
            panel.animator().setFrame(destination, display: true)
        } completionHandler: { [weak self, weak panel] in
            Task { @MainActor in
                guard self?.animationGeneration == generation else { return }
                panel?.orderOut(nil)
            }
        }
    }

    func playArrivalSound() {
        stopArrivalSound()
        let soundURL = URL(fileURLWithPath: "/System/Library/Sounds/Glass.aiff")
        arrivalSound = NSSound(contentsOf: soundURL, byReference: true)
        arrivalSound?.volume = 0.22
        arrivalSound?.play()
    }

    func stopArrivalSound() {
        arrivalSound?.stop()
        arrivalSound = nil
    }

    private func makePanel() -> PaceSuggestionPanel {
        let panel = PaceSuggestionPanel(contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.setAccessibilityLabel("Pace screen suggestion")
        panel.title = "Pace screen suggestion"
        return panel
    }
}

private final class PaceSuggestionPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

struct PaceScreenSuggestionNotificationView: View {
    let suggestion: PaceScreenSuggestion
    let onAction: (PaceScreenSuggestionNotificationAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(spacing: 9) {
                PaceBrandMark().foregroundStyle(Color(red: 0.75, green: 0.84, blue: 1))
                    .frame(width: 25, height: 25)
                    .padding(5)
                    .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Pace").font(.system(size: 12, weight: .semibold))
                    Text("On your screen").font(.system(size: 11)).foregroundStyle(.white.opacity(0.48))
                }
                Spacer()
                Button { onAction(.dismiss) } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(PaceSuggestionNotificationButtonStyle(isPrimary: false))
                .help("Dismiss suggestion").accessibilityLabel("Dismiss suggestion")
            }
            VStack(alignment: .leading, spacing: 7) {
                Text(suggestion.subject).font(.system(size: 17, weight: .semibold))
                    .tracking(-0.3).fixedSize(horizontal: false, vertical: true)
                Text(suggestion.offer).font(.system(size: 13)).lineSpacing(3)
                    .foregroundStyle(.white.opacity(0.68)).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                actionButton("Explain", symbol: "waveform", action: .explain, isPrimary: true)
                actionButton("Draw it", symbol: "square.on.circle", action: .draw, isPrimary: false)
                Spacer(minLength: 0)
                Button { onAction(.dismiss) } label: {
                    Text("Not now").font(.system(size: 11)).padding(.horizontal, 8).padding(.vertical, 9)
                }
                    .buttonStyle(PaceSuggestionNotificationButtonStyle(isPrimary: false))
            }
        }
        .padding(18)
        .frame(width: 360, alignment: .leading)
        .foregroundStyle(.white.opacity(0.94))
        .background(Color(red: 0.098, green: 0.11, blue: 0.137), in: RoundedRectangle(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.15), lineWidth: 1) }
        .colorScheme(.dark)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Pace screen suggestion")
    }

    private func actionButton(_ title: String, symbol: String,
                              action: PaceScreenSuggestionNotificationAction, isPrimary: Bool) -> some View {
        Button { onAction(action) } label: {
            Label(title, systemImage: symbol).font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 12).padding(.vertical, 9)
        }
        .buttonStyle(PaceSuggestionNotificationButtonStyle(isPrimary: isPrimary))
    }
}

private struct PaceSuggestionNotificationButtonStyle: ButtonStyle {
    let isPrimary: Bool

    func makeBody(configuration: Configuration) -> some View {
        Content(configuration: configuration, isPrimary: isPrimary)
    }

    private struct Content: View {
        let configuration: ButtonStyle.Configuration
        let isPrimary: Bool
        @State private var isHovered = false
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            configuration.label
                .foregroundStyle(isPrimary ? Color(red: 0.12, green: 0.17, blue: 0.24) : .white.opacity(isHovered ? 0.95 : 0.65))
                .background(background, in: RoundedRectangle(cornerRadius: 8))
                .overlay { PointerCursorView().allowsHitTesting(false) }
                .opacity(configuration.isPressed ? 0.76 : 1)
                .onHover { isHovered = $0 }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isHovered)
        }

        private var background: Color {
            if isPrimary { return Color(red: 0.78, green: 0.87, blue: 1).opacity(isHovered ? 1 : 0.92) }
            return .white.opacity(configuration.isPressed ? 0.13 : isHovered ? 0.08 : 0.025)
        }
    }
}
