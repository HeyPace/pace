import AppKit
import SwiftUI

@MainActor
final class PaceDiagramOverlayManager {
    private weak var controller: PaceDiagramOverlayController?
    private var drawingPanel: PaceDiagramIslandPanel?
    private var headerPanel: PaceDiagramIslandPanel?
    private var detailPanel: PaceDiagramIslandPanel?
    private var nodePanels: [String: PaceDiagramIslandPanel] = [:]
    private var displayIdentifier: NSNumber?
    private var screenObserver: NSObjectProtocol?
    private var localKeyMonitor: Any?
    private var globalKeyMonitor: Any?
    private var stageFrame = CGRect.zero
    private var visibleFrame = CGRect.zero

    init(controller: PaceDiagramOverlayController) {
        self.controller = controller
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.show() }
        }
    }

    deinit {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    }

    func show() {
        guard let controller, let document = controller.document,
              let screen = targetScreen() else { return }
        displayIdentifier = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        visibleFrame = screen.visibleFrame
        let maximumWidth = max(300, min(1120, visibleFrame.width - 80))
        let stageHeight = min(maximumWidth * 0.6, max(180, visibleFrame.height - 350))
        let stageWidth = stageHeight / 0.6
        stageFrame = CGRect(
            x: visibleFrame.midX - stageWidth / 2,
            y: visibleFrame.midY - stageHeight / 2 + 5,
            width: stageWidth, height: stageHeight
        )

        let drawingPanel = self.drawingPanel ?? PaceDiagramIslandPanel(ignoresMouseEvents: true)
        drawingPanel.contentView = NSHostingView(rootView: PaceDiagramConnectionsView(controller: controller))
        drawingPanel.setFrame(stageFrame, display: true)
        drawingPanel.orderFrontRegardless()
        self.drawingPanel = drawingPanel

        let headerWidth = min(stageWidth, 860)
        let headerFrame = CGRect(
            x: visibleFrame.midX - headerWidth / 2,
            y: min(visibleFrame.maxY - 128, stageFrame.maxY + 12),
            width: headerWidth, height: 104
        )
        let headerPanel = self.headerPanel ?? PaceDiagramIslandPanel()
        headerPanel.contentView = NSHostingView(rootView: PaceDiagramHeaderView(controller: controller))
        headerPanel.setFrame(headerFrame, display: true)
        headerPanel.orderFrontRegardless()
        self.headerPanel = headerPanel

        for (identifier, panel) in nodePanels where !document.nodes.contains(where: { $0.id == identifier }) {
            panel.orderOut(nil)
            nodePanels.removeValue(forKey: identifier)
        }
        for node in document.nodes {
            let nodeFrame = CGRect(
                x: stageFrame.minX + node.x / PaceDiagramDocument.canvasWidth * stageFrame.width,
                y: stageFrame.maxY - (node.y + node.height) / PaceDiagramDocument.canvasHeight * stageFrame.height,
                width: node.width / PaceDiagramDocument.canvasWidth * stageFrame.width,
                height: node.height / PaceDiagramDocument.canvasHeight * stageFrame.height
            )
            let panel = nodePanels[node.id] ?? PaceDiagramIslandPanel()
            panel.contentView = NSHostingView(rootView: PaceDiagramNodeView(controller: controller, node: node))
            panel.setFrame(nodeFrame, display: true)
            panel.orderFrontRegardless()
            nodePanels[node.id] = panel
        }
        refreshSelection()
        installEscapeMonitorsIfNeeded()
    }

    func refreshSelection() {
        guard let controller, let document = controller.document else { return }
        let panel = detailPanel ?? PaceDiagramIslandPanel()
        let width = min(450, visibleFrame.width - 64)
        let height: CGFloat = controller.selectedNode == nil ? 76 : 174
        panel.contentView = NSHostingView(rootView: PaceDiagramDetailView(controller: controller, summary: document.summary))
        panel.setFrame(CGRect(
            x: visibleFrame.midX - width / 2,
            y: max(visibleFrame.minY + 24, stageFrame.minY - height - 10),
            width: width, height: height
        ), display: true)
        panel.orderFrontRegardless()
        detailPanel = panel
    }

    func hide() {
        let panels = Array(nodePanels.values) + [drawingPanel, headerPanel, detailPanel].compactMap { $0 }
        for panel in panels {
            panel.orderOut(nil)
            panel.contentView = nil
            panel.close()
        }
        nodePanels.removeAll()
        drawingPanel = nil
        headerPanel = nil
        detailPanel = nil
        if let localKeyMonitor { NSEvent.removeMonitor(localKeyMonitor) }
        if let globalKeyMonitor { NSEvent.removeMonitor(globalKeyMonitor) }
        localKeyMonitor = nil
        globalKeyMonitor = nil
    }

    private func targetScreen() -> NSScreen? {
        if let displayIdentifier,
           let screen = NSScreen.screens.first(where: {
               $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber == displayIdentifier
           }) { return screen }
        return NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main
    }

    private func installEscapeMonitorsIfNeeded() {
        guard localKeyMonitor == nil else { return }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            Task { @MainActor in self?.dismissForEscapeIfPointerIsOverDiagram() }
            return event
        }
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return }
            Task { @MainActor in self?.dismissForEscapeIfPointerIsOverDiagram() }
        }
    }

    private func dismissForEscapeIfPointerIsOverDiagram() {
        let frames = [stageFrame, headerPanel?.frame, detailPanel?.frame].compactMap { $0 }
        guard Self.shouldDismissForEscape(pointerLocation: NSEvent.mouseLocation, diagramFrames: frames) else { return }
        controller?.dismiss()
    }

    static func shouldDismissForEscape(pointerLocation: CGPoint, diagramFrames: [CGRect]) -> Bool {
        diagramFrames.contains { $0.contains(pointerLocation) }
    }
}

