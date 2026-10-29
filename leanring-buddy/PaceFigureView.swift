import AppKit
import Combine
import RealityKit
import SwiftUI

@MainActor
struct PaceFigureAssembly {
    let root: Entity
    let selectableEntities: [ModelEntity]
    let movingSurfaces: [PaceFigureControlSurface]
}

@MainActor
struct PaceFigureControlSurface {
    let entity: Entity
    let restingOrientation: simd_quatf
    let axis: SIMD3<Float>
    let maximumAngle: Float
    let nodeID: String
    let direction: Float
}

@MainActor
struct PaceFigureView: View {
    @ObservedObject var controller: PaceDiagramOverlayController
    @StateObject private var model = PaceFigureViewModel()
    @State private var controlValue = 0.0
    @State private var zoom: Float = 1
    @State private var showsLabels = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 12) {
            PaceFigureRenderer(
                model: model, document: controller.document, selectedNodeID: controller.selectedNodeID,
                controlValue: Float(controlValue), zoom: zoom, animated: !reduceMotion,
                selectPart: controller.selectNode
            )
            .onHover { hovering in
                if hovering { NSCursor.openHand.set() } else { NSCursor.arrow.set() }
            }
            .accessibilityLabel(
                "Interactive three-dimensional figure. Drag to orbit; use the controls to explore parts."
            )
            .overlay {
                if showsLabels {
                    PaceFigureCalloutsView(
                        nodes: controller.document?.nodes ?? [], points: model.projectedAnchors,
                        selectedNodeID: controller.selectedNodeID,
                        isAircraft: controller.document?.figure?.template == .airplane,
                        selectPart: controller.selectNode
                    )
                }
            }
            .overlay {
                if let renderingError = model.renderingError {
                    Text(renderingError)
                        .font(DS.Typography.body)
                        .foregroundStyle(DS.Colors.textPrimary)
                        .padding(20)
                        .background(Color(hex: "#11151C"), in: RoundedRectangle(cornerRadius: 14))
                }
            }

            HStack(spacing: 8) {
                Menu {
                    ForEach(controller.document?.nodes ?? []) { node in
                        Button(node.label) { controller.selectNode(id: node.id) }
                    }
                } label: {
                    Label(controller.selectedNode?.label ?? "Explore a part", systemImage: "viewfinder")
                        .lineLimit(1)
                }
                .menuStyle(.borderlessButton)
                .frame(maxWidth: 150)
                .pointerCursor()
                .help("Select a physical part to read its explanation")

                Divider().frame(height: 18)
                figureButton("Rotate left", symbol: "rotate.left") { model.rotate(by: -.pi / 6) }
                figureButton("Rotate right", symbol: "rotate.right") { model.rotate(by: .pi / 6) }
                figureButton("Zoom out", symbol: "minus.magnifyingglass") { zoom = max(0.55, zoom / 1.15) }
                figureButton("Zoom in", symbol: "plus.magnifyingglass") { zoom = min(1.8, zoom * 1.15) }
                figureButton("Reset view", symbol: "arrow.counterclockwise") {
                    zoom = 1
                    controlValue = 0
                    model.resetOrientation()
                }
                figureButton(showsLabels ? "Hide part labels" : "Show part labels", symbol: "tag") {
                    showsLabels.toggle()
                }
                if model.hasMovingSurfaces {
                    Divider().frame(height: 18)
                    Text("Deflection")
                        .font(DS.Typography.caption)
                        .foregroundStyle(DS.Colors.textSecondary)
                    Slider(value: $controlValue, in: -1...1)
                        .frame(width: 80)
                        .accessibilityLabel("Control surface deflection")
                        .help("Move the airplane's ailerons, elevators, rudder and flaps")
                        .onHover { hovering in if hovering { NSCursor.pointingHand.set() } }
                }
            }
            .font(DS.Typography.caption)
            .foregroundStyle(DS.Colors.textPrimary)
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .background(Color(hex: "#11151C").opacity(0.97), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.09), lineWidth: 1))
        }
        .onChange(of: controller.selectedNodeID) { _, _ in controlValue = 0 }
        .onDisappear { model.stopProjection() }
    }

    private func figureButton(_ label: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 24, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .help(label)
        .accessibilityLabel(label)
    }
}

