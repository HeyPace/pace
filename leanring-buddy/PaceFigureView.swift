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
    @State private var zoom: Float = 1
    @State private var showsLabels = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 12) {
            PaceFigureRenderer(
                model: model, document: controller.document, selectedNodeID: controller.selectedNodeID,
                revision: controller.revision, controlValue: Float(controller.controlDeflection),
                zoom: zoom, animated: !reduceMotion,
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

            VStack(spacing: 8) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        partNavigation
                        exploreSelectedPartButton
                    }
                    VStack(spacing: 8) {
                        partNavigation
                        exploreSelectedPartButton
                    }
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        viewControls
                        if model.hasMovingSurfaces {
                            Divider().frame(height: 18)
                            deflectionControl
                        }
                    }
                    VStack(spacing: 8) {
                        viewControls
                        if model.hasMovingSurfaces { deflectionControl }
                    }
                }
            }
            .font(DS.Typography.caption)
            .foregroundStyle(DS.Colors.textPrimary)
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .background(Color(hex: "#11151C").opacity(0.97), in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.09), lineWidth: 1))
        }
        .onDisappear { model.stopProjection() }
    }

    private var partNavigation: some View {
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
            .paceControlHoverHighlight(cornerRadius: 6)
            .pointerCursor()
            .help("Select a physical part to read its explanation")

            figureButton("Next part", symbol: "arrow.right") { controller.selectNextNode() }
                .disabled(controller.document?.nodes.isEmpty ?? true)
                .help("Select the next part locally without starting an explanation")
                .accessibilityIdentifier("pace.figure.next-part")
        }
    }

    private var exploreSelectedPartButton: some View {
        Button {
            controller.askAboutSelectedNode()
        } label: {
            Label("Explore this part", systemImage: "arrow.up.right")
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!controller.canAskAboutSelectedNode)
        .opacity(controller.canAskAboutSelectedNode ? 1 : 0.4)
        .paceControlHoverHighlight(cornerRadius: 7, isEnabled: controller.canAskAboutSelectedNode)
        .pointerCursor(isEnabled: controller.canAskAboutSelectedNode)
        .help("Explain the selected part and update the diagram if a closer view would help")
        .accessibilityIdentifier("pace.figure.explore-part")
    }

    private var viewControls: some View {
        HStack(spacing: 8) {
            figureButton("Rotate left", symbol: "rotate.left") { model.rotate(by: -.pi / 6) }
            figureButton("Rotate right", symbol: "rotate.right") { model.rotate(by: .pi / 6) }
            figureButton("Zoom out", symbol: "minus.magnifyingglass") { zoom = max(0.55, zoom / 1.15) }
            figureButton("Zoom in", symbol: "plus.magnifyingglass") { zoom = min(1.8, zoom * 1.15) }
            figureButton("Reset view", symbol: "arrow.counterclockwise") {
                zoom = 1
                controller.setControlDeflection(0)
                model.resetOrientation()
            }
            figureButton(showsLabels ? "Hide part labels" : "Show part labels", symbol: "tag") {
                showsLabels.toggle()
            }
        }
    }

    private var deflectionControl: some View {
        HStack(spacing: 8) {
            Text("Deflection")
                .foregroundStyle(DS.Colors.textSecondary)
            Slider(
                value: Binding(get: { controller.controlDeflection }, set: controller.setControlDeflection),
                in: -1...1
            )
                .frame(width: 80)
                .accessibilityLabel("Control surface deflection")
                .help("Move the airplane's ailerons, elevators, rudder and flaps")
                .onHover { hovering in if hovering { NSCursor.pointingHand.set() } }
        }
    }

    private func figureButton(_ label: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 24, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .paceControlHoverHighlight(cornerRadius: 6)
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
    let revision: Int
    let controlValue: Float
    let zoom: Float
    let animated: Bool
    let selectPart: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(model: model, selectPart: selectPart) }

    func makeNSView(context: Context) -> ARView {
        let view = PaceFigureARView(frame: .zero)
        view.onViewportSizeChanged = { [weak model] viewportSize in
            model?.updateViewportSize(viewportSize)
        }
        view.environment.background = .color(.clear)
        view.wantsLayer = true
        view.layer?.isOpaque = false
        view.layer?.backgroundColor = NSColor.clear.cgColor
        let world = AnchorEntity(world: .zero)
        world.addChild(model.sceneRoot)
        let camera = PerspectiveCamera()
        camera.camera.fieldOfViewInDegrees = PaceFigureCameraFraming.verticalFieldOfViewInDegrees
        camera.camera.fieldOfViewOrientation = .vertical
        camera.look(at: .zero, from: [0, 0, PaceFigureCameraFraming.minimumCameraDistance], relativeTo: nil)
        model.configureCamera(camera, viewportSize: view.bounds.size)
        world.addChild(camera)
        for light in model.makeLights() { world.addChild(light) }
        view.scene.addAnchor(world)
        model.update(document: document, selectedNodeID: selectedNodeID, revision: revision)
        model.setControlValue(controlValue, animated: false)
        model.setZoom(zoom)
        model.startProjection(view: view)
        view.addGestureRecognizer(
            NSPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.drag(_:))))
        view.addGestureRecognizer(
            NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pick(_:))))
        return view
    }

    func updateNSView(_ view: ARView, context: Context) {
        model.update(document: document, selectedNodeID: selectedNodeID, revision: revision)
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

@MainActor
private final class PaceFigureARView: ARView {
    var onViewportSizeChanged: ((CGSize) -> Void)?

    override func layout() {
        super.layout()
        onViewportSizeChanged?(bounds.size)
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
                        if selected {
                            let reticle = CGRect(x: anchor.x - 7, y: anchor.y - 7, width: 14, height: 14)
                            context.stroke(
                                Path(ellipseIn: reticle), with: .color(Color(hex: "#C6E1FF")), lineWidth: 1.2)
                        }
                        let dotSize: CGFloat = selected ? 3 : 6
                        let dot = CGRect(
                            x: anchor.x - dotSize / 2, y: anchor.y - dotSize / 2,
                            width: dotSize, height: dotSize)
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
    private var appliedViewpointRevision: Int?
    private var assembly: PaceFigureAssembly?
    private var originalMaterials: [ObjectIdentifier: [any RealityKit.Material]] = [:]
    private var selectedNodeID: String?
    private var previousControlValue: Float = .nan
    private var previousZoom: Float = .nan
    private weak var framingCamera: PerspectiveCamera?
    private var framingBounds: PaceFigureCameraFraming.Bounds?
    private var viewportSize = CGSize.zero

    func configureCamera(_ camera: PerspectiveCamera, viewportSize: CGSize) {
        framingCamera = camera
        self.viewportSize = viewportSize
        refreshCameraFraming()
    }

    func updateViewportSize(_ viewportSize: CGSize) {
        guard self.viewportSize != viewportSize else { return }
        self.viewportSize = viewportSize
        refreshCameraFraming()
    }

    func update(document: PaceDiagramDocument?, selectedNodeID: String?, revision: Int) {
        guard let scene = document?.figure else { return }
        if assembly == nil || currentScene?.hasSameGeometry(as: scene) != true {
            do {
                let isFirstPresentation = assembly == nil
                let assembly =
                    try scene.template == .airplane
                    ? PaceAircraftFigureBuilder.makeAssembly() : Self.makeCustomAssembly(scene)
                let bounds = assembly.root.visualBounds(relativeTo: nil)
                let largestDimension = max(bounds.extents.x, bounds.extents.y, bounds.extents.z)
                guard largestDimension.isFinite, largestDimension > 0 else {
                    throw FigureRenderingError.emptyGeometry
                }
                let scale = 1.8 / largestDimension
                assembly.root.scale *= scale
                assembly.root.position -= bounds.center * scale
                sceneRoot.children.removeAll()
                sceneRoot.addChild(assembly.root)
                self.assembly = assembly
                cacheFramingBounds(for: assembly)
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
                if isFirstPresentation { resetOrientation() } else { refreshCameraFraming() }
            } catch {
                renderingError = "I couldn't render this object. Ask Pace to simplify its geometry."
                return
            }
        }
        if appliedViewpointRevision != revision {
            appliedViewpointRevision = revision
            if let viewpoint = scene.viewpoint {
                sceneRoot.orientation = viewpoint.orientation
                refreshCameraFraming()
            }
        }
        guard self.selectedNodeID != selectedNodeID, let assembly else { return }
        self.selectedNodeID = selectedNodeID
        previousControlValue = .nan
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
        refreshCameraFraming()
    }

    func orbit(horizontal: Float, vertical: Float) {
        sceneRoot.orientation =
            simd_quatf(angle: vertical, axis: [1, 0, 0])
            * simd_quatf(angle: horizontal, axis: [0, 1, 0]) * sceneRoot.orientation
        refreshCameraFraming()
    }

    func resetOrientation() {
        sceneRoot.orientation = PaceFigureScene.Viewpoint.threeQuarter.orientation
        refreshCameraFraming()
    }

    private func cacheFramingBounds(for assembly: PaceFigureAssembly) {
        let restingBounds = assembly.root.visualBounds(relativeTo: sceneRoot)
        var bounds = PaceFigureCameraFraming.Bounds(minimum: restingBounds.min, maximum: restingBounds.max)
        // Cache a full hinge envelope once, so animated control surfaces stay
        // inside the fitted volume without walking the mesh tree every frame.
        for surface in assembly.movingSurfaces {
            let hingePosition = surface.entity.position(relativeTo: sceneRoot)
            let surfaceBounds = surface.entity.visualBounds(relativeTo: sceneRoot)
            let corners = PaceFigureCameraFraming.Bounds(
                minimum: surfaceBounds.min, maximum: surfaceBounds.max
            ).corners
            let radius = corners.map { simd_length($0 - hingePosition) }.max() ?? 0
            bounds.includeSphere(center: hingePosition, radius: radius)
        }
        framingBounds = bounds
    }

    private func refreshCameraFraming() {
        guard let framingBounds, let framingCamera,
            let distance = PaceFigureCameraFraming.cameraDistance(
                for: framingBounds, orientation: sceneRoot.orientation, viewportSize: viewportSize)
        else { return }
        // Bounds are cached in the unzoomed scene-root coordinate space.
        // Manual zoom therefore magnifies the fitted view instead of being cancelled.
        framingCamera.look(at: .zero, from: [0, 0, distance], relativeTo: nil)
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
