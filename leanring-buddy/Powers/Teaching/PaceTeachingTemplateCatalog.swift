import Foundation

/// Trusted native geometry. Model output selects a template and supplies teaching text, never executable content.
nonisolated enum PaceTeachingTemplateCatalog {
    struct Motion: Equatable, Sendable {
        let nodeID: String
        let pivot: [Double]
        let axis: [Double]
        let maximumAngle: Double
        var translation: [Double] = [0, 0, 0]
    }
    struct Definition: Sendable {
        let template: PaceFigureScene.Template
        let title: String
        let explanations: [(id: String, label: String, detail: String)]
        let parts: [PaceFigureScene.Part]
        let anchors: [String: [Double]]
        let motions: [Motion]
        let source: String
        var nodeIDs: Set<String> { Set(explanations.map(\.id)) }
        var controlNodeIDs: Set<String> { Set(motions.map(\.nodeID)) }
        var prompt: String {
            "template \(template.rawValue): \(title). Required node IDs: "
                + explanations.map { "\($0.id) (\($0.label))" }.joined(separator: ", ")
                + ". Moving assemblies: " + motions.map(\.nodeID).joined(separator: ", ") + "."
        }
    }

    static let definitions: [Definition] = [liftSystem, piCamera]
    static func definition(for template: PaceFigureScene.Template?) -> Definition? {
        definitions.first { $0.template == template }
    }
    static var prompt: String { definitions.map(\.prompt).joined(separator: "\n") }

    static func lessonDocument(for template: PaceFigureScene.Template) -> PaceDiagramDocument? {
        guard let definition = definition(for: template) else { return nil }
        let nodes = definition.explanations.map { item in
            PaceDiagramNode(id: item.id, label: item.label, detail: item.detail, x: 0, y: 0,
                            width: 220, height: 130, shape: nil, role: nil, subtitle: nil)
        }
        let steps = definition.explanations.enumerated().map { index, item in
            PaceTeachingLesson.Step(id: "step-\(index + 1)", title: item.label, narration: item.detail,
                revealedNodeIDs: Array(definition.explanations.prefix(index + 1).map(\.id)), focusNodeID: item.id,
                viewpoint: index == 0 ? .threeQuarter : nil,
                controlValue: definition.controlNodeIDs.contains(item.id) ? 0.8 : nil)
        }
        return PaceDiagramDocument(title: definition.title,
            summary: "Conceptual teaching model. Drag to orbit; select a real assembly to explore it.",
            nodes: nodes, connections: [], figure: .init(template: template), lesson: .init(steps: steps))
    }

    private static func part(_ id: String, _ node: String, _ geometry: PaceFigureScene.Geometry,
                             _ position: [Double], _ size: [Double], _ finish: PaceFigureScene.Finish = .metal,
                             _ rotation: [Double]? = nil) -> PaceFigureScene.Part {
        .init(id: id, nodeID: node, geometry: geometry, position: position, size: size,
              rotation: rotation, finish: finish)
    }

    static let liftSystem: Definition = {
        var parts: [PaceFigureScene.Part] = []
        // X runs from the engine exhaust at the left to the lift fan and nose at the right.
        parts.append(part("keel", "airframe", .box, [0, -0.38, -0.12], [8.1, 0.12, 0.55], .dark))
        parts.append(part("nose", "airframe", .cone, [3.9, -0.07, -0.04], [0.85, 1.9, 0.75], .shell, [0, 0, -90]))
        for side in [-1.0, 1.0] {
            parts.append(part("wing-\(side)", "airframe", .mesh, [-0.4, -0.23, side * 0.65], [3.1, 0.11, 2.1], .shell))
            let index = parts.count - 1
            parts[index].vertices = [[-0.5, -0.5, 0], [0.5, -0.5, 0], [-0.36, -0.5, side * 0.5],
                                     [-0.5, 0.5, 0], [0.5, 0.5, 0], [-0.36, 0.5, side * 0.5]]
            parts[index].triangles = [0, 1, 2, 3, 5, 4, 0, 3, 4, 0, 4, 1, 1, 4, 5, 1, 5, 2, 2, 5, 3, 2, 3, 0]
            parts.append(part("rollpost-\(side)", "roll-posts", .cylinder, [-0.5, -0.38, side * 2.0], [0.3, 0.38, 0.3], .dark))
            parts.append(part("rollpipe-\(side)", "roll-posts", .cylinder, [-0.5, -0.18, side * 1.15], [0.16, 1.8, 0.16], .metal, [90, 0, 0]))
            parts.append(part("spine-\(side)", "airframe", .box, [0, -0.19, side * 0.6], [7.2, 0.23, 0.1], .shell))
        }
        parts.append(part("canopy", "airframe", .ellipsoid, [3.0, 0.38, 0], [1.1, 0.44, 0.58], .glass))
        for side in [-1.0, 1.0] {
            let vertices: [[Double]] = [[-0.5, -0.5, -0.05], [0.5, -0.5, -0.05], [-0.15, 0.5, -0.05],
                                        [-0.5, -0.5, 0.05], [0.5, -0.5, 0.05], [-0.15, 0.5, 0.05]]
            var fin = part("tail-fin-\(side)", "airframe", .mesh,
                           [-2.5, 0.48, side * 0.64], [1.1, 1.2, 0.8], .shell, [side * 18, 0, 0])
            fin.vertices = vertices
            fin.triangles = [0, 2, 1, 3, 4, 5, 0, 1, 4, 0, 4, 3, 1, 2, 5, 1, 5, 4, 2, 0, 3, 2, 3, 5]
            parts.append(fin)
            parts.append(part("tailplane-\(side)", "airframe", .box,
                              [-2.35, -0.2, side * 1.0], [1.35, 0.06, 1.15], .shell, [0, side * 15, 0]))
        }
        parts.append(part("fan-hub", "lift-fan", .cylinder, [2.05, 0.0, 0], [0.35, 0.7, 0.35], .metal))
        for ring in 0..<3 {
            for sector in 0..<16 {
                let angle = Double(sector) * .pi / 8
                let radius = 0.86
                parts.append(part("fan-ring-\(ring)-\(sector)", "lift-fan", .box,
                    [2.05 + cos(angle) * radius, Double(ring) * 0.25 - 0.24, sin(angle) * radius],
                    [0.35, 0.10, 0.08], .shell, [0, 90 - angle * 180 / .pi, 0]))
            }
        }
        for blade in 0..<14 {
            let angle = Double(blade) * .pi / 7
            parts.append(part("fan-blade-\(blade)", "lift-fan", .box,
                [2.05 + cos(angle) * 0.48, 0.16, sin(angle) * 0.48], [0.68, 0.055, 0.16], .metal,
                [12, -angle * 180 / .pi, 0]))
        }
        parts.append(part("shaft", "driveshaft", .cylinder, [0.65, 0, 0], [0.13, 2.6, 0.13], .metal, [0, 0, 90]))
        parts.append(part("clutch", "driveshaft", .cylinder, [1.45, 0, 0], [0.42, 0.28, 0.42], .accent, [0, 0, 90]))
        for bearing in 0..<3 {
            parts.append(part("shaft-bearing-\(bearing)", "driveshaft", .cylinder, [Double(bearing) * 0.65 - 0.1, 0, 0], [0.28, 0.1, 0.28], .dark, [0, 0, 90]))
        }
        parts.append(part("engine-core", "engine", .cylinder, [-1.45, 0, 0], [0.68, 2.4, 0.68], .dark, [0, 0, 90]))
        for station in 0..<8 {
            let x = -0.45 - Double(station) * 0.27
            for blade in 0..<8 {
                let angle = Double(blade) * .pi / 4
                parts.append(part("compressor-\(station)-\(blade)", "engine", .box,
                    [x, cos(angle) * 0.40, sin(angle) * 0.40], [0.055, 0.35, 0.12], station > 4 ? .accent : .metal,
                    [angle * 180 / .pi, 0, 0]))
            }
        }
        // Only the rear/underside casing is closed so the machinery remains visible from the teaching camera.
        for rib in 0..<5 {
            parts.append(part("engine-casing-\(rib)", "engine", .box, [-0.65 - Double(rib) * 0.4, -0.38, -0.28], [0.28, 0.18, 0.55], .shell))
        }
        for bearing in 0..<3 {
            parts.append(part("nozzle-bearing-\(bearing)", "swivel-nozzle", .cylinder,
                [-2.85 - Double(bearing) * 0.20, 0, 0], [0.77 - Double(bearing) * 0.05, 0.13, 0.77 - Double(bearing) * 0.05], .metal, [0, 0, 90]))
        }
        for petal in 0..<12 {
            let angle = Double(petal) * .pi / 6
            parts.append(part("nozzle-petal-\(petal)", "swivel-nozzle", .box,
                [-3.25, cos(angle) * 0.32, sin(angle) * 0.32], [0.42, 0.13, 0.16], .dark, [angle * 180 / .pi, 0, 0]))
        }
        return Definition(template: .liftSystem, title: "How the F-35B hovers",
            explanations: [
                ("airframe", "Cutaway airframe", "This is a conceptual F-35B lift-system cutaway, not exact CAD. The open upper casing lets us trace the machinery inside."),
                ("engine", "Main engine", "The main engine supplies exhaust thrust and shaft power. During vertical lift, some engine power is transferred forward to the lift fan."),
                ("driveshaft", "Driveshaft and clutch", "The driveshaft carries mechanical power from the engine. A clutch connects that power to the lift fan for vertical-lift operation."),
                ("lift-fan", "LiftFan", "The shaft-driven fan pushes air downward near the front of the aircraft. Its lift balances the rear exhaust while hovering."),
                ("swivel-nozzle", "Three-bearing swivel nozzle", "Three articulated bearings allow the rear exhaust module to direct thrust downward. This hinge demonstrates the idea rather than the exact bearing kinematics."),
                ("roll-posts", "Roll posts", "Ducted air exits through the roll posts near the wings. Differential flow helps control roll during hover.")],
            parts: parts, anchors: ["airframe": [3.2, -0.1, 0], "engine": [-1.5, 0.35, 0], "driveshaft": [1.25, 0.1, 0],
                "lift-fan": [2.05, 0.3, 0], "swivel-nozzle": [-3.1, 0, 0], "roll-posts": [-0.5, -0.35, 2]],
            motions: [.init(nodeID: "swivel-nozzle", pivot: [-2.65, 0, 0], axis: [0, 0, 1], maximumAngle: .pi / 2)],
            source: "https://www.rolls-royce.com/products-and-services/defence/aerospace/combat-jets/rolls-royce-liftsystem.aspx")
    }()

    static let piCamera: Definition = {
        var parts: [PaceFigureScene.Part] = []
        parts.append(part("pcb", "board", .box, [0, 0, 0], [4.3, 0.10, 2.8], .accent))
        for x in [-1.9, 1.9] { for z in [-1.15, 1.15] {
            parts.append(part("mount-\(x)-\(z)", "board", .cylinder, [x, 0.075, z], [0.18, 0.025, 0.18], .metal))
        }}
        parts.append(part("soc", "board", .box, [0.0, 0.19, -0.15], [0.85, 0.2, 0.85], .metal))
        parts.append(part("ram", "board", .box, [0.9, 0.13, 0.15], [0.55, 0.12, 0.65], .dark))
        for port in 0..<3 {
            parts.append(part("io-\(port)", "board", .box, [-1.55 + Double(port) * 1.45, 0.32, -1.18], [1.05, 0.55, 0.7], .metal))
            parts.append(part("io-opening-\(port)", "board", .box, [-1.55 + Double(port) * 1.45, 0.33, -1.54], [0.82, 0.36, 0.03], .dark))
        }
        for pin in 0..<40 {
            let x = -1.85 + Double(pin / 2) * 0.18
            let z = 0.99 + Double(pin % 2) * 0.18
            parts.append(part("gpio-\(pin)", "board", .box, [x, 0.29, z], [0.055, 0.43, 0.055], .metal))
        }
        for component in 0..<18 {
            let x = -1.75 + Double(component % 6) * 0.52
            let z = -0.7 + Double(component / 6) * 0.48
            parts.append(part("component-\(component)", "board", .box, [x, 0.10, z], [0.15, 0.09, 0.085], component % 3 == 0 ? .metal : .dark))
        }
        for port in 0..<2 {
            let x = 1.72
            let z = -0.6 + Double(port) * 1.05
            let node = port == 0 ? "camera-port" : "display-port"
            parts.append(part("socket-\(port)", node, .box, [x, 0.15, z], [0.30, 0.16, 0.80], .shell))
            for contact in 0..<22 {
                parts.append(part("contact-\(port)-\(contact)", node, .box,
                    [x + 0.08, 0.24, z - 0.34 + Double(contact) * 0.032], [0.13, 0.02, 0.012], .metal))
            }
            parts.append(part("latch-\(port)", port == 0 ? "latch" : node, .box,
                [x + 0.10, 0.27, z], [0.16, 0.07, 0.88], .dark))
        }
        parts.append(part("mini-cable", "ribbon", .box, [2.52, 0.20, -0.6], [1.4, 0.035, 0.70], .shell))
        for trace in 0..<22 {
            parts.append(part("ribbon-trace-\(trace)", "ribbon", .box,
                [2.52, 0.222, -0.94 + Double(trace) * 0.032], [1.38, 0.007, 0.010], .metal))
        }
        parts.append(part("ribbon-tab", "ribbon", .box, [1.92, 0.23, -0.6], [0.30, 0.05, 0.72], .accent))
        parts.append(part("camera-pcb", "camera", .box, [3.65, 0.17, -0.6], [0.88, 0.08, 1.05], .accent))
        parts.append(part("camera-sensor", "camera", .box, [3.65, 0.30, -0.6], [0.48, 0.20, 0.48], .dark))
        parts.append(part("camera-lens", "camera", .cylinder, [3.65, 0.48, -0.6], [0.35, 0.18, 0.35], .glass))
        return Definition(template: .piCamera, title: "Connect a Raspberry Pi 5 camera",
            explanations: [
                ("board", "Power off first", "Shut down the Raspberry Pi and disconnect its power before handling the camera cable. This board is a conceptual model; use the official connector orientation for your hardware."),
                ("camera-port", "22-pin camera/display port", "Raspberry Pi 5 has two 22-pin camera/display connectors. A standard camera module needs a Standard-to-Mini cable, with its mini end at the Pi."),
                ("display-port", "Second shared port", "The second connector can also carry a camera or display connection. These are shared camera/display interfaces, not a full-size older 15-pin camera socket."),
                ("latch", "Raise the latch gently", "Gently raise the connector latch. The illustrated motion exaggerates its travel so you can see the locking mechanism. Do not force or remove the latch."),
                ("ribbon", "Insert and secure the ribbon", "Align the ribbon contacts in the orientation shown in the official Pi 5 instructions, insert the cable straight and fully, then gently close the latch. The blue tab alone does not establish contact orientation."),
                ("camera", "Camera module", "Connect the standard end to the camera module. Check both ends are seated and locked before reconnecting power. Keep fingers off the lens and electrical contacts.")],
            parts: parts, anchors: ["board": [0, 0.25, 0], "camera-port": [1.72, 0.24, -0.6],
                "display-port": [1.72, 0.24, 0.45], "latch": [1.82, 0.3, -0.6], "ribbon": [2.52, 0.23, -0.6], "camera": [3.65, 0.5, -0.6]],
            motions: [.init(nodeID: "latch", pivot: [1.72, 0.23, -0.6], axis: [0, 0, 1], maximumAngle: 0, translation: [0, 0.2, 0]),
                      .init(nodeID: "ribbon", pivot: [0, 0, 0], axis: [0, 0, 1], maximumAngle: 0, translation: [0.5, 0.12, 0])],
            source: "https://www.raspberrypi.com/documentation/accessories/camera.html")
    }()
}