@MainActor
private final class PaceDiagramIslandPanel: NSPanel {
    init(ignoresMouseEvents: Bool = false) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        isFloatingPanel = true
        self.ignoresMouseEvents = ignoresMouseEvents
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        animationBehavior = .none
        setAccessibilityLabel("Pace diagram")
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct PaceDiagramNodeView: View {
    @ObservedObject var controller: PaceDiagramOverlayController
    let node: PaceDiagramNode
    @State private var isHovered = false
    @State private var hasAppeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isSelected: Bool { controller.selectedNodeID == node.id }

    var body: some View {
        GeometryReader { geometry in
            Button {
                controller.selectNode(id: node.id)
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    if geometry.size.height >= 90 {
                        Text((node.role?.rawValue ?? "concept").uppercased())
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .tracking(1.5)
                            .foregroundStyle(Color(hex: "#8CA9D1"))
                    }
                    Text(node.label)
                        .font(DS.Typography.headline)
                        .foregroundStyle(DS.Colors.textPrimary)
                        .lineLimit(geometry.size.height < 65 ? 2 : 3)
                        .minimumScaleFactor(1)
                        .multilineTextAlignment(.leading)
                    if geometry.size.height >= 110, let subtitle = node.subtitle {
                        Text(subtitle)
                            .font(DS.Typography.caption)
                            .foregroundStyle(Color(hex: "#9DAFC6"))
                            .lineLimit(2)
                    }
                }
                .padding(geometry.size.height < 65 ? 10 : 16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .background {
                    PaceDiagramNodeOutline(shape: node.shape ?? .rectangle)
                        .fill(LinearGradient(
                            colors: [Color(hex: isSelected ? "#223754" : "#182333"), Color(hex: "#101820")],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        ))
                }
                .overlay {
                    PaceDiagramNodeOutline(shape: node.shape ?? .rectangle)
                        .stroke(Color(hex: isSelected || isHovered ? "#80ABEC" : "#405B7F").opacity(isSelected ? 1 : 0.8), lineWidth: isSelected ? 1.5 : 1)
                }
                .contentShape(PaceDiagramNodeOutline(shape: node.shape ?? .rectangle))
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .onHover { isHovered = $0 }
            .opacity(hasAppeared ? 1 : 0)
            .onAppear {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.24)) { hasAppeared = true }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: isHovered)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: isSelected)
            .accessibilityLabel(node.label)
            .accessibilityValue(isSelected ? "selected" : "")
            .accessibilityHint("Select to read the explanation and ask Pace about this part")
            .accessibilityIdentifier("pace.diagram.part.\(node.id)")
        }
    }
}

private struct PaceDiagramNodeOutline: Shape {
    let shape: PaceDiagramNode.Shape

    func path(in rect: CGRect) -> Path {
        switch shape {
        case .rectangle: RoundedRectangle(cornerRadius: 14).path(in: rect)
        case .ellipse: Ellipse().path(in: rect)
        case .capsule: Capsule().path(in: rect)
        }
    }
}

private struct PaceDiagramConnectionsView: View {
    @ObservedObject var controller: PaceDiagramOverlayController

