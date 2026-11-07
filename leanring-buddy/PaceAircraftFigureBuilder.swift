import AppKit
import RealityKit
import simd

@MainActor
enum PaceAircraftFigureBuilder {
    private struct FoilSection {
        let leadingEdge: SIMD3<Float>
        let chord: Float
        let normal: SIMD3<Float>
    }

    private struct MeshGeometry {
        var positions: [SIMD3<Float>] = []
        var triangles: [UInt32] = []
    }

    static func makeAssembly() throws -> PaceFigureAssembly {
        let root = Entity()
        root.name = "fuselage"
        var selectableEntities: [ModelEntity] = []
        var movingSurfaces: [PaceFigureControlSurface] = []
        let silver = material(0.75, 0.79, 0.83, roughness: 0.40, metallic: true)
        let paleSilver = material(0.82, 0.85, 0.88, roughness: 0.35, metallic: true)
        let graphite = material(0.12, 0.15, 0.19, roughness: 0.47, metallic: true)
        let seam = material(0.21, 0.25, 0.30, roughness: 0.48, metallic: false)
        let glass = material(0.13, 0.28, 0.43, roughness: 0.10, metallic: true)
        let controlBlue = material(0.27, 0.43, 0.63, roughness: 0.32, metallic: true)
        let fanMetal = material(0.36, 0.41, 0.48, roughness: 0.23, metallic: true)
        let darkIntake = material(0.035, 0.045, 0.06, roughness: 0.76, metallic: false)

        func install(
            _ geometry: MeshGeometry, material: SimpleMaterial, diagnostic: String,
            nodeID: String? = nil, parent: Entity? = nil
        ) throws -> ModelEntity {
            let entity = ModelEntity(mesh: try mesh(geometry, diagnostic: diagnostic), materials: [material])
            entity.name = nodeID ?? ""
            if nodeID != nil {
                entity.components.set(InputTargetComponent())
                entity.generateCollisionShapes(recursive: false)
                selectableEntities.append(entity)
            }
            (parent ?? root).addChild(entity)
            return entity
        }

        func installControlSurface(
            sections: [FoilSection], chordRange: ClosedRange<Float>, side: Float,
            nodeID: String, direction: Float, angle: Float, diagnostic: String,
            thicknessRatio: Float = 0.12, parent: Entity? = nil
        ) throws -> Entity {
            let firstSection = sections[0]
            let lastSection = sections[sections.count - 1]
            let firstHinge = foilPoint(
                section: firstSection, fraction: chordRange.lowerBound, sign: 0, thicknessRatio: thicknessRatio)
            let lastHinge = foilPoint(
                section: lastSection, fraction: chordRange.lowerBound, sign: 0, thicknessRatio: thicknessRatio)
            let hinge = Entity()
            hinge.name = nodeID
            hinge.position = firstHinge
            (parent ?? root).addChild(hinge)
            let geometry = foil(
                sections: sections, chordRange: chordRange, reverse: side > 0, thicknessRatio: thicknessRatio)
            var localGeometry = geometry
            localGeometry.positions = geometry.positions.map { $0 - firstHinge }
            _ = try install(localGeometry, material: controlBlue, diagnostic: diagnostic, nodeID: nodeID, parent: hinge)
            movingSurfaces.append(
                .init(
                    entity: hinge, restingOrientation: hinge.orientation,
                    axis: simd_normalize(lastHinge - firstHinge), maximumAngle: angle,
                    nodeID: nodeID, direction: direction
                ))
            return hinge
        }

        let fuselageRings = (0...88).map { longitudinalIndex in
            let longitudinalPosition = -5.1 + Float(longitudinalIndex) / 88 * 10.2
            return (0..<72).map { radialIndex in
                bodyPoint(
                    longitudinalPosition: longitudinalPosition, angle: Float(radialIndex) / 72 * .pi * 2, offset: 0)
            }
        }
        _ = try install(
            loft(rings: fuselageRings, reverse: true), material: silver, diagnostic: "smooth-fuselage",
            nodeID: "fuselage")

        // A closed belly fairing carries the wing-root junction rather than leaving wings perched on the tube.
        let fairingProfile: [(Float, Float)] = [
            (-1.85, 0.025), (-1.55, 0.26), (-0.8, 0.42), (0.1, 0.43), (0.85, 0.29), (1.15, 0.025),
        ]
        var belly = lathe(profile: fairingProfile, radialSegments: 48)
        belly.positions = belly.positions.map { SIMD3<Float>($0.x, $0.y * 0.50 - 0.40, $0.z * 1.85) }
        _ = try install(belly, material: silver, diagnostic: "wing-body-belly-fairing")

        for longitudinalPosition: Float in [4.55, -3.05] {
            let points = (0...96).map { index in
                bodyPoint(longitudinalPosition: longitudinalPosition, angle: Float(index) / 96 * .pi * 2, offset: 0.006)
            }
            _ = try install(
                tube(points: points, radius: 0.005, sides: 6), material: seam,
                diagnostic: "fuselage-circumferential-joint")
        }
        for side: Float in [-1, 1] {
            let longitudinalPoints = (0...50).map { index in
                bodyPoint(longitudinalPosition: -2.75 + Float(index) / 50 * 5.7, angle: side * 1.77, offset: 0.005)
            }
            _ = try install(
                tube(points: longitudinalPoints, radius: 0.0035, sides: 5), material: seam,
                diagnostic: "lower-fuselage-skin-joint")
            for windowIndex in 0..<12 {
                let longitudinalPosition = -2.035 + Float(windowIndex) * 0.37
                let centerAngle = side * 1.25
                let outer = ellipseBoundary(
                    centerX: longitudinalPosition, centerAngle: centerAngle, halfWidth: 0.087, halfAngle: 0.151)
                let inner = ellipseBoundary(
                    centerX: longitudinalPosition, centerAngle: centerAngle, halfWidth: 0.065, halfAngle: 0.116)
                _ = try install(
                    bodyRing(outer: outer, inner: inner, offset: 0.008), material: graphite,
                    diagnostic: "cabin-window-frame")
                _ = try install(
                    bodyPatch(boundary: inner, offset: 0.012), material: glass, diagnostic: "cabin-window-glazing")
            }
            for doorX: Float in [-2.78, 2.78] {
                let outer = roundedBoundary(
                    centerX: doorX, centerAngle: side * 1.47, halfWidth: 0.18, halfAngle: 0.50, corner: 0.18)
                let inner = roundedBoundary(
                    centerX: doorX, centerAngle: side * 1.47, halfWidth: 0.165, halfAngle: 0.475, corner: 0.18)
                _ = try install(
                    bodyRing(outer: outer, inner: inner, offset: 0.007), material: seam,
                    diagnostic: "passenger-door-seal")
                let handle = roundedBoundary(
                    centerX: doorX + 0.05, centerAngle: side * 1.47, halfWidth: 0.045, halfAngle: 0.018, corner: 0.35)
                _ = try install(
                    bodyPatch(boundary: handle, offset: 0.014), material: paleSilver,
                    diagnostic: "passenger-door-handle")
            }
        }

        for side: Float in [-1, 1] {
            let cockpitPanels: [[SIMD2<Float>]] = [
                [
                    SIMD2(4.03, side * 0.17), SIMD2(4.40, side * 0.34), SIMD2(4.20, side * 0.94),
                    SIMD2(3.94, side * 0.83),
                ],
                [
                    SIMD2(3.91, side * 0.88), SIMD2(4.16, side * 1.00), SIMD2(3.95, side * 1.34),
                    SIMD2(3.70, side * 1.27),
                ],
                [
                    SIMD2(3.66, side * 0.91), SIMD2(3.83, side * 1.02), SIMD2(3.64, side * 1.37),
                    SIMD2(3.41, side * 1.31),
                ],
            ]
            for panel in cockpitPanels {
                let center = panel.reduce(SIMD2<Float>.zero, +) / Float(panel.count)
                let frameBoundary = panel.map { center + ($0 - center) * 1.075 }
                _ = try install(
                    bodyRing(outer: frameBoundary, inner: panel, offset: 0.009), material: graphite,
                    diagnostic: "cockpit-glazing-frame")
                _ = try install(
                    bodyPatch(boundary: panel, offset: 0.016), material: glass, diagnostic: "cockpit-glazing",
                    nodeID: "cockpit")
            }
        }

        for side: Float in [-1, 1] {
            let completeWing = wingSections(side: side, start: 0.59, end: 4.96, count: 26)
            _ = try install(
                foil(sections: completeWing, chordRange: 0...0.718, reverse: side > 0), material: paleSilver,
                diagnostic: "swept-airfoil-wing", nodeID: "wings")
            for fixedSpan: ClosedRange<Float> in [0.59...1.10, 2.96...3.08, 4.65...4.96] {
                let sections = wingSections(
                    side: side, start: fixedSpan.lowerBound, end: fixedSpan.upperBound, count: 5)
                _ = try install(
                    foil(sections: sections, chordRange: 0.725...1, reverse: side > 0), material: paleSilver,
                    diagnostic: "fixed-wing-trailing-edge")
            }
            _ = try installControlSurface(
                sections: wingSections(side: side, start: 3.08, end: 4.65, count: 12),
                chordRange: 0.730...1, side: side, nodeID: "ailerons", direction: 1,
                angle: .pi / 8, diagnostic: "outboard-aileron"
            )
            for flapSpan: ClosedRange<Float> in [1.10...2.0, 2.02...2.96] {
                let flap = try installControlSurface(
                    sections: wingSections(side: side, start: flapSpan.lowerBound, end: flapSpan.upperBound, count: 8),
                    chordRange: 0.730...1, side: side, nodeID: "flaps", direction: side,
                    angle: .pi / 5.5, diagnostic: "trailing-edge-flap"
                )
                let midSpan = (flapSpan.lowerBound + flapSpan.upperBound) / 2
                let station = wingSections(side: side, start: midSpan, end: midSpan + 0.01, count: 2)[0]
                let trackCenter = station.leadingEdge + SIMD3<Float>(-station.chord * 0.85, -0.11, 0)
                let trackProfile: [(Float, Float)] = [(-0.30, 0.003), (-0.20, 0.045), (0.11, 0.050), (0.22, 0.005)]
                var track = lathe(profile: trackProfile, radialSegments: 16)
                track.positions = track.positions.map { $0 + trackCenter }
                _ = try install(track, material: silver, diagnostic: "flap-track-fairing")
                let hingePin = ModelEntity(mesh: .generateSphere(radius: 0.022), materials: [fanMetal])
                hingePin.position = [0, -0.035, 0]
                flap.addChild(hingePin)
            }
            let wingletSections = (0...14).map { index in
                let fraction = Float(index) / 14
                let angle = fraction * 1.22
                return FoilSection(
                    leadingEdge: SIMD3<Float>(
                        -1.50 - fraction * 0.29, 0.247 + fraction * 0.82, side * (4.96 + 0.21 * sin(fraction * .pi / 2))
                    ),
                    chord: 0.76 - fraction * 0.36,
                    normal: SIMD3<Float>(0, cos(angle), -side * sin(angle))
                )
            }
            _ = try install(
                foil(sections: wingletSections, chordRange: 0...1, reverse: side > 0, thicknessRatio: 0.08),
                material: silver, diagnostic: "blended-winglet")
            let navigationLight = ModelEntity(
                mesh: .generateSphere(radius: 0.026),
                materials: [
                    material(side < 0 ? 0.56 : 0.15, side < 0 ? 0.13 : 0.47, 0.14, roughness: 0.18, metallic: false)
                ])
            navigationLight.position = SIMD3<Float>(-1.81, 1.075, side * 5.17)
            root.addChild(navigationLight)

            let enginePosition = SIMD3<Float>(0.45, -0.72, side * 1.85)
            let engineGroup = Entity()
            engineGroup.name = "engines"
            engineGroup.position = enginePosition
            root.addChild(engineGroup)
            let outerNacelle: [(Float, Float)] = [
                (-0.92, 0.24), (-0.80, 0.29), (-0.55, 0.37), (-0.1, 0.41),
                (0.45, 0.415), (0.80, 0.405), (0.99, 0.387),
                (0.99, 0.348), (0.78, 0.337), (0.25, 0.322), (-0.55, 0.25), (-0.92, 0.213),
            ]
            _ = try install(
                lathe(profile: outerNacelle, radialSegments: 64, closesProfile: true), material: silver,
                diagnostic: "hollow-nacelle-shell", nodeID: "engines", parent: engineGroup)
            _ = try install(
                torusX(longitudinalPosition: 0.992, majorRadius: 0.369, minorRadius: 0.021), material: paleSilver,
                diagnostic: "rounded-intake-lip", parent: engineGroup)
            let intakeProfile: [(Float, Float)] = [(0.15, 0.316), (0.72, 0.332), (0.72, 0.319), (0.15, 0.303)]
            _ = try install(
                lathe(profile: intakeProfile, radialSegments: 56, closesProfile: true), material: darkIntake,
                diagnostic: "acoustic-intake-liner", parent: engineGroup)
            _ = try install(
                torusX(longitudinalPosition: 0.69, majorRadius: 0.304, minorRadius: 0.012), material: fanMetal,
                diagnostic: "fan-case-rim", parent: engineGroup)
            for bladeIndex in 0..<12 {
                _ = try install(
                    fanBlade(index: bladeIndex, count: 12), material: fanMetal, diagnostic: "swept-turbofan-blade",
                    parent: engineGroup)
            }
            let spinnerProfile: [(Float, Float)] = [
                (0.67, 0.095), (0.76, 0.099), (0.88, 0.074), (0.97, 0.039), (1.01, 0.002),
            ]
            _ = try install(
                lathe(profile: spinnerProfile, radialSegments: 40), material: paleSilver, diagnostic: "fan-spinner",
                parent: engineGroup)
            let exhaustProfile: [(Float, Float)] = [
                (-1.06, 0.168), (-0.96, 0.220), (-0.78, 0.235), (-0.78, 0.203), (-0.98, 0.145),
            ]
            _ = try install(
                lathe(profile: exhaustProfile, radialSegments: 40, closesProfile: true), material: graphite,
                diagnostic: "exhaust-nozzle", parent: engineGroup)
            _ = try install(
                lathe(profile: [(-1.10, 0.002), (-0.95, 0.067), (-0.72, 0.083), (-0.60, 0.015)], radialSegments: 32),
                material: fanMetal, diagnostic: "exhaust-centerbody", parent: engineGroup)
            let pylonPoints = [
                SIMD2<Float>(-0.43, -0.31), SIMD2<Float>(0.46, -0.31), SIMD2<Float>(0.24, -0.075),
                SIMD2<Float>(-0.22, -0.05),
            ]
            var pylon = prism(polygon: pylonPoints, halfDepth: 0.065)
            pylon.positions = pylon.positions.map { $0 + SIMD3<Float>(0.44, 0, side * 1.85) }
            _ = try install(pylon, material: silver, diagnostic: "wing-mounted-engine-pylon")
        }

        for side: Float in [-1, 1] {
            let tailSections = tailplaneSections(side: side)
            _ = try install(
                foil(sections: tailSections, chordRange: 0...0.70, reverse: side > 0, thicknessRatio: 0.095),
                material: silver, diagnostic: "horizontal-stabilizer")
            _ = try installControlSurface(
                sections: tailSections, chordRange: 0.718...1, side: side,
                nodeID: "elevators", direction: -side, angle: .pi / 7,
                diagnostic: "hinged-elevator", thicknessRatio: 0.095
            )
        }

        let verticalSections = (0...20).map { index in
            let fraction = Float(index) / 20
            return FoilSection(
                leadingEdge: SIMD3<Float>(-3.18 - fraction * 1.15, 0.43 + fraction * 1.65, 0),
                chord: 1.52 - fraction * 0.85,
                normal: SIMD3<Float>(0, 0, 1)
            )
        }
        _ = try install(
            foil(sections: verticalSections, chordRange: 0...0.705, reverse: false, thicknessRatio: 0.095),
            material: silver, diagnostic: "vertical-stabilizer")
        _ = try installControlSurface(
            sections: verticalSections, chordRange: 0.722...1, side: -1,
            nodeID: "rudder", direction: 1, angle: .pi / 7,
            diagnostic: "hinged-rudder", thicknessRatio: 0.095
        )
        let beacon = ModelEntity(
            mesh: .generateSphere(radius: 0.027),
            materials: [material(0.48, 0.12, 0.11, roughness: 0.20, metallic: false)])
        beacon.position = bodyPoint(longitudinalPosition: -0.8, angle: 0, offset: 0.024)
        root.addChild(beacon)

        return PaceFigureAssembly(root: root, selectableEntities: selectableEntities, movingSurfaces: movingSurfaces)
    }

