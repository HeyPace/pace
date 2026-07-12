//
//  PaceAlwaysListeningCommandParser.swift
//  leanring-buddy
//
//  Voice-command parser for the always-listening preference. It mirrors
//  the watch-mode parser: exact enough to avoid hijacking normal turns.
//

import Foundation

nonisolated enum PaceAlwaysListeningCommand: Equatable {
    case start
    case stop
}

nonisolated enum PaceAlwaysListeningCommandParser {
    static func parse(_ transcript: String) -> PaceAlwaysListeningCommand? {
        let normalizedTranscript = transcript
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalizedTranscript.isEmpty else { return nil }

        let stopPhrases = [
            "pace stop listening always",
            "pace stop always listening",
            "stop always listening",
            "turn off always listening",
            "disable always listening",
            "stop ambient listening",
        ]
        if stopPhrases.contains(where: normalizedTranscript.contains) {
            return .stop
        }

        let startPhrases = [
            "pace listen always",
            "start always listening",
            "turn on always listening",
            "enable always listening",
            "start ambient listening",
            "listen for hey pace",
        ]
        if startPhrases.contains(where: normalizedTranscript.contains) {
            return .start
        }

        return nil
    }
}
