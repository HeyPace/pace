import AppKit
import Darwin
import Foundation

@main
struct GeneratedSVGOverlayProbe {
    @MainActor
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.count == 2, arguments[0] == "--inspect-image" {
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: arguments[1]))
                guard let bitmap = NSBitmapImageRep(data: data), bitmap.pixelsWide > 0, bitmap.pixelsHigh > 0 else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                let corners = [
                    (0, 0), (bitmap.pixelsWide - 1, 0), (0, bitmap.pixelsHigh - 1),
                    (bitmap.pixelsWide - 1, bitmap.pixelsHigh - 1),
                ]
                let cornerAlphas = try corners.map { pixelX, pixelY -> Double in
                    guard let color = bitmap.colorAt(x: pixelX, y: pixelY)?.usingColorSpace(.deviceRGB) else {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                    return Double(color.alphaComponent)
                }
                var bluePixels = 0
                for pixelY in 0..<bitmap.pixelsHigh {
                    for pixelX in 0..<bitmap.pixelsWide {
                        guard let color = bitmap.colorAt(x: pixelX, y: pixelY)?.usingColorSpace(.deviceRGB) else {
                            continue
                        }
                        if color.alphaComponent > 0.9, color.redComponent > 0.2, color.redComponent < 0.6,
                            color.greenComponent > 0.5, color.greenComponent < 0.9, color.blueComponent > 0.85
                        {
                            bluePixels += 1
                        }
                    }
                }
                let passed = cornerAlphas.allSatisfy { $0 == 0 } && bluePixels > 100
                try emitJSON([
                    "passed": passed, "width": bitmap.pixelsWide, "height": bitmap.pixelsHigh,
                    "cornerAlpha": cornerAlphas, "bluePixels": bluePixels,
                ])
                exit(passed ? EXIT_SUCCESS : EXIT_FAILURE)
            } catch {
                try? emitJSON(["passed": false, "error": error.localizedDescription])
                exit(EXIT_FAILURE)
            }
        }
        guard arguments.count == 4, arguments[0] == "--ready-json", arguments[2] == "--stop-marker" else {
            FileHandle.standardError.write(
                Data("Expected --ready-json PATH --stop-marker PATH or --inspect-image PATH\n".utf8))
            exit(EXIT_FAILURE)
        }
        let readyURL = URL(fileURLWithPath: arguments[1])
        let stopMarkerURL = URL(fileURLWithPath: arguments[3])
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        Task { @MainActor in
            let renderer = PaceGeneratedSVGRenderer()
            let panel = NSPanel(
                contentRect: CGRect(x: 60, y: 80, width: 240, height: 320),
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.level = .floating
            panel.title = "Pace generated SVG regression probe"
            do {
                let markup =
                    "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 240 320'><circle cx='120' cy='160' r='30' fill='#63c5ff'/></svg>"
                guard let drawing = PaceGeneratedSVG.parse(markup) else { throw CocoaError(.fileReadCorruptFile) }
                try await renderer.prepare(drawing)
                panel.contentView = renderer.view
                panel.orderFrontRegardless()
                try await Task.sleep(for: .milliseconds(200))
                guard panel.isVisible, panel.windowNumber > 0 else { throw CocoaError(.fileReadUnknown) }
                let ready: [String: Any] = [
                    "status": "ready", "pid": Int(ProcessInfo.processInfo.processIdentifier),
                    "windowID": panel.windowNumber, "width": 240, "height": 320,
                ]
                try JSONSerialization.data(withJSONObject: ready, options: [.sortedKeys]).write(
                    to: readyURL, options: .atomic)
                let deadline = Date().addingTimeInterval(10)
                while !FileManager.default.fileExists(atPath: stopMarkerURL.path), Date() < deadline {
                    try await Task.sleep(for: .milliseconds(100))
                }
            } catch {
                let failure: [String: Any] = ["status": "failed", "error": error.localizedDescription]
                try? JSONSerialization.data(withJSONObject: failure, options: [.sortedKeys]).write(
                    to: readyURL, options: .atomic)
            }
            renderer.stop()
            panel.orderOut(nil)
            panel.close()
            application.terminate(nil)
        }
        application.run()
    }

    private static func emitJSON(_ value: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0a]))
    }
}
