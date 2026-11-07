import Foundation

nonisolated enum PaceDictationCaptureMode: Equatable {
    case pushToTalk
    case handsFree
}

nonisolated enum PaceUtteranceEndpointReason: Equatable {
    case speechPause
    case noSpeech
    case maximumDuration
}

nonisolated struct PaceUtteranceEndpointConfiguration {
    var minimumSpeechRMS: Float = 0.006
    var minimumSilenceRMS: Float = 0.003
    var speechToNoiseRatio: Float = 3
    var silenceToNoiseRatio: Float = 1.7
    var minimumSpeechDuration: TimeInterval = 0.12
    var trailingSilenceDuration: TimeInterval = 1
    var noSpeechTimeout: TimeInterval = 8
    var maximumDuration: TimeInterval = 45
}

nonisolated struct PaceUtteranceEndpointDetector {
    let captureMode: PaceDictationCaptureMode
    let captureSessionIdentifier: UUID
    let configuration: PaceUtteranceEndpointConfiguration
    private(set) var hasDetectedSpeech = false
    private(set) var hasFinished = false
    private var elapsedDuration: TimeInterval = 0
    private var consecutiveSpeechDuration: TimeInterval = 0
    private var trailingSilenceDuration: TimeInterval = 0
    private var noiseFloorRMS: Float = 0.001

    init(
        captureMode: PaceDictationCaptureMode,
        captureSessionIdentifier: UUID = UUID(),
        configuration: PaceUtteranceEndpointConfiguration = PaceUtteranceEndpointConfiguration()
    ) {
        self.captureMode = captureMode
        self.captureSessionIdentifier = captureSessionIdentifier
        self.configuration = configuration
    }

    mutating func observe(
        rootMeanSquare: Float,
        audioDuration: TimeInterval,
        captureSessionIdentifier: UUID
    ) -> PaceUtteranceEndpointReason? {
        guard captureMode == .handsFree, !hasFinished, self.captureSessionIdentifier == captureSessionIdentifier,
            rootMeanSquare.isFinite, rootMeanSquare >= 0,
            audioDuration.isFinite, audioDuration > 0, audioDuration <= 0.25
        else { return nil }
        elapsedDuration += audioDuration

        let speechThreshold = max(configuration.minimumSpeechRMS, noiseFloorRMS * configuration.speechToNoiseRatio)
        let silenceThreshold = max(configuration.minimumSilenceRMS, noiseFloorRMS * configuration.silenceToNoiseRatio)
        if rootMeanSquare >= speechThreshold {
            consecutiveSpeechDuration += audioDuration
            if consecutiveSpeechDuration >= configuration.minimumSpeechDuration {
                hasDetectedSpeech = true
            }
            trailingSilenceDuration = 0
        } else {
            consecutiveSpeechDuration = 0
            let adaptationWeight = Float(audioDuration / (0.5 + audioDuration))
            noiseFloorRMS += (rootMeanSquare - noiseFloorRMS) * adaptationWeight
            if rootMeanSquare <= silenceThreshold, hasDetectedSpeech {
                trailingSilenceDuration += audioDuration
            } else {
                trailingSilenceDuration = 0
            }
        }

        let reason: PaceUtteranceEndpointReason?
        if elapsedDuration >= configuration.maximumDuration {
            reason = .maximumDuration
        } else if !hasDetectedSpeech, elapsedDuration >= configuration.noSpeechTimeout {
            reason = .noSpeech
        } else if hasDetectedSpeech, trailingSilenceDuration >= configuration.trailingSilenceDuration {
            reason = .speechPause
        } else {
            reason = nil
        }
        if reason != nil { hasFinished = true }
        return reason
    }
}

@MainActor
final class PaceHandsFreeCaptureEndpoint {
    private var detector: PaceUtteranceEndpointDetector
    private var onEndOfUtterance: ((PaceUtteranceEndpointReason) -> Void)?

    var hasDetectedSpeech: Bool { detector.hasDetectedSpeech }

    init(
        captureMode: PaceDictationCaptureMode,
        captureSessionIdentifier: UUID,
        onEndOfUtterance: @escaping (PaceUtteranceEndpointReason) -> Void
    ) {
        self.detector = PaceUtteranceEndpointDetector(
            captureMode: captureMode, captureSessionIdentifier: captureSessionIdentifier)
        self.onEndOfUtterance = onEndOfUtterance
    }

    func observe(rootMeanSquare: Float, audioDuration: TimeInterval, captureSessionIdentifier: UUID) {
        guard onEndOfUtterance != nil else { return }
        if let reason = detector.observe(
            rootMeanSquare: rootMeanSquare, audioDuration: audioDuration,
            captureSessionIdentifier: captureSessionIdentifier)
        {
            finish(reason: reason, captureSessionIdentifier: captureSessionIdentifier)
        }
    }

    func finish(reason: PaceUtteranceEndpointReason, captureSessionIdentifier: UUID) {
        guard detector.captureMode == .handsFree,
            detector.captureSessionIdentifier == captureSessionIdentifier,
            let callback = onEndOfUtterance
        else { return }
        onEndOfUtterance = nil
        callback(reason)
    }

    func cancel() {
        onEndOfUtterance = nil
    }
}
