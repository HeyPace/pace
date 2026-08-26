import AVFoundation
import Combine
import Foundation

nonisolated struct PacePadRecordedUtterance: Sendable {
    let audioData: Data
    let durationSeconds: TimeInterval
}

@MainActor
final class PacePadAudioRecorder: NSObject, ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var microphonePermissionIsGranted = false

    private var audioRecorder: AVAudioRecorder?
    private var recordingStartedAt: Date?
    private var recordingURL: URL?

    func requestPermission() async {
        microphonePermissionIsGranted = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { permissionWasGranted in
                continuation.resume(returning: permissionWasGranted)
            }
        }
    }

    func startRecording() throws {
        guard microphonePermissionIsGranted else {
            throw PacePadAudioRecorderError.microphonePermissionDenied
        }
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.defaultToSpeaker, .allowBluetoothHFP]
        )
        try audioSession.setActive(true)

        let recordingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pacepad-utterance-\(UUID().uuidString)")
            .appendingPathExtension("m4a")
        let recorder = try AVAudioRecorder(
            url: recordingURL,
            settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
                AVEncoderBitRateKey: 64_000,
            ]
        )
        recorder.prepareToRecord()
        guard
            recorder.record(
                forDuration: PaceCompanionProtocol.maximumUtteranceDurationSeconds
            )
        else {
            try? FileManager.default.removeItem(at: recordingURL)
            throw PacePadAudioRecorderError.recordingCouldNotStart
        }
        recordingStartedAt = Date()
        self.recordingURL = recordingURL
        audioRecorder = recorder
        isRecording = true
    }

    func stopRecording() throws -> PacePadRecordedUtterance {
        guard let audioRecorder, let recordingURL else {
            throw PacePadAudioRecorderError.noRecordingInProgress
        }
        let elapsedRecordingDuration =
            recordingStartedAt.map { Date().timeIntervalSince($0) }
            ?? audioRecorder.currentTime
        let durationSeconds = min(
            max(audioRecorder.currentTime, elapsedRecordingDuration),
            PaceCompanionProtocol.maximumUtteranceDurationSeconds
        )
        audioRecorder.stop()
        deactivateAudioSession()
        self.audioRecorder = nil
        recordingStartedAt = nil
        self.recordingURL = nil
        isRecording = false
        defer { try? FileManager.default.removeItem(at: recordingURL) }
        return PacePadRecordedUtterance(
            audioData: try Data(contentsOf: recordingURL),
            durationSeconds: durationSeconds
        )
    }

    func cancelRecording() {
        audioRecorder?.stop()
        deactivateAudioSession()
        if let recordingURL {
            try? FileManager.default.removeItem(at: recordingURL)
        }
        audioRecorder = nil
        recordingStartedAt = nil
        recordingURL = nil
        isRecording = false
    }

    private func deactivateAudioSession() {
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
    }
}

nonisolated enum PacePadAudioRecorderError: LocalizedError {
    case microphonePermissionDenied
    case recordingCouldNotStart
    case noRecordingInProgress

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            "Microphone access is off. Enable it in Settings to talk to Pace."
        case .recordingCouldNotStart:
            "The iPad microphone could not start recording."
        case .noRecordingInProgress:
            "There is no active recording to send."
        }
    }
}
