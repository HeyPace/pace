//
//  PaceBargeInVAD.swift
//  leanring-buddy
//
//  Tiny signal-level detector for barge-in tests and future audio-tap
//  wiring. Runtime callers feed normalized RMS samples while TTS is
//  playing; the detector fires only after sustained speech-like energy.
//

import Foundation

nonisolated struct PaceBargeInVADConfiguration: Equatable {
    var speechLevelThreshold: Float = 0.12
    var sustainedSpeechDuration: TimeInterval = 0.6
    var maximumInterSampleGap: TimeInterval = 0.25
}

nonisolated struct PaceBargeInVAD {
    private let configuration: PaceBargeInVADConfiguration
    private var sustainedSpeechStartedAt: Date?
    private var lastSampleAt: Date?

    init(configuration: PaceBargeInVADConfiguration = PaceBargeInVADConfiguration()) {
        self.configuration = configuration
    }

    mutating func reset() {
        sustainedSpeechStartedAt = nil
        lastSampleAt = nil
    }

    mutating func observe(normalizedLevel: Float, at sampleDate: Date) -> Bool {
        defer { lastSampleAt = sampleDate }

        if let lastSampleAt,
           sampleDate.timeIntervalSince(lastSampleAt) > configuration.maximumInterSampleGap {
            sustainedSpeechStartedAt = nil
        }

        guard normalizedLevel >= configuration.speechLevelThreshold else {
            sustainedSpeechStartedAt = nil
            return false
        }

        if sustainedSpeechStartedAt == nil {
            sustainedSpeechStartedAt = sampleDate
        }

        guard let sustainedSpeechStartedAt else { return false }
        return sampleDate.timeIntervalSince(sustainedSpeechStartedAt) >= configuration.sustainedSpeechDuration
    }
}
