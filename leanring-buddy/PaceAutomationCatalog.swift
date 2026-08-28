//
//  PaceAutomationCatalog.swift
//  leanring-buddy
//
//  A read-only, non-persisted view over every reusable local automation
//  source. Natural matching stays on-device and never injects catalog metadata
//  into a planner prompt or conversation memory.
//

import Foundation

nonisolated enum PaceAutomationCatalogReference: Equatable, Sendable {
    case typedDefinition(identifier: String)
    case program(identifier: String)
    case recordedFlow(name: String)
    case skill(slug: String, name: String)
    case shortcut(name: String)
}

extension PaceAutomationSource {
    var displayName: String {
        switch self {
        case .bundled:
            return "a built-in automation"
        case .user:
            return "a custom automation"
        case .program:
            return "a programmed automation"
        case .recordedFlow:
            return "a recorded flow"
        case .skill:
            return "a skill"
        case .shortcuts:
            return "a Shortcut"
        }
    }
}

nonisolated struct PaceAutomationCatalogEntry: Equatable, Sendable {
    let name: String
    let description: String
    let category: String
    let source: PaceAutomationSource
    let executionMode: PaceAutomationExecutionMode
    let invocationPhrases: [String]
    let reference: PaceAutomationCatalogReference
}

nonisolated enum PaceAutomationCatalogMatch: Equatable, Sendable {
    case notFound
    case unique(PaceAutomationCatalogEntry)
    case collision([PaceAutomationCatalogEntry])
}