// macOS RealityView supplies an opaque environment and automatic framing. The AppKit
// RealityKit surface gives this desktop overlay explicit alpha and camera control.
@MainActor
private struct PaceFigureRenderer: NSViewRepresentable {
    let model: PaceFigureViewModel
    let document: PaceDiagramDocument?
    let selectedNodeID: String?
    let controlValue: Float
    let zoom: Float
    let animated: Bool
    let selectPart: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(model: model, selectPart: selectPart) }

    func makeNSView(context: Context) -> ARView {
        let view = ARView(frame: .zero)
        view.environment.background = .color(.clear)
        view.wantsLayer = true
        view.layer?.isOpaque = false
        view.layer?.backgroundColor = NSColor.clear.cgColor
        let world = AnchorEntity(world: .zero)
        world.addChild(model.sceneRoot)
        let camera = PerspectiveCamera()
        camera.camera.fieldOfViewInDegrees = 35
        camera.look(at: .zero, from: [0, 0, 2.6], relativeTo: nil)
        world.addChild(camera)
        for light in model.makeLights() { world.addChild(light) }
        view.scene.addAnchor(world)
        model.update(document: document, selectedNodeID: selectedNodeID)
        model.startProjection(view: view)
        view.addGestureRecognizer(
            NSPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.drag(_:))))
        view.addGestureRecognizer(
            NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pick(_:))))
        return view
    }

    func updateNSView(_ view: ARView, context: Context) {
        model.update(document: document, selectedNodeID: selectedNodeID)
        model.setControlValue(controlValue, animated: animated)
        model.setZoom(zoom)
        context.coordinator.selectPart = selectPart
    }

    static func dismantleNSView(_ view: ARView, coordinator: Coordinator) {
        coordinator.model.stopProjection()
        view.scene.anchors.removeAll()
    }

    @MainActor
    final class Coordinator: NSObject {
        let model: PaceFigureViewModel
        var selectPart: (String) -> Void

        init(model: PaceFigureViewModel, selectPart: @escaping (String) -> Void) {
            self.model = model
            self.selectPart = selectPart
        }

        @objc func drag(_ gesture: NSPanGestureRecognizer) {
            guard let view = gesture.view else { return }
            let translation = gesture.translation(in: view)
            model.orbit(horizontal: Float(translation.x) * 0.008, vertical: Float(-translation.y) * 0.008)
            gesture.setTranslation(.zero, in: view)
            NSCursor.closedHand.set()
            if gesture.state == .ended || gesture.state == .cancelled { NSCursor.openHand.set() }
        }

        @objc func pick(_ gesture: NSClickGestureRecognizer) {
            guard let view = gesture.view as? ARView,
                let entity = view.entity(at: gesture.location(in: view))
            else { return }
            selectPart(entity.name)
        }
    }
}

private struct PaceFigureCalloutsView: View {
    let nodes: [PaceDiagramNode]
    let points: [String: CGPoint]
    let selectedNodeID: String?
    let isAircraft: Bool
    let selectPart: (String) -> Void
    @State private var labelPositions: [String: CGPoint] = [:]

