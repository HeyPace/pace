import CoreGraphics
import Foundation
import simd

nonisolated enum PaceFigureCameraFraming {
    static let verticalFieldOfViewInDegrees: Float = 35
    static let minimumCameraDistance: Float = 2.6
    static let framingMargin: Float = 1.12

    struct Bounds {
        var minimum: SIMD3<Float>
        var maximum: SIMD3<Float>

        var corners: [SIMD3<Float>] {
            [minimum.x, maximum.x].flatMap { horizontal in
                [minimum.y, maximum.y].flatMap { vertical in
                    [minimum.z, maximum.z].map { depth in
                        SIMD3(horizontal, vertical, depth)
                    }
                }
            }
        }

        var isValid: Bool {
            let coordinates = [minimum.x, minimum.y, minimum.z, maximum.x, maximum.y, maximum.z]
            return coordinates.allSatisfy(\.isFinite)
                && minimum.x <= maximum.x && minimum.y <= maximum.y && minimum.z <= maximum.z
                && minimum != maximum
        }

        mutating func includeSphere(center: SIMD3<Float>, radius: Float) {
            minimum = simd_min(minimum, center - SIMD3(repeating: radius))
            maximum = simd_max(maximum, center + SIMD3(repeating: radius))
        }
    }

    static func cameraDistance(
        for bounds: Bounds,
        orientation: simd_quatf,
        viewportSize: CGSize
    ) -> Float? {
        let orientationLengthSquared = simd_length_squared(orientation.vector)
        guard bounds.isValid,
            viewportSize.width.isFinite, viewportSize.height.isFinite,
            viewportSize.width > 0, viewportSize.height > 0,
            orientation.vector.x.isFinite, orientation.vector.y.isFinite,
            orientation.vector.z.isFinite, orientation.vector.w.isFinite,
            orientationLengthSquared.isFinite, orientationLengthSquared > 0
        else { return nil }

        let aspectRatio = Float(viewportSize.width / viewportSize.height)
        let verticalTangent = tan(verticalFieldOfViewInDegrees * .pi / 360)
        let horizontalTangent = verticalTangent * aspectRatio
        guard horizontalTangent.isFinite, horizontalTangent > 0 else { return nil }

        let normalizedOrientation = simd_normalize(orientation)
        var distance = minimumCameraDistance
        for corner in bounds.corners {
            let rotatedCorner = normalizedOrientation.act(corner)
            // A camera at +Z must fit each corner at its own depth; fitting
            // only width/height at the origin clips the near side on rotation.
            distance = max(
                distance,
                rotatedCorner.z + abs(rotatedCorner.x) * framingMargin / horizontalTangent,
                rotatedCorner.z + abs(rotatedCorner.y) * framingMargin / verticalTangent
            )
        }
        return distance.isFinite ? distance : nil
    }
}
