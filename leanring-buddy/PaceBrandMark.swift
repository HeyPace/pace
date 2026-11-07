import AppKit
import SwiftUI

struct PaceBrandMark: View {
    var body: some View {
        GeometryReader { geometry in
            let strokeWidth = min(geometry.size.width, geometry.size.height) * 3.5 / 32
            ZStack {
                PaceBrandMarkOutline()
                    .stroke(style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round, lineJoin: .round))
                Path { path in
                    path.move(to: CGPoint(x: geometry.size.width * 15 / 32, y: geometry.size.height * 13.4 / 32))
                    path.addLine(to: CGPoint(x: geometry.size.width * 19.7 / 32, y: geometry.size.height * 11.3 / 32))
                }
                .stroke(style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round))
                .opacity(0.5)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }

    @MainActor
    static func menuBarImage() -> NSImage? {
        let renderer = ImageRenderer(content: PaceBrandMark().foregroundStyle(.black).frame(width: 18, height: 18))
        renderer.scale = 2
        let image = renderer.nsImage
        image?.isTemplate = true
        image?.accessibilityDescription = "Pace"
        return image
    }
}

private struct PaceBrandMarkOutline: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 9, y: 27))
        path.addLine(to: CGPoint(x: 9, y: 13))
        path.addCurve(to: CGPoint(x: 17, y: 5), control1: CGPoint(x: 9, y: 8.582), control2: CGPoint(x: 12.582, y: 5))
        path.addCurve(to: CGPoint(x: 25, y: 13), control1: CGPoint(x: 21.418, y: 5), control2: CGPoint(x: 25, y: 8.582))
        path.addCurve(
            to: CGPoint(x: 17, y: 21), control1: CGPoint(x: 25, y: 17.418), control2: CGPoint(x: 21.418, y: 21))
        path.addLine(to: CGPoint(x: 16, y: 21))
        return path.applying(
            CGAffineTransform(scaleX: rect.width / 32, y: rect.height / 32)
                .concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY)))
    }
}