    var body: some View {
        GeometryReader { geometry in
            let labelWidth = min(150, max(100, geometry.size.width * 0.19))
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    for node in nodes {
                        guard let anchor = points[node.id], let label = labelPositions[node.id] else { continue }
                        let isLeft = label.x < geometry.size.width / 2
                        let start = CGPoint(x: label.x + (isLeft ? labelWidth / 2 : -labelWidth / 2), y: label.y)
                        var leader = Path()
                        leader.move(to: start)
                        leader.addLine(to: anchor)
                        let selected = selectedNodeID == node.id
                        context.stroke(
                            leader, with: .color(Color(hex: selected ? "#A5D1FF" : "#70A8E4")),
                            lineWidth: selected ? 1.5 : 1)
                        let dot = CGRect(x: anchor.x - 3, y: anchor.y - 3, width: 6, height: 6)
                        context.fill(Path(ellipseIn: dot), with: .color(Color(hex: "#71B0FA")))
                        context.stroke(Path(ellipseIn: dot), with: .color(.white), lineWidth: 1)
                    }
                }
                .allowsHitTesting(false)

                ForEach(Array(nodes.enumerated()), id: \.element.id) { index, node in
                    if let position = labelPositions[node.id], points[node.id] != nil {
                        Button {
                            selectPart(node.id)
                        } label: {
                            HStack(alignment: .top, spacing: 7) {
                                Text("\(index + 1)")
                                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                                    .frame(width: 20, height: 20)
                                    .background(Color(hex: "#2588F0"), in: Circle())
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(node.label).font(.system(size: 11, weight: .semibold)).lineLimit(2)
                                    if let role = node.subtitle ?? (isAircraft ? Self.aircraftRoles[node.id] : nil) {
                                        Text(role).font(.system(size: 9)).foregroundStyle(Color(hex: "#B9C5D2"))
                                            .lineLimit(2)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .foregroundStyle(.white)
                            .padding(8)
                            .frame(width: labelWidth, alignment: .leading)
                            .background(Color(hex: "#141C26").opacity(0.97), in: RoundedRectangle(cornerRadius: 10))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10).strokeBorder(
                                    Color(hex: selectedNodeID == node.id ? "#9CC9FC" : "#61778E"), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .pointerCursor()
                        .help(node.detail)
                        .accessibilityLabel("\(node.label). Select to explore this physical part.")
                        .position(position)
                    }
                }
            }
            .onChange(of: points, initial: true) { _, _ in
                if labelPositions.isEmpty { arrangeLabels(size: geometry.size, labelWidth: labelWidth) }
            }
            .onChange(of: geometry.size) { _, newSize in arrangeLabels(size: newSize, labelWidth: labelWidth) }
            .onChange(of: nodes.map(\.id)) { _, _ in arrangeLabels(size: geometry.size, labelWidth: labelWidth) }
        }
    }

    private func arrangeLabels(size: CGSize, labelWidth: CGFloat) {
        let visibleNodes = nodes.filter { points[$0.id] != nil }.sorted {
            points[$0.id]!.x < points[$1.id]!.x
        }
        guard !visibleNodes.isEmpty else { return }
        let leftCount = (visibleNodes.count + 1) / 2
        var positions: [String: CGPoint] = [:]
        for (side, group) in [Array(visibleNodes.prefix(leftCount)), Array(visibleNodes.dropFirst(leftCount))]
            .enumerated()
        {
            let ordered = group.sorted { points[$0.id]!.y < points[$1.id]!.y }
            for (row, node) in ordered.enumerated() {
                let verticalFraction = CGFloat(row + 1) / CGFloat(ordered.count + 1)
                positions[node.id] = CGPoint(
                    x: side == 0 ? labelWidth / 2 + 8 : size.width - labelWidth / 2 - 8,
                    y: 16 + (size.height - 32) * verticalFraction)
            }
        }
        labelPositions = positions
    }

    private static let aircraftRoles = [
        "cockpit": "Pilot controls", "fuselage": "Passengers and cargo", "wings": "Generate lift",
        "engines": "Produce thrust", "ailerons": "Control roll", "flaps": "Increase lift and drag",
        "elevators": "Control pitch", "rudder": "Controls yaw",
    ]
}

@MainActor
private final class PaceFigureViewModel: ObservableObject {
    let sceneRoot = Entity()
    @Published private(set) var renderingError: String?
    @Published private(set) var hasMovingSurfaces = false
    @Published private(set) var projectedAnchors: [String: CGPoint] = [:]
    private var anchors: [String: [Entity]] = [:]
    private var projectionSubscription: (any Cancellable)?
    private var currentScene: PaceFigureScene?
    private var assembly: PaceFigureAssembly?
    private var originalMaterials: [ObjectIdentifier: [any RealityKit.Material]] = [:]
    private var selectedNodeID: String?
    private var previousControlValue: Float = .nan
    private var previousZoom: Float = .nan