    private static func material(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, roughness: Float, metallic: Bool)
        -> SimpleMaterial
    {
        var material = SimpleMaterial(
            color: NSColor(srgbRed: red, green: green, blue: blue, alpha: 1), roughness: .float(roughness),
            isMetallic: metallic)
        if metallic { material.metallic = .float(0.40) }
        return material
    }

    private static func bodyRadius(_ longitudinalPosition: Float) -> Float {
        if longitudinalPosition > 3 {
            let fraction = min(1, max(0, (longitudinalPosition - 3) / 2.1))
            return max(0.002, 0.64 * sqrt(max(0, 1 - fraction * fraction)))
        }
        if longitudinalPosition < -2.8 {
            let fraction = min(1, max(0, (longitudinalPosition + 5.1) / 2.3))
            return max(0.002, 0.64 * pow(sin(fraction * .pi / 2), 1.35))
        }
        return 0.64
    }

    private static func bodyPoint(longitudinalPosition: Float, angle: Float, offset: Float) -> SIMD3<Float> {
        let radius = bodyRadius(longitudinalPosition) + offset
        let tailFraction = max(0, min(1, (-2.8 - longitudinalPosition) / 2.3))
        return SIMD3<Float>(
            longitudinalPosition, radius * cos(angle) * 0.94 + tailFraction * tailFraction * 0.16, radius * sin(angle))
    }

