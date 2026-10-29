import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class PaceImageOverlayManager {
    private weak var controller: PaceImageOverlayController?
    private var panel: PaceImagePanel?

    init(controller: PaceImageOverlayController) { self.controller = controller }

    func show() {
        guard let controller else { return }
        if panel == nil {
            let panel = PaceImagePanel(
                contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel, .resizable], backing: .buffered,
                defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.level = .floating
            panel.hasShadow = false
            panel.hidesOnDeactivate = false
            panel.isFloatingPanel = true
            panel.setAccessibilityLabel("Pace generated image")
            panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.contentMinSize = .init(width: 420, height: 320)
            panel.contentView = NSHostingView(rootView: PaceImageOverlayView(controller: controller))
            let frame =
                (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
            let size = NSSize(width: min(800, frame.width - 80), height: min(690, frame.height - 80))
            panel.setFrame(
                NSRect(
                    x: frame.midX - size.width / 2, y: frame.midY - size.height / 2, width: size.width,
                    height: size.height), display: false)
            self.panel = panel
        }
        panel?.orderFrontRegardless()
    }

    func hide() { panel?.orderOut(nil) }
}

private final class PaceImagePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private struct PaceImageOverlayView: View {
    @ObservedObject var controller: PaceImageOverlayController
    @State private var zoom = 1.0
    @State private var saveError: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "photo").foregroundStyle(.white.opacity(0.6))
                Text(title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Spacer()
                button("Zoom out", symbol: "minus.magnifyingglass") { zoom = max(1, zoom - 0.25) }.disabled(
                    controller.lastSuccessfulArtifact == nil)
                Text("\(Int(zoom * 100))%").font(.system(size: 11, design: .monospaced)).foregroundStyle(
                    .white.opacity(0.55)
                ).frame(width: 40)
                button("Zoom in", symbol: "plus.magnifyingglass") { zoom = min(4, zoom + 0.25) }.disabled(
                    controller.lastSuccessfulArtifact == nil)
                button("Save image", symbol: "square.and.arrow.down") { save() }.disabled(
                    controller.lastSuccessfulArtifact == nil)
                button("Close image", symbol: "xmark") { controller.dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 18).padding(.vertical, 14)
            .background(chrome, in: UnevenRoundedRectangle(topLeadingRadius: 14, topTrailingRadius: 14))
            Divider().overlay(.white.opacity(0.08))
            GeometryReader { geometry in
                if let artifact = controller.lastSuccessfulArtifact, let image = NSImage(contentsOf: artifact.fileURL) {
                    ScrollView([.horizontal, .vertical]) {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                            .frame(width: geometry.size.width * zoom, height: geometry.size.height * zoom)
                            .accessibilityLabel(artifact.request.title)
                    }
                } else {
                    VStack(spacing: 16) {
                        if case .generating = controller.state { ProgressView().controlSize(.large).tint(.white) }
                        Image(systemName: "photo").font(.system(size: 42, weight: .ultraLight)).foregroundStyle(
                            .white.opacity(0.25))
                        Text(controller.statusText ?? "").font(.system(size: 14)).multilineTextAlignment(.center)
                            .foregroundStyle(.white.opacity(0.7)).padding(.horizontal, 40)
                    }
                    .padding(.vertical, 32)
                    .frame(maxWidth: 420)
                    .background(chrome, in: RoundedRectangle(cornerRadius: 14))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            Divider().overlay(.white.opacity(0.08))
            HStack(spacing: 10) {
                if case .generating = controller.state { ProgressView().controlSize(.small) }
                Circle().fill(Color.orange.opacity(0.85)).frame(width: 5, height: 5)
                Text(saveError ?? controller.statusText ?? "").font(.system(size: 12)).lineLimit(2)
                Spacer(minLength: 0)
                Text("Codex · Image").font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
            }.foregroundStyle(.white.opacity(0.65)).padding(.horizontal, 18).padding(.vertical, 13)
                .background(chrome, in: UnevenRoundedRectangle(bottomLeadingRadius: 14, bottomTrailingRadius: 14))
        }
        .foregroundStyle(.white.opacity(0.9))
        .background(Color.clear)
        .onChange(of: controller.lastSuccessfulArtifact?.id) { _, _ in
            zoom = 1
            saveError = nil
        }
    }

    private var chrome: Color { Color(red: 0.075, green: 0.08, blue: 0.09) }

    private var title: String {
        if case .generating(let request) = controller.state { return request.title }
        return controller.lastSuccessfulArtifact?.request.title ?? "Image generation"
    }

    private func button(_ label: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13)).frame(width: 28, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(PaceImageButtonStyle()).help(label).accessibilityLabel(label)
    }

    private func save() {
        guard let artifact = controller.lastSuccessfulArtifact else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [artifact.fileURL.pathExtension == "png" ? .png : .jpeg]
        panel.nameFieldStringValue =
            artifact.request.title.replacingOccurrences(of: "/", with: "-") + "." + artifact.fileURL.pathExtension
        panel.begin { response in
            guard response == .OK, let destination = panel.url else { return }
            do {
                let validated = try PaceGeneratedImageStore.validatedImageData(at: artifact.fileURL)
                try validated.data.write(to: destination, options: .atomic)
                controller.preserveExplicitlySavedArtifact(artifact, at: destination)
                saveError = nil
            } catch { saveError = "Couldn't save image. \(error.localizedDescription)" }
        }
    }
}

private struct PaceImageButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PaceImageButtonBody(configuration: configuration)
    }
    private struct PaceImageButtonBody: View {
        let configuration: ButtonStyle.Configuration
        @State private var hovered = false
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            configuration.label
                .foregroundStyle(.white.opacity(enabled ? 0.8 : 0.25))
                .background(
                    .white.opacity(configuration.isPressed ? 0.16 : hovered && enabled ? 0.09 : 0),
                    in: RoundedRectangle(cornerRadius: 6)
                )
                .onHover { hovering in
                    hovered = hovering
                    if hovering && enabled { NSCursor.pointingHand.push() } else if !hovering { NSCursor.pop() }
                }
        }
    }
}
