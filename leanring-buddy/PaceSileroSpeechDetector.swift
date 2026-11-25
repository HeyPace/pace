import Foundation
import SileroVAD

nonisolated enum PaceSileroSpeechDetector {
    // Short PTT utterances need speech confirmation, not amplitude heuristics.
    // Keep original audio intact; the classifier only rejects all-silence input.
    static func containsSpeech(
        in samples: [Float], minimumProbability: Float = 0.35, minimumConsecutiveFrames: Int = 2
    ) throws -> Bool {
        guard !samples.isEmpty else { return false }
        let detector = try SileroVAD()
        var speechFrames = 0
        var offset = 0
        while offset < samples.count {
            let end = min(offset + SileroVAD.chunkSize, samples.count)
            var chunk = Array(samples[offset..<end])
            chunk.append(contentsOf: repeatElement(0, count: SileroVAD.chunkSize - chunk.count))
            let probability = try detector.process(chunk)
            speechFrames = probability >= minimumProbability ? speechFrames + 1 : 0
            if speechFrames >= minimumConsecutiveFrames { return true }
            offset = end
        }
        return false
    }
}