    private static func wingSections(side: Float, start: Float, end: Float, count: Int) -> [FoilSection] {
        (0..<count).map { index in
            let span = start + (end - start) * Float(index) / Float(count - 1)
            let fraction = (span - 0.59) / (4.96 - 0.59)
            return FoilSection(
                leadingEdge: SIMD3<Float>(1.28 - fraction * 2.78, -0.14 + fraction * 0.387, side * span),
                chord: 2.58 - fraction * 1.82,
                normal: SIMD3<Float>(0, 1, 0)
            )
        }
    }

    private static func tailplaneSections(side: Float) -> [FoilSection] {
        (0...16).map { index in
            let fraction = Float(index) / 16
            return FoilSection(
                leadingEdge: SIMD3<Float>(
                    -3.48 - fraction * 0.81, 0.35 + fraction * 0.20, side * (0.43 + fraction * 1.56)),
                chord: 1.28 - fraction * 0.60,
                normal: SIMD3<Float>(0, 1, 0)
            )
        }
    }

    private static func foil(
        sections: [FoilSection], chordRange: ClosedRange<Float>, reverse: Bool, thicknessRatio: Float = 0.12
    ) -> MeshGeometry {
        let samples = 22
        let fractions = (0...samples).map { index -> Float in
            let easedFraction = (1 - cos(Float(index) / Float(samples) * .pi)) / 2
            return chordRange.lowerBound + easedFraction * (chordRange.upperBound - chordRange.lowerBound)
        }
        let rings = sections.map { section in
            let upper = fractions.map { fraction in
                foilPoint(section: section, fraction: fraction, sign: 1, thicknessRatio: thicknessRatio)
            }
            let lower = fractions.reversed().map { fraction in
                foilPoint(section: section, fraction: fraction, sign: -1, thicknessRatio: thicknessRatio)
            }
            return upper + lower
        }
        return loft(rings: rings, reverse: reverse)
    }