    var body: some View {
        Canvas { context, size in
            guard let document = controller.document else { return }
            let nodesByID = Dictionary(uniqueKeysWithValues: document.nodes.map { ($0.id, $0) })
            for connection in document.connections {
                guard let source = nodesByID[connection.source], let target = nodesByID[connection.target] else { continue }
                let horizontal = abs(target.x - source.x) >= abs(target.y - source.y)
                let forward = horizontal ? target.x > source.x : target.y > source.y
                let start = CGPoint(
                    x: (horizontal ? source.x + (forward ? source.width : 0) : source.x + source.width / 2) / 1000 * size.width,
                    y: (horizontal ? source.y + source.height / 2 : source.y + (forward ? source.height : 0)) / 600 * size.height
                )
                let end = CGPoint(
                    x: (horizontal ? target.x + (forward ? 0 : target.width) : target.x + target.width / 2) / 1000 * size.width,
                    y: (horizontal ? target.y + target.height / 2 : target.y + (forward ? 0 : target.height)) / 600 * size.height
                )
                let controlOffset = horizontal ? (end.x - start.x) / 2 : (end.y - start.y) / 2
                var path = Path()
                path.move(to: start)
                path.addCurve(
                    to: end,
                    control1: CGPoint(x: start.x + (horizontal ? controlOffset : 0), y: start.y + (horizontal ? 0 : controlOffset)),
                    control2: CGPoint(x: end.x - (horizontal ? controlOffset : 0), y: end.y - (horizontal ? 0 : controlOffset))
                )
                let isSelected = controller.selectedNodeID == connection.source || controller.selectedNodeID == connection.target
                let color = Color(hex: isSelected ? "#B2CFF8" : "#7395C3")
                context.stroke(path, with: .color(color.opacity(isSelected ? 1 : 0.72)), lineWidth: isSelected ? 1.8 : 1.2)
                let direction: CGFloat = forward ? 1 : -1
                var arrow = Path()
                arrow.move(to: CGPoint(x: end.x - (horizontal ? 7 * direction : -4), y: end.y - (horizontal ? 4 : 7 * direction)))
                arrow.addLine(to: end)
                arrow.addLine(to: CGPoint(x: end.x - (horizontal ? 7 * direction : 4), y: end.y + (horizontal ? 4 : -7 * direction)))
                context.stroke(arrow, with: .color(color), style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
                if let label = connection.label {
                    let text = Text(label).font(.system(size: 10, weight: .medium)).foregroundColor(Color(hex: "#C1CEE0"))
                    let position = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2 - 13)
                    let resolvedText = context.resolve(text)
                    let bounds = resolvedText.measure(in: CGSize(width: 170, height: 36))
                    context.fill(Path(roundedRect: CGRect(x: position.x - bounds.width / 2 - 5, y: position.y - bounds.height / 2 - 3, width: bounds.width + 10, height: bounds.height + 6), cornerRadius: 4), with: .color(Color(hex: "#101820").opacity(0.94)))
                    context.draw(resolvedText, at: position)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct PaceDiagramHeaderView: View {
    @ObservedObject var controller: PaceDiagramOverlayController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .foregroundStyle(Color(hex: "#A6C5F0"))
                Text("pace is explaining").font(DS.Typography.callout)
                Spacer()
                Button("Next part", systemImage: "arrow.right") { controller.selectNextNode() }
                    .labelStyle(.iconOnly)
                    .help("Select the next diagram part")
                Button("Close diagram", systemImage: "xmark") { controller.dismiss() }
                    .labelStyle(.iconOnly)
                    .help("Close diagram · Escape while hovering the diagram")
                    .accessibilityIdentifier("pace.diagram.close")
            }
            .font(.system(size: 12))
            Text(controller.document?.title ?? "")
                .font(DS.Typography.sceneTitle)
                .lineLimit(2)
        }
        .foregroundStyle(DS.Colors.textPrimary)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(hex: "#0C1117").opacity(0.92), in: RoundedRectangle(cornerRadius: 15))
        .buttonStyle(DiagramQuietButtonStyle())
    }
}

private struct PaceDiagramDetailView: View {
    @ObservedObject var controller: PaceDiagramOverlayController
    let summary: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let node = controller.selectedNode {
                HStack {
                    Text("SELECTED · \(node.label)")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .tracking(1)
                        .foregroundStyle(Color(hex: "#9DB7DA"))
                        .lineLimit(1)
                    Spacer()
                    Button("Next part", systemImage: "arrow.right") { controller.selectNextNode() }
                        .labelStyle(.iconOnly)
                }
                ScrollView {
                    Text(node.detail)
                        .font(DS.Typography.body)
                        .foregroundStyle(DS.Colors.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                HStack {
                    Text("Keep talking to change the diagram.")
                        .font(.system(size: 10))
                        .foregroundStyle(DS.Colors.textSecondary)
                    Spacer()
                    Button("Explain this", systemImage: "waveform") { controller.askAboutSelectedNode() }
                        .font(DS.Typography.callout)
                        .accessibilityIdentifier("pace.diagram.explain")
                }
            } else {
                Text(summary).font(DS.Typography.callout).lineLimit(2)
                Text("Select a part. Hover here and press Escape to close.")
                    .font(.system(size: 10))
                    .foregroundStyle(DS.Colors.textSecondary)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(hex: "#101318").opacity(0.98), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.white.opacity(0.12), lineWidth: 1))
        .foregroundStyle(DS.Colors.textPrimary)
        .buttonStyle(DiagramQuietButtonStyle())
    }
}

private struct DiagramQuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        DiagramQuietButtonBody(label: configuration.label, isPressed: configuration.isPressed)
    }
}

private struct DiagramQuietButtonBody: View {
    let label: ButtonStyleConfiguration.Label
    let isPressed: Bool
    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        label
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color.white.opacity(isPressed ? 0.14 : isHovered ? 0.09 : 0.035), in: RoundedRectangle(cornerRadius: 7))
            .opacity(isEnabled ? 1 : 0.4)
            .pointerCursor(isEnabled: isEnabled)
            .onHover { isHovered = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: isHovered)
    }
}
