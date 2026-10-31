// Compile with PaceBrandMark.swift to keep every raster icon on the native mark geometry.
import AppKit
import SwiftUI

private struct PaceIconArtwork: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.205, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.14, green: 0.15, blue: 0.17), Color(red: 0.045, green: 0.05, blue: 0.06),
                        ],
                        startPoint: .topLeading, endPoint: .bottomTrailing)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: size * 0.205, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: max(0.5, size / 1024))
                }
                .frame(width: size * 0.875, height: size * 0.875)
            PaceBrandMark()
                .foregroundStyle(Color(red: 0.92, green: 0.94, blue: 0.97))
                .frame(width: size * 0.53, height: size * 0.53)
                .offset(x: -size * 0.016)
        }
        .frame(width: size, height: size)
    }
}

@main
struct RenderPaceIcons {
    @MainActor
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            throw NSError(
                domain: "RenderPaceIcons", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Pass the Pace repository root."])
        }
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        func png(size: Int) throws -> Data {
            let renderer = ImageRenderer(content: PaceIconArtwork(size: CGFloat(size)))
            renderer.scale = 1
            guard let image = renderer.cgImage else { throw NSError(domain: "RenderPaceIcons", code: 2) }
            let bitmap = NSBitmapImageRep(cgImage: image)
            guard let data = bitmap.representation(using: .png, properties: [:]) else {
                throw NSError(domain: "RenderPaceIcons", code: 3)
            }
            return data
        }
        for size in [16, 32, 64, 128, 256, 512, 1024] {
            try png(size: size).write(
                to: root.appendingPathComponent("leanring-buddy/Assets.xcassets/AppIcon.appiconset/\(size)-mac.png"))
        }
        try png(size: 180).write(to: root.appendingPathComponent("website/public/apple-touch-icon.png"))
        let favicon = try png(size: 32)
        var icon = Data([0, 0, 1, 0, 1, 0, 32, 32, 0, 0, 1, 0, 32, 0])
        var byteCount = UInt32(favicon.count).littleEndian
        var offset = UInt32(22).littleEndian
        withUnsafeBytes(of: &byteCount) { icon.append(contentsOf: $0) }
        withUnsafeBytes(of: &offset) { icon.append(contentsOf: $0) }
        icon.append(favicon)
        try icon.write(to: root.appendingPathComponent("website/public/favicon.ico"))
        let svg =
            ##"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32" role="img" aria-label="Pace"><rect width="32" height="32" rx="7" fill="#101114"/><g fill="none" stroke="#ebeff7" stroke-width="3.5" stroke-linecap="round" stroke-linejoin="round"><path d="M9 27V13a8 8 0 1 1 8 8h-1"/><path d="M15 13.4l4.7-2.1" opacity=".5"/></g></svg>"##
        for filename in ["icon.svg", "favicon.svg"] {
            try svg.write(
                to: root.appendingPathComponent("website/public/\(filename)"), atomically: true, encoding: .utf8)
        }
        print("Rendered seven native app icon sizes and web identity assets.")
    }
}