    private static func foilPoint(section: FoilSection, fraction: Float, sign: Float, thicknessRatio: Float) -> SIMD3<
        Float
    > {
        let thickness =
            5 * thicknessRatio
            * (0.2969 * sqrt(fraction) - 0.1260 * fraction - 0.3516 * fraction * fraction + 0.2843 * pow(fraction, 3)
                - 0.1036 * pow(fraction, 4))
        let camber = 0.011 * sin(fraction * .pi)
        return section.leadingEdge + SIMD3<Float>(-section.chord * fraction, 0, 0) + section.normal * section.chord
            * (camber + sign * max(0.001, thickness))
    }

    private static func loft(rings: [[SIMD3<Float>]], reverse: Bool, capsEnds: Bool = true) -> MeshGeometry {
        var geometry = MeshGeometry(positions: rings.flatMap { $0 })
        let ringSize = rings[0].count
        for ringIndex in 0..<(rings.count - 1) {
            for vertexIndex in 0..<ringSize {
                let first = UInt32(ringIndex * ringSize + vertexIndex)
                let second = UInt32((ringIndex + 1) * ringSize + vertexIndex)
                let third = UInt32((ringIndex + 1) * ringSize + (vertexIndex + 1) % ringSize)
                let fourth = UInt32(ringIndex * ringSize + (vertexIndex + 1) % ringSize)
                geometry.triangles +=
                    reverse
                    ? [first, third, second, first, fourth, third] : [first, second, third, first, third, fourth]
            }
        }
        if capsEnds {
            for ringIndex in [0, rings.count - 1] {
                let center = rings[ringIndex].reduce(SIMD3<Float>.zero, +) / Float(ringSize)
                let centerIndex = UInt32(geometry.positions.count)
                geometry.positions.append(center)
                for vertexIndex in 0..<ringSize {
                    let first = UInt32(ringIndex * ringSize + vertexIndex)
                    let second = UInt32(ringIndex * ringSize + (vertexIndex + 1) % ringSize)
                    let flip = (ringIndex == 0) == reverse
                    geometry.triangles += flip ? [centerIndex, second, first] : [centerIndex, first, second]
                }
            }
        }
        return geometry
    }

