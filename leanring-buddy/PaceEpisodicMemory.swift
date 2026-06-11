//
//  PaceEpisodicMemory.swift
//  leanring-buddy
//
//  Deterministic v1 episodic-memory scaffold. It extracts only obvious
//  durable facts and stores them as normal retrieval documents.
//

import Foundation

struct PaceEpisodicFact: Codable, Equatable, Identifiable {
    let identifier: String
    let extractedAt: Date
    let subject: String
    let predicate: String
    let value: String
    let confidence: Double
    let expiresAt: Date?
    let topicHashtags: [String]
    let sourceTurnId: String?

    var id: String { identifier }
}

struct PaceEpisodicFactExtractor {
    var now: () -> Date = Date.init

    func extractFacts(
        from userTranscript: String,
        assistantText: String = "",
        frontmostApplicationName: String? = nil,
        sourceTurnId: String? = nil
    ) -> [PaceEpisodicFact] {
        let trimmedTranscript = userTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedTranscript = trimmedTranscript.lowercased()
        guard !trimmedTranscript.isEmpty else { return [] }
        guard !Self.looksEphemeral(normalizedTranscript) else { return [] }
        guard !Self.looksLikeAction(normalizedTranscript) else { return [] }

        let extractedAt = now()
        var facts: [PaceEpisodicFact] = []

        if let preference = Self.preferenceFact(from: trimmedTranscript) {
            facts.append(makeFact(
                extractedAt: extractedAt,
                subject: "user",
                predicate: "prefers",
                value: preference,
                confidence: 0.82,
                topicHashtags: ["#preference"],
                sourceTurnId: sourceTurnId
            ))
        }

        if let healthFact = Self.healthFact(from: trimmedTranscript) {
            facts.append(makeFact(
                extractedAt: extractedAt,
                subject: healthFact.subject,
                predicate: "is in",
                value: healthFact.value,
                confidence: 0.78,
                topicHashtags: ["#family", "#health"],
                sourceTurnId: sourceTurnId
            ))
        }

        if let workFact = Self.workFact(from: trimmedTranscript) {
            facts.append(makeFact(
                extractedAt: extractedAt,
                subject: workFact.subject,
                predicate: workFact.predicate,
                value: workFact.value,
                confidence: 0.76,
                topicHashtags: ["#work"],
                sourceTurnId: sourceTurnId
            ))
        }

        return facts
    }

    private func makeFact(
        extractedAt: Date,
        subject: String,
        predicate: String,
        value: String,
        confidence: Double,
        topicHashtags: [String],
        sourceTurnId: String?
    ) -> PaceEpisodicFact {
        let stableSeed = "\(subject)|\(predicate)|\(value)|\(sourceTurnId ?? "")"
        return PaceEpisodicFact(
            identifier: "episodic-\(abs(stableSeed.hashValue))",
            extractedAt: extractedAt,
            subject: subject,
            predicate: predicate,
            value: value,
            confidence: confidence,
            expiresAt: nil,
            topicHashtags: topicHashtags,
            sourceTurnId: sourceTurnId
        )
    }

    static func retrievalDocument(for fact: PaceEpisodicFact) -> PaceRetrievalDocument {
        PaceRetrievalDocument(
            id: fact.identifier,
            source: .episodicMemory,
            title: "\(fact.subject) \(fact.predicate)",
            text: "\(fact.subject) \(fact.predicate) \(fact.value) \(fact.topicHashtags.joined(separator: " "))",
            modifiedAt: fact.extractedAt,
            permissionScope: "episodicMemory"
        )
    }

    private static func looksEphemeral(_ normalizedTranscript: String) -> Bool {
        let ephemeralHints = [
            "i'm hungry", "i am hungry", "i'm tired", "i am tired",
            "i feel sleepy", "i'm bored", "right now", "for today",
        ]
        return ephemeralHints.contains(where: normalizedTranscript.contains)
    }

    private static func looksLikeAction(_ normalizedTranscript: String) -> Bool {
        let actionPrefixes = [
            "open ", "click ", "tap ", "press ", "type ", "scroll ",
            "draft ", "compose ", "send ", "set a timer", "start a timer",
        ]
        return actionPrefixes.contains(where: normalizedTranscript.hasPrefix)
    }

    private static func preferenceFact(from transcript: String) -> String? {
        let patterns = ["i prefer ", "i like ", "i usually use ", "my preferred "]
        let lowercasedTranscript = transcript.lowercased()
        for pattern in patterns where lowercasedTranscript.contains(pattern) {
            guard let range = lowercasedTranscript.range(of: pattern) else { continue }
            let originalStartIndex = transcript.index(transcript.startIndex, offsetBy: lowercasedTranscript.distance(from: lowercasedTranscript.startIndex, to: range.upperBound))
            return sanitizedValue(String(transcript[originalStartIndex...]))
        }
        return nil
    }

    private static func healthFact(from transcript: String) -> (subject: String, value: String)? {
        let lowercasedTranscript = transcript.lowercased()
        let subjects = ["my mom", "my mother", "my dad", "my father", "my partner"]
        guard let subject = subjects.first(where: lowercasedTranscript.contains) else { return nil }
        if lowercasedTranscript.contains("hospital") {
            return (subject: subject.replacingOccurrences(of: "my ", with: "user's "), value: "the hospital")
        }
        return nil
    }

    private static func workFact(from transcript: String) -> (subject: String, predicate: String, value: String)? {
        let lowercasedTranscript = transcript.lowercased()
        guard lowercasedTranscript.contains("shipping")
            || lowercasedTranscript.contains("launch")
            || lowercasedTranscript.contains("deadline") else {
            return nil
        }
        if lowercasedTranscript.contains("friday") {
            return (subject: "work milestone", predicate: "happens on", value: "Friday")
        }
        return (subject: "work milestone", predicate: "is", value: sanitizedValue(transcript))
    }

    private static func sanitizedValue(_ rawValue: String) -> String {
        rawValue
            .trimmingCharacters(in: CharacterSet(charactersIn: " .,!?\n\t"))
            .prefix(180)
            .description
    }
}