    func update(document: PaceDiagramDocument?, selectedNodeID: String?) {
        guard let scene = document?.figure else { return }
        if assembly == nil || currentScene?.template != scene.template || currentScene?.parts != scene.parts {
            do {
                let isFirstPresentation = assembly == nil
                let assembly =
                    try scene.template == .airplane
                    ? PaceAircraftFigureBuilder.makeAssembly() : Self.makeCustomAssembly(scene)
                sceneRoot.children.removeAll()
                let bounds = assembly.root.visualBounds(relativeTo: nil)
                let largestDimension = max(bounds.extents.x, bounds.extents.y, bounds.extents.z)
                guard largestDimension.isFinite, largestDimension > 0 else {
                    throw FigureRenderingError.emptyGeometry
                }
                let scale = 1.8 / largestDimension
                assembly.root.scale *= scale
                assembly.root.position -= bounds.center * scale
                sceneRoot.addChild(assembly.root)
                self.assembly = assembly
                anchors.removeAll()
                for entity in assembly.selectableEntities {
                    let anchor = Entity()
                    anchor.name = entity.name
                    anchor.position = entity.visualBounds(relativeTo: entity).center
                    entity.addChild(anchor)
                    anchors[entity.name, default: []].append(anchor)
                }
                projectedAnchors = [:]
                originalMaterials = Dictionary(
                    uniqueKeysWithValues: assembly.selectableEntities.map {
                        (ObjectIdentifier($0), $0.model?.materials ?? [])
                    })
                currentScene = scene
                self.selectedNodeID = nil
                previousControlValue = .nan
                previousZoom = .nan
                hasMovingSurfaces = !assembly.movingSurfaces.isEmpty
                renderingError = nil
                if isFirstPresentation { resetOrientation() }
            } catch {
                renderingError = "I couldn't render this object. Ask Pace to simplify its geometry."
                return
            }
        }
        guard self.selectedNodeID != selectedNodeID, let assembly else { return }
        self.selectedNodeID = selectedNodeID
        for entity in assembly.selectableEntities {
            if entity.name == selectedNodeID {
                entity.model?.materials = [
                    SimpleMaterial(color: NSColor(Color(hex: "#79A9DF")), roughness: 0.32, isMetallic: true)
                ]
            } else if let materials = originalMaterials[ObjectIdentifier(entity)] {
                entity.model?.materials = materials
            }
        }
    }

    func startProjection(view: ARView) {
        stopProjection()
        projectionSubscription = view.scene.subscribe(to: SceneEvents.Update.self) { [weak self, weak view] _ in
            guard let self, let view else { return }
            var points: [String: CGPoint] = [:]
            for (identifier, candidates) in anchors {
                // Repeated parts share one explanation. Attach its leader to the
                // nearest instance as the object turns, rather than an obscured twin.
                guard
                    let anchor = candidates.max(by: {
                        $0.position(relativeTo: nil).z < $1.position(relativeTo: nil).z
                    })
                else { continue }
                if let point = view.project(anchor.position(relativeTo: nil)),
                    point.x.isFinite, point.y.isFinite
                {
                    // ARView projects into AppKit's bottom-left viewport; SwiftUI
                    // callouts use a top-left origin in the same view bounds.
                    points[identifier] = CGPoint(x: point.x, y: view.bounds.height - point.y)
                }
            }
            let moved =
                points.count != projectedAnchors.count
                || points.contains { identifier, point in
                    guard let previous = self.projectedAnchors[identifier] else { return true }
                    return hypot(point.x - previous.x, point.y - previous.y) > 0.4
                }
            if moved { projectedAnchors = points }
        }
    }

    func stopProjection() {
        projectionSubscription?.cancel()
        projectionSubscription = nil
    }

    func setControlValue(_ value: Float, animated: Bool) {
        guard previousControlValue != value, let assembly else { return }
        previousControlValue = value
        let focusedControlNodeID =
            assembly.movingSurfaces.contains(where: { $0.nodeID == selectedNodeID })
            ? selectedNodeID : nil
        for surface in assembly.movingSurfaces {
            let isFocused = focusedControlNodeID == nil || focusedControlNodeID == surface.nodeID
            let angle = isFocused ? surface.maximumAngle * value * surface.direction : 0
            var transform = surface.entity.transform
            transform.rotation = simd_quatf(angle: angle, axis: surface.axis) * surface.restingOrientation
            surface.entity.move(to: transform, relativeTo: surface.entity.parent, duration: animated ? 0.16 : 0)
        }
    }

