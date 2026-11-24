import Foundation

nonisolated struct PaceRequestFeedback: Equatable {
    let title: String
    let detail: String?
    let elapsedLabel: String?
    let showsSpinner: Bool

    static func resolve(
        state: PaceSignalState, hudDetail: String?, isPreparing: Bool,
        isFinalizing: Bool, startedAt: Date?, now: Date
    ) -> Self {
        let seconds = startedAt.map { max(0, Int(now.timeIntervalSince($0))) }
        let elapsed = seconds.map { $0 < 60 ? "\($0)s" : "\($0 / 60)m \($0 % 60)s" }
        if state == .failed || state == .blocked {
            return Self(
                title: state == .failed ? "Needs attention" : "Request needs attention",
                detail: hudDetail, elapsedLabel: nil, showsSpinner: false)
        }
        if isPreparing || hudDetail == "Starting microphone…" {
            return Self(
                title: "Starting microphone…", detail: "Wait for the listening tone, then speak.",
                elapsedLabel: elapsed, showsSpinner: true)
        }
        if isFinalizing {
            return Self(
                title: "Transcribing…", detail: "Audio received. Turning it into words.", elapsedLabel: elapsed,
                showsSpinner: true)
        }
        switch state {
        case .listening:
            return Self(
                title: "Listening", detail: "Speak naturally. Your words will appear below.", elapsedLabel: elapsed,
                showsSpinner: false)
        case .understanding, .acting:
            let detail: String?
            switch hudDetail {
            case "classifying intent", "planning local action", "checking screen and tools":
                detail = "Understanding your request."
            case "Message received · Working…": detail = "Your message is received."
            case "Heard you · Working…": detail = "I heard you. Working on your request."
            default: detail = hudDetail
            }
            return Self(
                title: (seconds ?? 0) >= 8 ? "Still working…" : "Working on it…",
                detail: detail, elapsedLabel: elapsed, showsSpinner: true)
        case .speaking: return Self(title: "Replying", detail: nil, elapsedLabel: nil, showsSpinner: false)
        case .awaitingApproval:
            return Self(title: "Waiting for your approval", detail: hudDetail, elapsedLabel: nil, showsSpinner: false)
        case .failed: return Self(title: "Needs attention", detail: hudDetail, elapsedLabel: nil, showsSpinner: false)
        case .blocked:
            return Self(title: "Request needs attention", detail: hudDetail, elapsedLabel: nil, showsSpinner: false)
        case .completed: return Self(title: "Done", detail: nil, elapsedLabel: nil, showsSpinner: false)
        case .ready: return Self(title: "Ready", detail: nil, elapsedLabel: nil, showsSpinner: false)
        }
    }
}

enum PaceChatVoiceAction: Equatable {
    case allowMicrophone, allowSpeechRecognition, checkVoiceModel, retryPracticeMicrophone
    case preparingPracticeMicrophone, start, finishRecording, transcribing

    @MainActor
    static func resolve(for manager: CompanionManager) -> Self {
        let dictation = manager.buddyDictationManager
        if dictation.isFinalizingTranscript { return .transcribing }
        if dictation.isDictationInProgress { return .finishRecording }
        if let permission = missingPermission(
            microphoneAllowed: manager.hasMicrophonePermission,
            speechRequired: dictation.selectedTranscriptionProvider.requiresSpeechRecognitionPermission,
            speechAllowed: manager.hasSpeechRecognitionPermission)
        {
            return permission
        }
        if dictation.usesJapanesePracticeTranscription {
            switch dictation.japanesePracticeMicrophoneReadiness {
            case .failed: return .retryPracticeMicrophone
            case .preparing, .inactive: return .preparingPracticeMicrophone
            case .ready: break
            }
        }
        return manager.isTranscriptionModelReady ? .start : .checkVoiceModel
    }

    static func missingPermission(microphoneAllowed: Bool, speechRequired: Bool, speechAllowed: Bool) -> Self? {
        if !microphoneAllowed { return .allowMicrophone }
        if speechRequired && !speechAllowed { return .allowSpeechRecognition }
        return nil
    }
}