    private static func lathe(profile: [(Float, Float)], radialSegments: Int, closesProfile: Bool = false)
        -> MeshGeometry
    {
        let closedProfile = closesProfile ? profile + [profile[0]] : profile
        let rings = closedProfile.map { longitudinalPosition, radius in
            (0..<radialSegments).map { index in
                let angle = Float(index) / Float(radialSegments) * .pi * 2
                return SIMD3<Float>(longitudinalPosition, radius * cos(angle), radius * sin(angle))
            }
        }
        return loft(rings: rings, reverse: true, capsEnds: !closesProfile)
    }

    private static func torusX(longitudinalPosition: Float, majorRadius: Float, minorRadius: Float) -> MeshGeometry {
        let profile = (0...20).map { index in
            let angle = Float(index) / 20 * .pi * 2
            return (longitudinalPosition + minorRadius * cos(angle), majorRadius - minorRadius * sin(angle))
        }
        return lathe(profile: Array(profile.dropLast()), radialSegments: 64, closesProfile: true)
    }

    private static func ellipseBoundary(centerX: Float, centerAngle: Float, halfWidth: Float, halfAngle: Float)
        -> [SIMD2<Float>]
    {
        (0..<28).map { index in
            let angle = Float(index) / 28 * .pi * 2
            return SIMD2<Float>(centerX + halfWidth * cos(angle), centerAngle + halfAngle * sin(angle))
        }
    }