    func setZoom(_ zoom: Float) {
        guard previousZoom != zoom else { return }
        previousZoom = zoom
        sceneRoot.scale = SIMD3(repeating: zoom)
    }

    func rotate(by angle: Float) {
        sceneRoot.orientation = simd_quatf(angle: angle, axis: [0, 1, 0]) * sceneRoot.orientation
    }

    func orbit(horizontal: Float, vertical: Float) {
        sceneRoot.orientation =
            simd_quatf(angle: vertical, axis: [1, 0, 0])
            * simd_quatf(angle: horizontal, axis: [0, 1, 0]) * sceneRoot.orientation
    }

    func resetOrientation() {
        sceneRoot.orientation =
            simd_quatf(angle: .pi / 7, axis: [1, 0, 0])
            * simd_quatf(angle: -.pi / 5, axis: [0, 1, 0])
    }

    func makeLights() -> [Entity] {
        let keyLight = DirectionalLight()
        keyLight.light.intensity = 2600
        keyLight.look(at: .zero, from: [3, 5, 4], relativeTo: nil)
        let fillLight = PointLight()
        fillLight.light.intensity = 1400
        fillLight.light.attenuationRadius = 20
        fillLight.position = [-3, 2, -3]
        return [keyLight, fillLight]
    }

    private static func makeCustomAssembly(_ scene: PaceFigureScene) throws -> PaceFigureAssembly {
        let root = Entity()
        var selectableEntities: [ModelEntity] = []
        for part in scene.parts ?? [] {
            let mesh: MeshResource
            switch part.geometry {
            case .box: mesh = .generateBox(size: 1, cornerRadius: 0.045)
            case .ellipsoid: mesh = .generateSphere(radius: 0.5)
            case .cylinder: mesh = .generateCylinder(height: 1, radius: 0.5)
            case .cone: mesh = .generateCone(height: 1, radius: 0.5)
            case .mesh:
                var descriptor = MeshDescriptor(name: part.id)
                descriptor.positions = MeshBuffers.Positions((part.vertices ?? []).map(vector))
                descriptor.primitives = .triangles((part.triangles ?? []).map(UInt32.init))
                mesh = try .generate(from: [descriptor])
            }
            let material = material(for: part.finish ?? .shell)
            let entity = ModelEntity(mesh: mesh, materials: [material])
            entity.name = part.nodeID
            entity.position = vector(part.position)
            entity.scale = vector(part.size)
            if let rotation = part.rotation {
                entity.orientation =
                    simd_quatf(angle: Float(rotation[2]) * .pi / 180, axis: [0, 0, 1])
                    * simd_quatf(angle: Float(rotation[1]) * .pi / 180, axis: [0, 1, 0])
                    * simd_quatf(angle: Float(rotation[0]) * .pi / 180, axis: [1, 0, 0])
            }
            entity.generateCollisionShapes(recursive: false)
            entity.components.set(InputTargetComponent())
            root.addChild(entity)
            selectableEntities.append(entity)
        }
        return PaceFigureAssembly(root: root, selectableEntities: selectableEntities, movingSurfaces: [])
    }

    private static func vector(_ coordinates: [Double]) -> SIMD3<Float> {
        SIMD3(Float(coordinates[0]), Float(coordinates[1]), Float(coordinates[2]))
    }

    private static func material(for finish: PaceFigureScene.Finish) -> SimpleMaterial {
        switch finish {
        case .shell: SimpleMaterial(color: NSColor(Color(hex: "#DCE1E6")), roughness: 0.3, isMetallic: false)
        case .metal: SimpleMaterial(color: NSColor(Color(hex: "#A6B2C2")), roughness: 0.24, isMetallic: true)
        case .glass: SimpleMaterial(color: NSColor(Color(hex: "#15304B")), roughness: 0.12, isMetallic: true)
        case .accent: SimpleMaterial(color: NSColor(Color(hex: "#79A9DF")), roughness: 0.32, isMetallic: true)
        case .dark: SimpleMaterial(color: NSColor(Color(hex: "#222A35")), roughness: 0.65, isMetallic: false)
        }
    }

    private enum FigureRenderingError: Error { case emptyGeometry }
}
