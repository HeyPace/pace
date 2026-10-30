import CoreGraphics
import Foundation
import Testing
import simd

@testable import Pace

struct PaceFigureCameraFramingTests {
    @Test func uprightAircraftRegressionFitsAfterRotationInWideAndNarrowViewports() throws {
        let bounds = PaceFigureCameraFraming.Bounds(minimum: [-0.9, -0.15, -0.8], maximum: [0.9, 0.15, 0.8])
        let upright = simd_quatf(angle: .pi / 2, axis: [0, 0, 1])
        let verticalTangent = tan(PaceFigureCameraFraming.verticalFieldOfViewInDegrees * .pi / 360)
        let oldProjectedHeight = 0.9 / (2.6 - 0.8) / verticalTangent
        #expect(oldProjectedHeight > 1)

        for viewport in [CGSize(width: 1120, height: 540), CGSize(width: 360, height: 540)] {
            let distance = try #require(
                PaceFigureCameraFraming.cameraDistance(for: bounds, orientation: upright, viewportSize: viewport))
            #expect(distance > PaceFigureCameraFraming.minimumCameraDistance)
            assertCornersFit(bounds, orientation: upright, viewport: viewport, distance: distance)
        }
    }

    @Test func allCornersFitAcrossOrbitAnglesAndAspectRatios() throws {
        let bounds = PaceFigureCameraFraming.Bounds(minimum: [-0.9, -0.35, -0.75], maximum: [0.8, 0.4, 0.9])
        for viewport in [
            CGSize(width: 300, height: 500), CGSize(width: 640, height: 480), CGSize(width: 1120, height: 500),
        ] {
            for horizontalAngle in stride(from: Float.zero, through: .pi * 2, by: .pi / 6) {
                for verticalAngle in stride(from: -Float.pi / 2, through: .pi / 2, by: .pi / 6) {
                    let orientation =
                        simd_quatf(angle: verticalAngle, axis: [1, 0, 0])
                        * simd_quatf(angle: horizontalAngle, axis: [0, 1, 0])
                    let distance = try #require(
                        PaceFigureCameraFraming.cameraDistance(
                            for: bounds, orientation: orientation, viewportSize: viewport))
                    assertCornersFit(bounds, orientation: orientation, viewport: viewport, distance: distance)
                }
            }
        }
    }

    @Test func narrowViewportMovesCameraBackAndUserZoomStillMagnifies() throws {
        let bounds = PaceFigureCameraFraming.Bounds(minimum: [-0.9, -0.4, -0.3], maximum: [0.9, 0.4, 0.3])
        let orientation = simd_quatf(angle: 0, axis: [0, 1, 0])
        let wideDistance = try #require(
            PaceFigureCameraFraming.cameraDistance(
                for: bounds, orientation: orientation, viewportSize: CGSize(width: 1120, height: 500)))
        let narrowDistance = try #require(
            PaceFigureCameraFraming.cameraDistance(
                for: bounds, orientation: orientation, viewportSize: CGSize(width: 300, height: 500)))
        #expect(narrowDistance > wideDistance)

        let point = SIMD3<Float>(0.9, 0, 0.3)
        let restingProjection = point.x / (wideDistance - point.z)
        let zoomedPoint = point * 1.8
        let zoomedProjection = zoomedPoint.x / (wideDistance - zoomedPoint.z)
        #expect(zoomedProjection > restingProjection * 1.8)
    }

    @Test func invalidBoundsViewportOrOrientationCannotMoveTheCamera() {
        let bounds = PaceFigureCameraFraming.Bounds(minimum: [-1, -1, -1], maximum: [1, 1, 1])
        let orientation = simd_quatf(angle: 0, axis: [0, 1, 0])
        for viewport in [CGSize.zero, CGSize(width: -1, height: 300), CGSize(width: .infinity, height: 300)] {
            #expect(
                PaceFigureCameraFraming.cameraDistance(for: bounds, orientation: orientation, viewportSize: viewport)
                    == nil)
        }
        for invalidBounds in [
            PaceFigureCameraFraming.Bounds(minimum: [.nan, 0, 0], maximum: [1, 1, 1]),
            PaceFigureCameraFraming.Bounds(minimum: [2, 0, 0], maximum: [1, 1, 1]),
            PaceFigureCameraFraming.Bounds(minimum: .zero, maximum: .zero),
        ] {
            #expect(
                PaceFigureCameraFraming.cameraDistance(
                    for: invalidBounds, orientation: orientation, viewportSize: CGSize(width: 640, height: 480)) == nil)
        }
        #expect(
            PaceFigureCameraFraming.cameraDistance(
                for: bounds, orientation: simd_quatf(vector: .zero), viewportSize: CGSize(width: 640, height: 480))
                == nil)
    }

    @Test func hingeEnvelopeIncludesAnyControlSurfaceOrientation() {
        var bounds = PaceFigureCameraFraming.Bounds(minimum: [-1, -0.1, -0.4], maximum: [1, 0.1, 0.4])
        bounds.includeSphere(center: [0.5, 0, 0], radius: 0.3)
        #expect(bounds.minimum.y <= -0.3)
        #expect(bounds.maximum.y >= 0.3)
        #expect(bounds.minimum.x == -1)
        #expect(bounds.maximum.x == 1)
    }

    private func assertCornersFit(
        _ bounds: PaceFigureCameraFraming.Bounds,
        orientation: simd_quatf,
        viewport: CGSize,
        distance: Float
    ) {
        let verticalTangent = tan(PaceFigureCameraFraming.verticalFieldOfViewInDegrees * .pi / 360)
        let horizontalTangent = verticalTangent * Float(viewport.width / viewport.height)
        for corner in bounds.corners {
            let point = orientation.act(corner)
            let depth = distance - point.z
            #expect(depth > 0)
            #expect(abs(point.x / depth / horizontalTangent) <= 1 / PaceFigureCameraFraming.framingMargin + 0.0001)
            #expect(abs(point.y / depth / verticalTangent) <= 1 / PaceFigureCameraFraming.framingMargin + 0.0001)
        }
    }
}