    private static func roundedBoundary(
        centerX: Float, centerAngle: Float, halfWidth: Float, halfAngle: Float, corner: Float
    ) -> [SIMD2<Float>] {
        var points: [SIMD2<Float>] = []
        for cornerIndex in 0..<4 {
            let cornerAngle = Float(cornerIndex) * .pi / 2
            let center = SIMD2<Float>(cos(cornerAngle + .pi / 4) > 0 ? 1 : -1, sin(cornerAngle + .pi / 4) > 0 ? 1 : -1)
            for sample in 0...7 {
                let angle = cornerAngle + Float(sample) / 7 * .pi / 2
                points.append(
                    SIMD2<Float>(
                        centerX + halfWidth * (center.x * (1 - corner) + cos(angle) * corner),
                        centerAngle + halfAngle * (center.y * (1 - corner) + sin(angle) * corner)
                    ))
            }
        }
        return points
    }

    private static func bodyPatch(boundary: [SIMD2<Float>], offset: Float) -> MeshGeometry {
        let center = boundary.reduce(SIMD2<Float>.zero, +) / Float(boundary.count)
        let subdivisions = boundary.count <= 6 ? 14 : 3
        var geometry = MeshGeometry()
        for boundaryIndex in boundary.indices {
            let secondCorner = boundary[boundaryIndex]
            let thirdCorner = boundary[(boundaryIndex + 1) % boundary.count]
            var rowIndices: [[UInt32]] = []
            for rowIndex in 0...subdivisions {
                var currentRow: [UInt32] = []
                for columnIndex in 0...(subdivisions - rowIndex) {
                    let coordinate =
                        center
                        + (secondCorner - center) * Float(rowIndex) / Float(subdivisions)
                        + (thirdCorner - center) * Float(columnIndex) / Float(subdivisions)
                    currentRow.append(UInt32(geometry.positions.count))
                    geometry.positions.append(
                        bodyPoint(longitudinalPosition: coordinate.x, angle: coordinate.y, offset: offset))
                }
                rowIndices.append(currentRow)
            }
            for rowIndex in 0..<subdivisions {
                for columnIndex in 0..<(subdivisions - rowIndex) {
                    let firstIndex = rowIndices[rowIndex][columnIndex]
                    let secondIndex = rowIndices[rowIndex + 1][columnIndex]
                    let thirdIndex = rowIndices[rowIndex][columnIndex + 1]
                    geometry.triangles += [firstIndex, secondIndex, thirdIndex]
                    if columnIndex < subdivisions - rowIndex - 1 {
                        geometry.triangles += [secondIndex, rowIndices[rowIndex + 1][columnIndex + 1], thirdIndex]
                    }
                }
            }
        }
        orientOutward(&geometry)
        return geometry
    }

