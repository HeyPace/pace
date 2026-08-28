//
//  PaceChainedTextEmbeddingClient.swift
//  leanring-buddy
//
//  Tries a primary `PaceTextEmbedding` first; on throw, all-empty
//  vectors, or wrong-cardinality result, falls back to a secondary.
//  Used to give an explicitly enabled in-process MLX embedder an
//  always-available Apple NaturalLanguage fallback.
//
//  The default factories deliberately do not use an LM Studio embedding
//  model. A second sidecar model can evict the conversational model from
//  a single-model runtime, making an ordinary question pay a cold-load
//  penalty or fail outright. Reliability of the user-facing turn takes
//  priority over a small semantic-ranking improvement.
//

import Foundation

final class PaceChainedTextEmbeddingClient: PaceTextEmbedding {
    private let primaryClient: any PaceTextEmbedding
    private let fallbackClient: any PaceTextEmbedding

    init(
        primary: any PaceTextEmbedding,
        fallback: any PaceTextEmbedding
    ) {
        self.primaryClient = primary
        self.fallbackClient = fallback
    }

    func embed(_ texts: [String]) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        do {
            let primaryVectors = try await primaryClient.embed(texts)
            // Treat wrong-count or all-zero outputs as a primary
            // failure too. A primary that "succeeds" by returning
            // a uniform zero vector would silently break recall
            // without flipping us to the fallback otherwise.
            if primaryVectors.count == texts.count,
               primaryVectorsHaveAnyNonZeroSignal(primaryVectors) {
                return primaryVectors
            }
        } catch {
            // Primary failed — log once at the lowest level so a
            // missing LM Studio doesn't spam the console on every
            // turn. Fallthrough to fallback.
            print("ℹ️  Primary embedding client failed (\(error.localizedDescription)). Falling back to Apple NL.")
        }
        return try await fallbackClient.embed(texts)
    }

    /// Quick non-zero-signal probe — we only need to know that AT
    /// LEAST ONE vector has a non-zero component to trust the primary
    /// result. Scanning every component of every vector is wasteful;
    /// scanning the first non-zero we find is sufficient.
    private func primaryVectorsHaveAnyNonZeroSignal(_ vectors: [[Float]]) -> Bool {
        for vector in vectors {
            for component in vector where component != 0 {
                return true
            }
        }
        return false
    }
}

extension PaceChainedTextEmbeddingClient {
    /// Default factory. Preference order:
    ///   1. Bundled MLX (when SPM runtime is linked AND the user has
    ///      opted into in-process embeddings) — zero LM Studio
    ///      dependency, runs entirely in-process.
    ///   2. Apple NL — always-available baseline that ships with
    ///      every Mac.
    ///
    /// Keep the preference order here so background memory work can never
    /// cause LM Studio to swap away from the conversational model.
    static func makePaceDefault() -> any PaceTextEmbedding {
        guard PaceBundledModelsSettings.isUsingMLXInProcessEmbedder() else {
            return PaceAppleNLEmbeddingClient()
        }
        return PaceChainedTextEmbeddingClient(
            primary: PaceMLXEmbeddingClient(
                modelIdentifier: PaceBundledModelsSettings.embedderModelIdentifier()
            ),
            fallback: PaceAppleNLEmbeddingClient()
        )
    }

    /// Voice/text routing is latency-sensitive and runs before the planner on
    /// ordinary utterances. It must therefore use only an in-process embedder.
    static func makeAutomationRoutingDefault() -> any PaceTextEmbedding {
        makePaceDefault()
    }
}
