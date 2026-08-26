import AVFoundation
import Combine
import Foundation

@MainActor
final class PacePadSpeechPlayer: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published private(set) var isSpeaking = false

    var onSpeechFinished: (() -> Void)?

    private let speechSynthesizer = AVSpeechSynthesizer()
    private var activeUtteranceIdentifier: ObjectIdentifier?

    override init() {
        super.init()
        speechSynthesizer.delegate = self
    }

    func speak(_ text: String) {
        stop()
        let audioSession = AVAudioSession.sharedInstance()
        try? audioSession.setCategory(
            .playback,
            mode: .spokenAudio,
            options: [.duckOthers]
        )
        try? audioSession.setActive(true)
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = 0.48
        utterance.pitchMultiplier = 0.92
        utterance.voice =
            AVSpeechSynthesisVoice(language: "en-IN")
            ?? AVSpeechSynthesisVoice(language: "en-US")
        activeUtteranceIdentifier = ObjectIdentifier(utterance)
        isSpeaking = true
        speechSynthesizer.speak(utterance)
    }

    func stop() {
        activeUtteranceIdentifier = nil
        if speechSynthesizer.isSpeaking {
            speechSynthesizer.stopSpeaking(at: .immediate)
        }
        isSpeaking = false
        deactivateAudioSession()
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        let finishedUtteranceIdentifier = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in
            guard let self, activeUtteranceIdentifier == finishedUtteranceIdentifier else {
                return
            }
            activeUtteranceIdentifier = nil
            isSpeaking = false
            deactivateAudioSession()
            onSpeechFinished?()
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        let cancelledUtteranceIdentifier = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in
            guard let self, activeUtteranceIdentifier == cancelledUtteranceIdentifier else {
                return
            }
            activeUtteranceIdentifier = nil
            isSpeaking = false
            deactivateAudioSession()
        }
    }

    private func deactivateAudioSession() {
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
    }
}
