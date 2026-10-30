import Foundation
import simd

nonisolated struct PaceFigureScene: Codable, Equatable, Sendable {
    enum Template: String, Codable, Sendable { case airplane }
    enum Geometry: String, Codable, Sendable { case box, ellipsoid, cylinder, cone, mesh }
    enum Finish: String, Codable, Sendable { case shell, metal, glass, accent, dark }

    enum Viewpoint: String, Codable, CaseIterable, Sendable {
        case threeQuarter = "three_quarter"
        case side, top, front, rear, underside

        var orientation: simd_quatf {
            switch self {
            case .threeQuarter:
                return simd_quatf(angle: .pi / 7, axis: [1, 0, 0])
                    * simd_quatf(angle: -.pi / 5, axis: [0, 1, 0])
            case .side: return simd_quatf(angle: 0, axis: [0, 1, 0])
            case .top: return simd_quatf(angle: .pi / 2, axis: [1, 0, 0])
            case .front: return simd_quatf(angle: -.pi / 2, axis: [0, 1, 0])
            case .rear: return simd_quatf(angle: .pi / 2, axis: [0, 1, 0])
            case .underside: return simd_quatf(angle: -.pi / 2, axis: [1, 0, 0])
            }
        }
    }

    struct Part: Codable, Equatable, Sendable {
        let id: String
        let nodeID: String
        let geometry: Geometry
        let position: [Double]
        let size: [Double]
        var rotation: [Double]? = nil
        var finish: Finish? = nil
        var vertices: [[Double]]? = nil
        var triangles: [Int]? = nil
    }

    var template: Template? = nil
    var parts: [Part]? = nil
    var focusNodeID: String? = nil
    var viewpoint: Viewpoint? = nil
    var controlDeflection: Double? = nil

    static let airplaneNodeIDs: Set<String> = [
        "fuselage", "cockpit", "wings", "engines", "ailerons", "elevators", "rudder", "flaps",
    ]
    static let airplaneControlSurfaceNodeIDs: Set<String> = ["ailerons", "elevators", "rudder", "flaps"]

    func hasSameGeometry(as other: Self) -> Bool {
        template == other.template && (parts ?? []) == (other.parts ?? [])
    }

    func validationIssue(nodeIDs: Set<String>) -> String? {
        if let focusNodeID, !nodeIDs.contains(focusNodeID) {
            return "requires the figure focus to reference an existing part"
        }
        if let controlDeflection {
            guard controlDeflection.isFinite, (-1...1).contains(controlDeflection), template == .airplane else {
                return "requires a finite control deflection from -1 to 1 on the airplane template"
            }
            if controlDeflection != 0, !Self.airplaneControlSurfaceNodeIDs.contains(focusNodeID ?? "") {
                return "requires a selected aileron, elevator, rudder or flap assembly for nonzero deflection"
            }
        }
        if template == .airplane {
            guard nodeIDs == Self.airplaneNodeIDs, parts?.isEmpty ?? true else {
                return
                    "requires airplane explanations for fuselage, cockpit, wings, engines, ailerons, elevators, rudder and flaps"
            }
            return nil
        }
        guard let parts, (1...96).contains(parts.count), Set(parts.map(\.id)).count == parts.count else {
            return "requires one to ninety-six uniquely identified solid parts"
        }
        var referencedNodeIDs: Set<String> = []
        var totalVertexCount = 0
        for part in parts {
            guard !part.id.isEmpty, part.id.count <= 60,
                part.id.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" }
                ),
                nodeIDs.contains(part.nodeID), Self.validVector(part.position, in: -12...12),
                Self.validVector(part.size, in: 0.005...12),
                part.rotation.map({ Self.validVector($0, in: -360...360) }) ?? true
            else { return "requires bounded finite solid transforms and a valid explanation ID for every solid" }
            referencedNodeIDs.insert(part.nodeID)
            if part.geometry == .mesh {
                guard let vertices = part.vertices, (3...256).contains(vertices.count),
                    vertices.allSatisfy({ Self.validVector($0, in: -1...1) }),
                    let triangles = part.triangles, (3...1536).contains(triangles.count),
                    triangles.count.isMultiple(of: 3),
                    triangles.allSatisfy({ vertices.indices.contains($0) })
                else { return "requires bounded triangle meshes with valid vertex indices" }
                for offset in stride(from: 0, to: triangles.count, by: 3) {
                    let first = vertices[triangles[offset]]
                    let second = vertices[triangles[offset + 1]]
                    let third = vertices[triangles[offset + 2]]
                    let firstEdge = first.indices.map { second[$0] - first[$0] }
                    let secondEdge = first.indices.map { third[$0] - first[$0] }
                    let crossProduct = [
                        firstEdge[1] * secondEdge[2] - firstEdge[2] * secondEdge[1],
                        firstEdge[2] * secondEdge[0] - firstEdge[0] * secondEdge[2],
                        firstEdge[0] * secondEdge[1] - firstEdge[1] * secondEdge[0],
                    ]
                    guard crossProduct.reduce(0, { $0 + $1 * $1 }) > 0.000_000_000_1 else {
                        return "requires nondegenerate mesh triangles"
                    }
                }
                totalVertexCount += vertices.count
            } else if part.vertices != nil || part.triangles != nil {
                return "accepts vertex data only for mesh geometry"
            }
        }
        guard totalVertexCount <= 4096, referencedNodeIDs == nodeIDs else {
            return "requires every explanation to have a visible solid, with at most 4096 custom vertices"
        }
        return nil
    }

    private static func validVector(_ values: [Double], in range: ClosedRange<Double>) -> Bool {
        values.count == 3 && values.allSatisfy { $0.isFinite && range.contains($0) }
    }
}
