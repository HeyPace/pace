//
//  PaceResponseQualityChecker.swift
//  leanring-buddy
//
//  Post-hoc response quality detection. After the local model
//  generates a response, this checks whether it's adequate before
//  speaking it to the user. If the response is poor AND a stronger
//  model is available (codex CLI), the turn is re-routed.
//
//  Only applied to text-only answer paths (pureKnowledge, chitchat)
//  where the response is generated fully before TTS begins. The main
//  agent loop (screenAction, screenDescription) streams to TTS
//  during generation and can't be cleanly intercepted.
//

import Foundation

/// Result of a quality check on a planner response.
enum PaceResponseQualityVerdict: Equatable {
    /// Response is adequate — proceed with speaking it.
    case adequate

    /// Response is poor — re-route to a stronger model if available.
    /// The reason is logged for debugging.
    case inadequate(reason: String)

}

/// Heuristic quality checks on a planner response. Zero latency, zero
/// model cost. Catches the most common failure modes of small local
/// models: empty output, hedging, repetition, and non-answers.
enum PaceResponseQualityHeuristics {

    /// Phrases that indicate the local model is hedging or failing.
    /// These are strong signals that the response is not useful.
    private static let failureMarkers: [String] = [
        "i'm not sure",
        "i am not sure",
        "i don't know",
        "i do not know",
        "i can't help with that",
        "i cannot help with that",
        "i'm unable to",
        "i am unable to",
        "unable to help",
        "sorry, i can't",
        "sorry, i cannot",
        "i don't have access to",
        "i do not have access to",
        "i don't have information",
        "i do not have information",
        "i'm just a",
        "i am just a",
        "as an ai",
        "as a language model",
        "i don't have the ability to",
        "i do not have the ability to",
    ]

    /// Check heuristic quality of a response against the original query.
    /// Returns `.inadequate` with a reason if any check fails.
    static func check(query: String, response: String) -> PaceResponseQualityVerdict {
        let lowercaseResponse = response.lowercased()
        let responseWords = lowercaseResponse.split { $0.isWhitespace }
        let responseWordCount = responseWords.count

        // 1. Empty output is always broken. Brevity is not: "Jupiter" is a
        // complete answer to a short factual question, and sending it through
        // another model merely because it is one word adds delay and risk.
        if response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .inadequate(reason: "empty response")
        }

        // 2. Failure markers — the model is explicitly saying it
        //    can't answer. These are definitive.
        for marker in failureMarkers {
            if lowercaseResponse.contains(marker) {
                return .inadequate(reason: "failure marker: \"\(marker)\"")
            }
        }

        // 3. Repetition — same phrase repeated 3+ times indicates
        //    the model is stuck in a loop. Check 3-gram repetition.
        if responseWordCount > 15 {
            let words = responseWords.map(String.init)
            var ngramCounts: [String: Int] = [:]
            for i in 0..<(words.count - 2) {
                let ngram = words[i..<(i + 3)].joined(separator: " ")
                ngramCounts[ngram, default: 0] += 1
            }
            if let maxCount = ngramCounts.values.max(), maxCount >= 4 {
                return .inadequate(reason: "repetitive 3-gram (count: \(maxCount))")
            }
        }

        // 4. Echo — the response just repeats the query back without
        //    adding information. Common with small models on edge cases.
        //    Check if most UNIQUE words in the response are also in the
        //    query — if the response adds no new vocabulary, it's an echo.
        let queryWords = Set(query.lowercased().split { $0.isWhitespace }.map(String.init))
        let responseWordSet = Set(responseWords.map(String.init))
        if responseWordCount > 5 && responseWordSet.count < 15 {
            let overlap = queryWords.intersection(responseWordSet).count
            let overlapRatio = Double(overlap) / Double(responseWordSet.count)
            // If >80% of unique response words are also in the query,
            // the response isn't adding new information — it's an echo.
            if overlapRatio > 0.80 {
                return .inadequate(reason: "response echoes query (overlap: \(Int(overlapRatio * 100))%)")
            }
        }

        return .adequate
    }

}

/// Quality checker for failure modes that can be detected without asking a
/// second generative model to guess whether the first model was factually
/// correct. Factual accuracy belongs in planner evaluation, not a runtime
/// judge that can confidently repeat the same mistake.
@MainActor
final class PaceResponseQualityChecker {
    func check(query: String, response: String) async -> PaceResponseQualityVerdict {
        PaceResponseQualityHeuristics.check(query: query, response: response)
    }
}
