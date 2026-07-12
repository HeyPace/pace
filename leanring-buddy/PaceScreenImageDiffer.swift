//
//  PaceScreenImageDiffer.swift
//  leanring-buddy
//
//  Cheap visual-change detection for screen captures. This is the first
//  gate for watch-mode style behavior: if the screen only changed by a
//  cursor blink, tiny animation, or JPEG noise, reuse the previous screen
//  analysis instead of spending a fresh OCR/VLM pass.
//

import AppKit
import Foundation

struct PaceScreenVisualFingerprint: Equatable {
    let width: Int
    let height: Int
    let grayscalePixels: [UInt8]
}

struct PaceScreenImageDiff: Equatable {
    let meanPixelDelta: Double
    let changedPixelRatio: Double

    var isMeaningful: Bool {
        changedPixelRatio >= 0.04 || meanPixelDelta >= 10
    }
}

enum PaceScreenImageDiffer {
    static let defaultFingerprintWidth = 64
    static let defaultFingerprintHeight = 36
    private static let changedPixelDeltaThreshold = 18

    static func fingerprint(
        for imageData: Data,
        width: Int = defaultFingerprintWidth,
        height: Int = defaultFingerprintHeight
    ) -> PaceScreenVisualFingerprint? {
        guard width > 0, height > 0,
              let bitmap = NSBitmapImageRep(data: imageData),
              bitmap.pixelsWide > 0,
              bitmap.pixelsHigh > 0 else {
            return nil
        }

        var grayscalePixels: [UInt8] = []
        grayscalePixels.reserveCapacity(width * height)

        for targetY in 0..<height {
            let sourceY = min(
                bitmap.pixelsHigh - 1,
                max(0, Int(Double(targetY) * Double(bitmap.pixelsHigh) / Double(height)))
            )
            for targetX in 0..<width {
                let sourceX = min(
                    bitmap.pixelsWide - 1,
                    max(0, Int(Double(targetX) * Double(bitmap.pixelsWide) / Double(width)))
                )
                let color = bitmap.colorAt(x: sourceX, y: sourceY) ?? .black
                let red = color.redComponent
                let green = color.greenComponent
                let blue = color.blueComponent
                let luminance = (0.299 * red + 0.587 * green + 0.114 * blue) * 255
                grayscalePixels.append(UInt8(max(0, min(255, Int(luminance.rounded())))))
            }
        }

        return PaceScreenVisualFingerprint(
            width: width,
            height: height,
            grayscalePixels: grayscalePixels
        )
    }

    static func diff(
        from previousFingerprint: PaceScreenVisualFingerprint,
        to currentFingerprint: PaceScreenVisualFingerprint
    ) -> PaceScreenImageDiff? {
        guard previousFingerprint.width == currentFingerprint.width,
              previousFingerprint.height == currentFingerprint.height,
              previousFingerprint.grayscalePixels.count == currentFingerprint.grayscalePixels.count,
              !previousFingerprint.grayscalePixels.isEmpty else {
            return nil
        }

        var totalDelta = 0
        var changedPixelCount = 0
        for pixelIndex in previousFingerprint.grayscalePixels.indices {
            let delta = abs(
                Int(previousFingerprint.grayscalePixels[pixelIndex])
                - Int(currentFingerprint.grayscalePixels[pixelIndex])
            )
            totalDelta += delta
            if delta >= changedPixelDeltaThreshold {
                changedPixelCount += 1
            }
        }

        let pixelCount = previousFingerprint.grayscalePixels.count
        return PaceScreenImageDiff(
            meanPixelDelta: Double(totalDelta) / Double(pixelCount),
            changedPixelRatio: Double(changedPixelCount) / Double(pixelCount)
        )
    }
}