nonisolated struct PaceAutomationCatalog: Equatable, Sendable {
    let entries: [PaceAutomationCatalogEntry]

    init(
        typedDefinitions: [PaceAutomationDefinition],
        recordedFlows: [PaceRecordedFlow],
        skills: [PaceSkillFile],
        shortcutNames: [String],
        programs: [PaceProgramDefinition] = []
    ) {
        var discoveredEntries = typedDefinitions.map { definition in
            PaceAutomationCatalogEntry(
                name: definition.name,
                description: definition.description,
                category: definition.category,
                source: definition.source,
                executionMode: .deterministicLocal,
                invocationPhrases: Self.distinctPhrases(
                    [definition.name] + (definition.invocationPhrases ?? [])
                ),
                reference: .typedDefinition(identifier: definition.identifier)
            )
        }
        discoveredEntries.append(contentsOf: programs.map { program in
            PaceAutomationCatalogEntry(
                name: program.name,
                description: program.description,
                category: program.category,
                source: .program,
                executionMode: .deterministicProgram,
                invocationPhrases: Self.distinctPhrases(
                    [program.name] + program.invocationPhrases
                ),
                reference: .program(identifier: program.identifier)
            )
        })
        discoveredEntries.append(contentsOf: recordedFlows.map { recordedFlow in
            PaceAutomationCatalogEntry(
                name: recordedFlow.name,
                description: "Recorded \(recordedFlow.steps.count)-step UI replay.",
                category: "recorded flow",
                source: .recordedFlow,
                executionMode: .deterministicReplay,
                invocationPhrases: [recordedFlow.name],
                reference: .recordedFlow(name: recordedFlow.name)
            )
        })
        discoveredEntries.append(contentsOf: skills.map { skill in
            PaceAutomationCatalogEntry(
                name: skill.name,
                description: skill.description,
                category: skill.category,
                source: .skill,
                executionMode: .plannerGrounded,
                invocationPhrases: Self.distinctPhrases(
                    [skill.name] + [skill.trigger].compactMap { $0 }
                ),
                reference: .skill(slug: skill.slug, name: skill.name)
            )
        })
        discoveredEntries.append(contentsOf: shortcutNames.map { shortcutName in
            PaceAutomationCatalogEntry(
                name: shortcutName,
                description: "Workflow managed by the macOS Shortcuts app.",
                category: "Shortcut",
                source: .shortcuts,
                executionMode: .externalOpaque,
                invocationPhrases: [shortcutName],
                reference: .shortcut(name: shortcutName)
            )
        })

        self.entries = discoveredEntries.sorted { firstEntry, secondEntry in
            let nameOrdering = firstEntry.name.localizedCaseInsensitiveCompare(secondEntry.name)
            if nameOrdering == .orderedSame {
                return firstEntry.source.rawValue < secondEntry.source.rawValue
            }
            return nameOrdering == .orderedAscending
        }
    }

    func exactMatch(for requestedName: String) -> PaceAutomationCatalogMatch {
        let normalizedRequestedName = Self.normalizedName(requestedName)
        let matchingEntries = entries.filter { entry in
            Self.normalizedName(entry.name) == normalizedRequestedName
        }

        switch matchingEntries.count {
        case 0:
            return .notFound
        case 1:
            return .unique(matchingEntries[0])
        default:
            return .collision(matchingEntries)
        }
    }

    func spokenListResponse() -> String {
        guard !entries.isEmpty else {
            return "you don't have any automations yet."
        }

        let modeOrder: [PaceAutomationExecutionMode] = [
            .deterministicLocal,
            .deterministicProgram,
            .deterministicReplay,
            .plannerGrounded,
            .externalOpaque,
        ]
        let groupedSummaries = modeOrder.compactMap { executionMode -> String? in
            let matchingNames = entries
                .filter { $0.executionMode == executionMode }
                .map(\.name)
            guard !matchingNames.isEmpty else {
                return nil
            }

            // The bundled starter library is deliberately small enough to
            // enumerate in full. User-owned sources can grow without bound,
            // so keep those spoken lists capped.
            let maximumNamesPerMode = executionMode == .deterministicLocal ? 20 : 8
            let spokenNames = matchingNames.prefix(maximumNamesPerMode).joined(separator: ", ")
            let remainingCount = matchingNames.count - min(matchingNames.count, maximumNamesPerMode)
            let remainingSuffix = remainingCount > 0 ? ", and \(remainingCount) more" : ""
            return "\(executionMode.displayName): \(spokenNames)\(remainingSuffix)"
        }

        return "your automations are " + groupedSummaries.joined(separator: "; ") + "."
    }

    static func normalizedName(_ name: String) -> String {
        name
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    private static func distinctPhrases(_ phrases: [String]) -> [String] {
        var seenNormalizedPhrases: Set<String> = []
        return phrases.filter { phrase in
            let normalizedPhrase = PaceAutomationNaturalLanguageMatcher
                .normalizedPhrase(phrase)
            return !normalizedPhrase.isEmpty
                && seenNormalizedPhrases.insert(normalizedPhrase).inserted
        }
    }
}

nonisolated enum PaceAutomationNaturalLanguageEvidence: Equatable, Sendable {
    case exactInvocationPhrase
    case semantic
}

nonisolated enum PaceAutomationNaturalLanguageMatch: Equatable, Sendable {
    case noMatch
    case unique(
        entry: PaceAutomationCatalogEntry,
        evidence: PaceAutomationNaturalLanguageEvidence,
        score: Double
    )
    case ambiguous(
        entries: [PaceAutomationCatalogEntry],
        evidence: PaceAutomationNaturalLanguageEvidence
    )
}

/// Conservative local matcher for completed text transcripts. Embeddings are
/// used only to retrieve a likely catalog entry; the absolute-score and
/// winner-margin gates remain deterministic policy.
nonisolated enum PaceAutomationNaturalLanguageMatcher {
    struct Configuration: Equatable, Sendable {
        let minimumSemanticScore: Double
        let minimumCompactEmbeddingSemanticScore: Double
        let minimumResolverSemanticScore: Double
        let minimumCompactEmbeddingResolverSemanticScore: Double
        let minimumWinnerMargin: Double
        let maximumResolverCandidateCount: Int

        static let paceDefault = Configuration(
            minimumSemanticScore: 0.70,
            // Apple's built-in sentence vectors have a lower cosine range
            // than Nomic. This gate was calibrated against positive and
            // unrelated word probes; the same winner margin still applies.
            minimumCompactEmbeddingSemanticScore: 0.40,
            minimumResolverSemanticScore: 0.55,
            minimumCompactEmbeddingResolverSemanticScore: 0.30,
            minimumWinnerMargin: 0.08,
            maximumResolverCandidateCount: 5
        )
    }

    private struct RankedEntry {
        let entry: PaceAutomationCatalogEntry
        let score: Double
        let evidence: PaceAutomationNaturalLanguageEvidence
    }

    static func match(
        transcript: String,
        catalog: PaceAutomationCatalog,
        embedder: (any PaceTextEmbedding)?,
        configuration: Configuration = .paceDefault
    ) async -> PaceAutomationNaturalLanguageMatch {
        let normalizedTranscript = normalizedPhrase(transcript)
        guard !normalizedTranscript.isEmpty, !catalog.entries.isEmpty else {
            return .noMatch
        }

        let exactEntries = catalog.entries.filter { entry in
            entry.invocationPhrases.contains { invocationPhrase in
                normalizedPhrase(invocationPhrase) == normalizedTranscript
            }
        }
        if exactEntries.count == 1, let exactEntry = exactEntries.first {
            return .unique(
                entry: exactEntry,
                evidence: .exactInvocationPhrase,
                score: 1
            )
        }
        if exactEntries.count > 1 {
            return .ambiguous(
                entries: exactEntries,
                evidence: .exactInvocationPhrase
            )
        }

        // Exact authored phrases above remain authoritative. For every other
        // information-seeking question, skip semantic automation matching:
        // approximate vector similarity between a factual question and names
        // such as "today schedule" must never delay or hijack the answer path.
        guard shouldAttemptImplicitCatalogMatch(transcript: normalizedTranscript) else {
            return .noMatch
        }

        guard let embedder else { return .noMatch }

        do {
            let semanticDocuments = catalog.entries.map(semanticDocument)
            let vectors = try await embedder.embed([transcript] + semanticDocuments)
            guard vectors.count == semanticDocuments.count + 1,
                  let transcriptVector = vectors.first,
                  transcriptVector.contains(where: { $0 != 0 }) else {
                throw PaceEmbeddingClientError(message: "invalid automation embedding vectors")
            }

            let semanticScores = vectors.dropFirst().map { candidateVector in
                max(0, cosineSimilarity(transcriptVector, candidateVector))
            }
            let effectiveMinimumSemanticScore = transcriptVector.count <= 512
                ? configuration.minimumCompactEmbeddingSemanticScore
                : configuration.minimumSemanticScore
            let effectiveMinimumResolverSemanticScore = transcriptVector.count <= 512
                ? configuration.minimumCompactEmbeddingResolverSemanticScore
                : configuration.minimumResolverSemanticScore
            return gatedOutcome(
                entries: catalog.entries,
                scores: semanticScores,
                evidence: .semantic,
                minimumScore: effectiveMinimumSemanticScore,
                minimumResolverScore: effectiveMinimumResolverSemanticScore,
                minimumWinnerMargin: configuration.minimumWinnerMargin,
                maximumResolverCandidateCount: configuration.maximumResolverCandidateCount
            )
        } catch {
            return .noMatch
        }
    }

    static func normalizedPhrase(_ phrase: String) -> String {
        let foldedPhrase = phrase.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        let normalizedCharacters = foldedPhrase.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) {
                return Character(String(scalar))
            }
            return " "
        }
        return String(normalizedCharacters)
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    static func shouldAttemptImplicitCatalogMatch(transcript: String) -> Bool {
        let normalizedTranscript = normalizedPhrase(transcript)
        let informationSeekingPrefixes = [
            "what ", "whats ", "who ", "when ", "where ", "why ",
            "how ", "which ", "tell me about ", "explain ", "define ",
        ]
        return !informationSeekingPrefixes.contains { prefix in
            normalizedTranscript.hasPrefix(prefix)
        }
    }

    private static func semanticDocument(for entry: PaceAutomationCatalogEntry) -> String {
        ([entry.name, entry.description] + entry.invocationPhrases)
            .joined(separator: ". ")
    }

    private static func cosineSimilarity(_ firstVector: [Float], _ secondVector: [Float]) -> Double {
        guard firstVector.count == secondVector.count, !firstVector.isEmpty else { return 0 }
        var dotProduct = 0.0
        var firstMagnitude = 0.0
        var secondMagnitude = 0.0
        for index in firstVector.indices {
            let firstValue = Double(firstVector[index])
            let secondValue = Double(secondVector[index])
            dotProduct += firstValue * secondValue
            firstMagnitude += firstValue * firstValue
            secondMagnitude += secondValue * secondValue
        }
        guard firstMagnitude > 0, secondMagnitude > 0 else { return 0 }
        return dotProduct / (sqrt(firstMagnitude) * sqrt(secondMagnitude))
    }

    private static func gatedOutcome(
        entries: [PaceAutomationCatalogEntry],
        scores: [Double],
        evidence: PaceAutomationNaturalLanguageEvidence,
        minimumScore: Double,
        minimumResolverScore: Double,
        minimumWinnerMargin: Double,
        maximumResolverCandidateCount: Int
    ) -> PaceAutomationNaturalLanguageMatch {
        let rankedEntries = zip(entries, scores)
            .map { RankedEntry(entry: $0.0, score: $0.1, evidence: evidence) }
            .sorted { firstRankedEntry, secondRankedEntry in
                if firstRankedEntry.score == secondRankedEntry.score {
                    return firstRankedEntry.entry.name.localizedCaseInsensitiveCompare(
                        secondRankedEntry.entry.name
                    ) == .orderedAscending
                }
                return firstRankedEntry.score > secondRankedEntry.score
            }
        guard let winner = rankedEntries.first,
              winner.score >= minimumResolverScore else {
            return .noMatch
        }

        if winner.score >= minimumScore, rankedEntries.count > 1 {
            let runnerUp = rankedEntries[1]
            if winner.score - runnerUp.score >= minimumWinnerMargin {
                return .unique(
                    entry: winner.entry,
                    evidence: winner.evidence,
                    score: winner.score
                )
            }
        }

        let resolverCandidates = rankedEntries
            .prefix(maximumResolverCandidateCount)
            .map(\.entry)
        return .ambiguous(entries: resolverCandidates, evidence: evidence)
    }
}

nonisolated enum PaceAutomationCatalogCommand: Equatable, Sendable {
    case list
    case run(requestedName: String)
}

nonisolated enum PaceAutomationCatalogCommandParser {
    private static let listCommands: Set<String> = [
        "list automations",
        "list my automations",
        "show automations",
        "show my automations",
        "what automations do i have",
        "which automations do i have",
    ]

    static func parse(_ transcript: String) -> PaceAutomationCatalogCommand? {
        let cleanedTranscript = transcript
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!?"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedTranscript = PaceAutomationCatalog.normalizedName(cleanedTranscript)

        if listCommands.contains(normalizedTranscript) {
            return .list
        }

        for prefix in [
            "run the automation named ",
            "run automation named ",
            "execute the automation named ",
            "execute automation named ",
            "run the automation ",
            "run automation ",
            "execute the automation ",
            "execute automation ",
        ] {
            guard let prefixRange = cleanedTranscript.range(
                of: prefix,
                options: [.caseInsensitive, .anchored]
            ) else {
                continue
            }

            let requestedName = String(cleanedTranscript[prefixRange.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !requestedName.isEmpty {
                return .run(requestedName: requestedName)
            }
        }

        return nil
    }
}
