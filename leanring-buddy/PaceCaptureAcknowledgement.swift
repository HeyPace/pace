import AVFoundation
import Foundation

nonisolated struct PaceCapturedAudio: Equatable, Sendable {
    let captureIdentifier: UUID
    let frameCount: Int
    let recognizedText: String
}

nonisolated enum PaceCaptureStopOutcome: Equatable, Sendable {
    case captured(PaceCapturedAudio)
    case empty
    case ignored
}

nonisolated final class PaceCaptureAcknowledgementGate: @unchecked Sendable {
    private let lock = NSLock()
    private var captureIdentifier: UUID?
    private var receivedFrameCount = 0
    private var hasStopped = false

    @MainActor
    func begin(_ identifier: UUID) {
        lock.withLock {
            captureIdentifier = identifier
            receivedFrameCount = 0
            hasStopped = false
        }
    }

    func receivedProcessedBuffer(_ buffer: AVAudioPCMBuffer, captureIdentifier identifier: UUID) {
        guard buffer.frameLength > 0, buffer.format.channelCount > 0 else { return }
        lock.withLock {
            guard captureIdentifier == identifier, !hasStopped else { return }
            receivedFrameCount += Int(buffer.frameLength)
        }
    }

    @MainActor
    func deliverRecognitionResult(for identifier: UUID, publish: () -> Void) {
        guard lock.withLock({ captureIdentifier == identifier }) else { return }
        publish()
    }

    @MainActor
    func stop(
        _ identifier: UUID, recognizedText: String,
        removeTap: () -> Void, acknowledge: (PaceCapturedAudio) -> Void
    ) -> PaceCaptureStopOutcome {
        guard lock.withLock({ captureIdentifier == identifier && !hasStopped }) else { return .ignored }
        removeTap()
        let outcome: PaceCaptureStopOutcome = lock.withLock {
            guard captureIdentifier == identifier, !hasStopped else { return .ignored }
            hasStopped = true
            guard receivedFrameCount > 0 else { return .empty }
            return .captured(PaceCapturedAudio(captureIdentifier: identifier, frameCount: receivedFrameCount,
                recognizedText: recognizedText.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        if case .captured(let captured) = outcome { acknowledge(captured) }
        return outcome
    }

    @MainActor
    func cancel(_ identifier: UUID) {
        lock.withLock {
            guard captureIdentifier == identifier else { return }
            captureIdentifier = nil
            receivedFrameCount = 0
            hasStopped = true
        }
    }
}
