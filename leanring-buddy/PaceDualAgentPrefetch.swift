//
//  PaceDualAgentPrefetch.swift
//  leanring-buddy
//
//  Dual-agent pre-fetch — while the user is speaking, a background
//  agent pre-computes likely-needed context so the planner has it
//  ready instantly when PTT releases.
//
//  Inspired by VoiceAgentRAG's "Slow Thinker + Fast Talker" architecture.
//  The slow agent (this prefetcher) runs in the background while the
//  user is still talking; the fast agent (the main planner) reads from
//  the pre-computed cache for the actual response.
//
//  What this pre-computes:
//    1. Screen context (VLM element map) — starts on PTT press, not
//       release. By the time the user finishes speaking, the VLM has
//       already produced its element map.
//    2. Episodic memory recall — based on the stable partial transcript,
//       pre-fetch relevant facts from episodic memory.
//    3. RAG retrieval — if the stable partial looks like a knowledge
//       question, pre-fetch relevant documents from the local index.
//
//  The pre-fetch is speculative — it may be discarded if the final
//  transcript differs significantly from the stable partial. The cost
//  of a wasted pre-fetch is small (background CPU); the win of a hit
//  is ~1-3s saved on the planner's critical path.
//

import Combine
import Foundation

/// A pre-fetched context result. Produced by the background agent
/// and consumed by the main planner path.
struct PacePrefetchResult: Equatable {
    /// The stable partial transcript that triggered this pre-fetch.
    let triggerTranscript: String
    /// VLM element map (if screen context was pre-fetched).
    let vlmElementMap: String?
    /// Episodic memory facts (if recalled).
    let episodicFacts: [String]
    /// RAG retrieval results (if fetched).
    let ragResults: [String]
    /// When this pre-fetch was completed.
    let completedAt: Date

    /// Whether this pre-fetch has any usable results.
    var hasResults: Bool {
        vlmElementMap != nil || !episodicFacts.isEmpty || !ragResults.isEmpty
    }

    static func == (lhs: PacePrefetchResult, rhs: PacePrefetchResult) -> Bool {
        lhs.triggerTranscript == rhs.triggerTranscript
    }
}

/// Manages the dual-agent pre-fetch pipeline. Started when PTT
/// presses, fed stable partial transcripts, and consumed when the
/// planner begins its turn.
@MainActor
final class PaceDualAgentPrefetch: ObservableObject {
    static let shared = PaceDualAgentPrefetch()

    /// The latest pre-fetch result, if any. Consumed (set to nil) by
    /// the planner when it starts its turn.
    @Published private(set) var currentResult: PacePrefetchResult?

    /// Callback to pre-compute VLM screen context. Set by
    /// CompanionManager. Returns the element map text, or nil.
    var prefetchVLMContext: (() async -> String?)?

    /// Callback to pre-fetch episodic memory facts. Set by
    /// CompanionManager. Returns relevant facts for the query.
    var prefetchEpisodicMemory: ((String) async -> [String])?

    /// Callback to pre-fetch RAG results. Set by CompanionManager.
    /// Returns relevant document snippets for the query.
    var prefetchRAG: ((String) async -> [String])?

    /// Whether pre-fetch is enabled. When false, no background work
    /// is done and the planner runs as before.
    var isEnabled: Bool = true

    /// Minimum stable partial word count before pre-fetch triggers.
    /// Avoids wasting work on single-word partials.
    private let minWordCount = 3

    /// The current pre-fetch task, if any.
    private var prefetchTask: Task<Void, Never>?

    /// The transcript that triggered the current pre-fetch.
    private var currentTriggerTranscript: String?

    private init() {}

    // MARK: - Lifecycle

    /// Called when PTT presses. Starts VLM pre-fetch immediately
    /// (screen context doesn't depend on the transcript).
    func onPTTPress() {
        guard isEnabled else { return }

        // Cancel any previous pre-fetch (e.g. from a prior PTT session).
        prefetchTask?.cancel()
        currentResult = nil
        currentTriggerTranscript = nil

        // Start VLM pre-fetch immediately — it doesn't need the
        // transcript, just the screen.
        if prefetchVLMContext != nil {
            prefetchTask = Task { @MainActor [weak self] in
                guard let self else { return }

                // VLM pre-fetch runs in parallel with speech.
                async let vlmResult = self.prefetchVLMContext?() ?? nil

                // Wait for VLM (or cancellation).
                let elementMap = await vlmResult

                if Task.isCancelled { return }

                // Store the VLM result. Episodic/RAG will be added
                // when a stable partial arrives.
                if let elementMap {
                    self.currentResult = PacePrefetchResult(
                        triggerTranscript: "",
                        vlmElementMap: elementMap,
                        episodicFacts: [],
                        ragResults: [],
                        completedAt: Date()
                    )
                    print("🔮 Pre-fetch: VLM element map ready (\(elementMap.count) chars)")
                }
            }
        }
    }

    /// Called when a stable partial transcript is available. Triggers
    /// episodic memory and RAG pre-fetch based on the partial.
    func onStablePartial(_ transcript: String) {
        guard isEnabled else { return }

        let wordCount = transcript.split(separator: " ").count
        guard wordCount >= minWordCount else { return }

        // Don't re-trigger if we already have a result for this transcript.
        if currentTriggerTranscript == transcript { return }
        currentTriggerTranscript = transcript

        // Cancel the previous pre-fetch and start a new one with the
        // transcript-dependent work.
        prefetchTask?.cancel()

        let previousVLM = currentResult?.vlmElementMap

        prefetchTask = Task { @MainActor [weak self] in
            guard let self else { return }

            // Run episodic memory and RAG in parallel.
            async let episodicResult = self.prefetchEpisodicMemory?(transcript) ?? []
            async let ragResult = self.prefetchRAG?(transcript) ?? []

            let episodicFacts = await episodicResult
            let ragResults = await ragResult

            if Task.isCancelled { return }

            self.currentResult = PacePrefetchResult(
                triggerTranscript: transcript,
                vlmElementMap: previousVLM,
                episodicFacts: episodicFacts,
                ragResults: ragResults,
                completedAt: Date()
            )

            print("🔮 Pre-fetch: \(episodicFacts.count) facts, \(ragResults.count) RAG results for '\(transcript.prefix(40))'")
        }
    }

    /// Called when PTT releases and the planner is about to start.
    /// Returns the pre-fetched context and clears it. The planner
    /// should inject this into its prompt.
    func consume() -> PacePrefetchResult? {
        let result = currentResult
        currentResult = nil
        currentTriggerTranscript = nil
        prefetchTask?.cancel()
        prefetchTask = nil

        if let result, result.hasResults {
            print("🔮 Pre-fetch consumed: VLM=\(result.vlmElementMap != nil), facts=\(result.episodicFacts.count), RAG=\(result.ragResults.count)")
        }

        return result?.hasResults == true ? result : nil
    }

    /// Cancel any in-flight pre-fetch (e.g. user cancelled PTT).
    func cancel() {
        prefetchTask?.cancel()
        prefetchTask = nil
        currentResult = nil
        currentTriggerTranscript = nil
    }
}