    private static func bodyRing(outer: [SIMD2<Float>], inner: [SIMD2<Float>], offset: Float) -> MeshGeometry {
        var geometry = MeshGeometry()
        let subdivisions = 12
        for boundaryIndex in outer.indices {
            let nextIndex = (boundaryIndex + 1) % outer.count
            for edgeIndex in 0..<subdivisions {
                let firstFraction = Float(edgeIndex) / Float(subdivisions)
                let secondFraction = Float(edgeIndex + 1) / Float(subdivisions)
                let coordinates = [
                    outer[boundaryIndex] + (outer[nextIndex] - outer[boundaryIndex]) * firstFraction,
                    outer[boundaryIndex] + (outer[nextIndex] - outer[boundaryIndex]) * secondFraction,
                    inner[boundaryIndex] + (inner[nextIndex] - inner[boundaryIndex]) * secondFraction,
                    inner[boundaryIndex] + (inner[nextIndex] - inner[boundaryIndex]) * firstFraction,
                ]
                let firstVertex = UInt32(geometry.positions.count)
                geometry.positions += coordinates.map {
                    bodyPoint(longitudinalPosition: $0.x, angle: $0.y, offset: offset)
                }
                geometry.triangles += [
                    firstVertex, firstVertex + 1, firstVertex + 2, firstVertex, firstVertex + 2, firstVertex + 3,
                ]
            }
        }
        orientOutward(&geometry)
        return geometry
    }

    private static func orientOutward(_ geometry: inout MeshGeometry) {
        guard geometry.triangles.count >= 3 else { return }
        let first = geometry.positions[Int(geometry.triangles[0])]
        let second = geometry.positions[Int(geometry.triangles[1])]
        let third = geometry.positions[Int(geometry.triangles[2])]
        let normal = simd_cross(second - first, third - first)
        let radialDirection = SIMD3<Float>(0, first.y, first.z)
        if simd_dot(normal, radialDirection) < 0 {
            for index in stride(from: 0, to: geometry.triangles.count, by: 3) {
                geometry.triangles.swapAt(index + 1, index + 2)
            }
        }
    }

    private static func prism(polygon: [SIMD2<Float>], halfDepth: Float) -> MeshGeometry {
        let front = polygon.map { SIMD3<Float>($0.x, $0.y, halfDepth) }
        let back = polygon.map { SIMD3<Float>($0.x, $0.y, -halfDepth) }
        var geometry = MeshGeometry(positions: front + back)
        let count = polygon.count
        for index in 1..<(count - 1) {
            geometry.triangles += [
                0, UInt32(index), UInt32(index + 1), UInt32(count), UInt32(count + index + 1), UInt32(count + index),
            ]
        }
        for index in 0..<count {
            let next = (index + 1) % count
            geometry.triangles += [
                UInt32(index), UInt32(count + index), UInt32(count + next), UInt32(index), UInt32(count + next),
                UInt32(next),
            ]
        }
        return geometry
    }

    private static func fanBlade(index: Int, count: Int) -> MeshGeometry {
        let baseAngle = Float(index) / Float(count) * .pi * 2
        let polarOutline: [(Float, Float)] = [
            (0.091, -0.16), (0.18, -0.05), (0.315, 0.30), (0.32, 0.50), (0.19, 0.22), (0.095, 0.19),
        ]
        let front = polarOutline.map { radius, angularOffset in
            let angle = baseAngle + angularOffset
            return SIMD3<Float>(0.69 + (radius - 0.09) * 0.12, radius * cos(angle), radius * sin(angle))
        }
        let back = front.map { $0 - SIMD3<Float>(0.016, 0, 0) }
        var geometry = MeshGeometry(positions: front + back)
        let vertexCount = front.count
        let faceTriangles = triangulatePolygon(front.map { SIMD2<Float>($0.y, $0.z) })
        for triangleOffset in stride(from: 0, to: faceTriangles.count, by: 3) {
            let firstIndex = faceTriangles[triangleOffset]
            let secondIndex = faceTriangles[triangleOffset + 1]
            let thirdIndex = faceTriangles[triangleOffset + 2]
            geometry.triangles += [
                firstIndex, secondIndex, thirdIndex,
                UInt32(vertexCount) + firstIndex, UInt32(vertexCount) + thirdIndex, UInt32(vertexCount) + secondIndex,
            ]
        }
        for vertexIndex in 0..<vertexCount {
            let next = (vertexIndex + 1) % vertexCount
            geometry.triangles += [
                UInt32(vertexIndex), UInt32(vertexCount + vertexIndex), UInt32(vertexCount + next), UInt32(vertexIndex),
                UInt32(vertexCount + next), UInt32(next),
            ]
        }
        return geometry
    }

