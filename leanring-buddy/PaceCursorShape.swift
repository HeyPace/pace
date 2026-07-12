//
//  PaceCursorShape.swift
//  leanring-buddy
//
//  The arrowhead shape Pace renders as its on-screen cursor. Extracted
//  from `OverlayWindow.swift` so the file can shrink and so the shape
//  is reachable from any future overlay variation (e.g. settings
//  preview, onboarding screen) without dragging the whole overlay
//  machinery along.
//
//  Pair with a linear-gradient fill and a thin highlight stroke for
//  the full Codex-style effect — see `BlueCursorView` for the canonical
//  styling.
//

import SwiftUI

/// The cursor shape pace uses on screen. Modeled on the sharp,
/// slightly chevron-cut pointer from Codex's CLI — a tall pointer with
/// gently curved flanks and a soft concave notch at the base so it
/// reads as a directional arrowhead rather than a flat triangle.
struct CodexArrowShape: Shape {
    func path(in rect: CGRect) -> Path {
        var arrowPath = Path()

        let arrowWidth = rect.width
        let arrowHeight = rect.height
        let horizontalCenter = rect.midX

        let topPointCoordinate = CGPoint(x: horizontalCenter, y: rect.minY)
        let bottomLeftCoordinate = CGPoint(x: rect.minX + arrowWidth * 0.18, y: rect.maxY)
        let bottomRightCoordinate = CGPoint(x: rect.maxX - arrowWidth * 0.18, y: rect.maxY)
        let bottomNotchCoordinate = CGPoint(x: horizontalCenter, y: rect.maxY - arrowHeight * 0.22)

        // Right flank — slight outward bulge for a refined silhouette
        let rightFlankControl = CGPoint(x: rect.maxX, y: rect.midY + arrowHeight * 0.10)
        // Left flank — mirror of the right
        let leftFlankControl = CGPoint(x: rect.minX, y: rect.midY + arrowHeight * 0.10)

        arrowPath.move(to: topPointCoordinate)
        arrowPath.addQuadCurve(to: bottomRightCoordinate, control: rightFlankControl)
        arrowPath.addLine(to: bottomNotchCoordinate)
        arrowPath.addLine(to: bottomLeftCoordinate)
        arrowPath.addQuadCurve(to: topPointCoordinate, control: leftFlankControl)
        arrowPath.closeSubpath()

        return arrowPath
    }
}
