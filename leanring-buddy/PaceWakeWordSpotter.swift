//
//  PaceWakeWordSpotter.swift
//  leanring-buddy
//
//  Wake-word scaffold for always-listening mode. The runtime audio tap can
//  feed partial transcripts or detector hypotheses into this object; v1
//  keeps the decision deterministic and dependency-free.
//

import Foundation

nonisolated struct PaceWakeWordSpotterConfiguration: Equatable {
    var phrases: [String] = ["pace", "hey pace"]
    var minimumConfidence: Double = 0.7
}

final class PaceWakeWordSpotter {
    private let configuration: PaceWakeWordSpotterConfiguration
    private(set) var isEnabled: Bool = false

    init(configuration: PaceWakeWordSpotterConfiguration = PaceWakeWordSpotterConfiguration()) {
        self.configuration = configuration
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
    }

    func detectWakeWord(in partialTranscript: String, confidence: Double = 1.0) -> Bool {
        guard isEnabled, confidence >= configuration.minimumConfidence else {
            return false
        }
        let normalizedTranscript = partialTranscript
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: " ")
        return configuration.phrases.contains { phrase in
            normalizedTranscript == phrase
                || normalizedTranscript.hasPrefix("\(phrase) ")
        }
    }
}