    private static func triangulatePolygon(_ positions: [SIMD2<Float>]) -> [UInt32] {
        func signedArea(_ first: SIMD2<Float>, _ second: SIMD2<Float>, _ third: SIMD2<Float>) -> Float {
            (second.x - first.x) * (third.y - first.y) - (second.y - first.y) * (third.x - first.x)
        }
        var remainingIndices = Array(positions.indices)
        var triangles: [UInt32] = []
        while remainingIndices.count > 3 {
            var clippedEar = false
            for candidateOffset in remainingIndices.indices {
                let previousIndex = remainingIndices[
                    (candidateOffset + remainingIndices.count - 1) % remainingIndices.count]
                let candidateIndex = remainingIndices[candidateOffset]
                let nextIndex = remainingIndices[(candidateOffset + 1) % remainingIndices.count]
                let firstPosition = positions[previousIndex]
                let secondPosition = positions[candidateIndex]
                let thirdPosition = positions[nextIndex]
                guard signedArea(firstPosition, secondPosition, thirdPosition) > 0.00000001 else { continue }
                let containsAnotherVertex = remainingIndices.contains { vertexIndex in
                    guard vertexIndex != previousIndex && vertexIndex != candidateIndex && vertexIndex != nextIndex
                    else { return false }
                    let vertex = positions[vertexIndex]
                    return signedArea(firstPosition, secondPosition, vertex) >= 0
                        && signedArea(secondPosition, thirdPosition, vertex) >= 0
                        && signedArea(thirdPosition, firstPosition, vertex) >= 0
                }
                guard !containsAnotherVertex else { continue }
                triangles += [UInt32(previousIndex), UInt32(candidateIndex), UInt32(nextIndex)]
                remainingIndices.remove(at: candidateOffset)
                clippedEar = true
                break
            }
            precondition(clippedEar, "Authored aircraft polygon must remain simple and counterclockwise")
        }
        triangles += remainingIndices.map(UInt32.init)
        return triangles
    }

    private static func tube(points: [SIMD3<Float>], radius: Float, sides: Int) -> MeshGeometry {
        let rings = points.indices.map { index in
            let previous = points[max(0, index - 1)]
            let next = points[min(points.count - 1, index + 1)]
            let tangent = simd_normalize(next - previous)
            let reference: SIMD3<Float> = abs(tangent.y) < 0.9 ? [0, 1, 0] : [0, 0, 1]
            let firstNormal = simd_normalize(simd_cross(tangent, reference))
            let secondNormal = simd_cross(tangent, firstNormal)
            return (0..<sides).map { sideIndex in
                let angle = Float(sideIndex) / Float(sides) * .pi * 2
                return points[index] + radius * (firstNormal * cos(angle) + secondNormal * sin(angle))
            }
        }
        return loft(rings: rings, reverse: true)
    }

    private static func mesh(_ geometry: MeshGeometry, diagnostic: String) throws -> MeshResource {
        var descriptor = MeshDescriptor(name: diagnostic)
        descriptor.positions = MeshBuffers.Positions(geometry.positions)
        descriptor.primitives = .triangles(geometry.triangles)
        var normals = Array(repeating: SIMD3<Float>.zero, count: geometry.positions.count)
        for index in stride(from: 0, to: geometry.triangles.count, by: 3) {
            let first = Int(geometry.triangles[index])
            let second = Int(geometry.triangles[index + 1])
            let third = Int(geometry.triangles[index + 2])
            let faceNormal = simd_cross(
                geometry.positions[second] - geometry.positions[first],
                geometry.positions[third] - geometry.positions[first])
            if simd_length_squared(faceNormal) > 0.0000000001 {
                normals[first] += faceNormal
                normals[second] += faceNormal
                normals[third] += faceNormal
            }
        }
        descriptor.normals = MeshBuffers.Normals(
            normals.map { normal in
                simd_length_squared(normal) > 0.0000000001 ? simd_normalize(normal) : SIMD3<Float>(0, 1, 0)
            })
        return try MeshResource.generate(from: [descriptor])
    }
}
