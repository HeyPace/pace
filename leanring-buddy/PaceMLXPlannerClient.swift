//
//  PaceMLXPlannerClient.swift
//  leanring-buddy
//
//  In-process MLX planner — runs Qwen3-4B-Instruct (or a sibling
//  bundled model) directly via `mlx-swift-examples` rather than
//  through LM Studio's HTTP loopback. The whole point is to drop
//  the LM Studio install dependency from the new-user setup story
//  so first-launch Pace just works.
//
//  Compiles cleanly with OR without the `MLXLLM` SPM module via
//  `#if canImport(MLXLLM)`. When the SPM dependency is absent every
//  method throws `PaceMLXPlannerError.runtimeNotLinked` and
//  `isRuntimeAvailable` returns false — the factory keeps the
//  current LM Studio / Apple FM / Direct API tiering intact.
//
//  Quality posture: a 4B in-process planner scores ~3-4 points
//  lower than qwen3-30b-a3b on the FM-fixture set. Bundled MLX is
//  opt-in (see `PaceBundledModelsSettings`); LM Studio remains the
//  gold-quality option for power users.
//

import Foundation

#if canImport(MLXLLM)
import MLXLLM
import MLXLMCommon
#endif

nonisolated enum PaceMLXPlannerError: LocalizedError {
    case runtimeNotLinked
    case modelLoadFailed(underlyingErrorDescription: String)
    case inferenceFailed(underlyingErrorDescription: String)

    var errorDescription: String? {
        switch self {
        case .runtimeNotLinked:
            return "MLX runtime not linked into this build. Add `mlx-swift-examples` as a Swift Package dependency in Xcode → Project → Package Dependencies."
        case .modelLoadFailed(let underlyingErrorDescription):
            return "MLX model load failed: \(underlyingErrorDescription)"
        case .inferenceFailed(let underlyingErrorDescription):
            return "MLX inference failed: \(underlyingErrorDescription)"
        }
    }
}

@MainActor
final class PaceMLXPlannerClient: BuddyPlannerClient {

    // Compile-time visible to the factory so it knows whether to
    // even consider this client. `canImport(MLXLLM)` resolves at
    // compile time — true once the SPM dependency lands.
    nonisolated static var isRuntimeAvailable: Bool {
        #if canImport(MLXLLM)
        return true
        #else
        return false
        #endif
    }

    /// HuggingFace model identifier (e.g. `mlx-community/Qwen3-4B-Instruct-4bit`).
    /// Loaded lazily on first `generateResponseStreaming` — pipeline
    /// construction is ~200-500ms on Apple Silicon plus a one-time
    /// HuggingFace download on first launch.
    private let modelIdentifier: String
    private let generationTemperature: Float

    let displayName: String
    let supportsImageInput: Bool = false

    init(
        modelIdentifier: String = "mlx-community/Qwen3-4B-Instruct-4bit",
        generationTemperature: Float = 0.0
    ) {
        self.modelIdentifier = modelIdentifier
        self.generationTemperature = generationTemperature
        self.displayName = "MLX in-process (\(Self.shortenedModelLabel(forIdentifier: modelIdentifier)))"
    }

    /// Pre-fetch the configured model container — surfaces progress
    /// via the Hub package's NSProgress so callers can render a
    /// real percentage instead of an indeterminate spinner. Safe to
    /// call multiple times; subsequent calls return the cached
    /// container immediately. Throws on any load failure so the
    /// Settings UI can show a useful message instead of "downloading…
    /// (forever)".
    static func prefetchModel(
        modelIdentifier: String,
        progressHandler: @Sendable @escaping (Progress) -> Void = { _ in }
    ) async throws {
        #if canImport(MLXLLM)
        _ = try await Self.sharedModelContainer(
            modelIdentifier: modelIdentifier,
            progressHandler: progressHandler
        )
        #else
        _ = (modelIdentifier, progressHandler)
        throw PaceMLXPlannerError.runtimeNotLinked
        #endif
    }

    nonisolated static func shortenedModelLabel(forIdentifier modelIdentifier: String) -> String {
        // "mlx-community/Qwen3-4B-Instruct-4bit" → "Qwen3-4B"
        let lastSegment = modelIdentifier.split(separator: "/").last.map(String.init) ?? modelIdentifier
        let trimmedSegment = lastSegment
            .replacingOccurrences(of: "-Instruct-4bit", with: "")
            .replacingOccurrences(of: "-Instruct", with: "")
            .replacingOccurrences(of: "-4bit", with: "")
        return trimmedSegment
    }

    // MARK: - BuddyPlannerClient

    func generateResponseStreaming(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String,
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval) {
        #if canImport(MLXLLM)
        let inferenceStartedAt = Date()

        let modelContainer: ModelContainer
        do {
            modelContainer = try await Self.sharedModelContainer(modelIdentifier: modelIdentifier)
        } catch {
            throw PaceMLXPlannerError.modelLoadFailed(
                underlyingErrorDescription: error.localizedDescription
            )
        }

        // Wrap the incoming system prompt with the plan-then-execute
        // scaffold. The bundled MLX 4B model materially benefits
        // from explicit intent → plan → action structuring before
        // committing to a response. The <think> block content is
        // automatically stripped before TTS by the existing
        // streaming pipeline.
        let wrappedSystemPrompt: String
        if systemPrompt.isEmpty {
            wrappedSystemPrompt = CompanionSystemPrompt.planThenExecuteScaffoldForBundledMLX
        } else {
            wrappedSystemPrompt = CompanionSystemPrompt.wrapWithPlanThenExecuteScaffoldForBundledMLX(
                systemPrompt
            )
        }

        // Lever #1 — KV-cache prefix reuse across turns. The big
        // TTFT win. ChatSession's underlying Generator preserves
        // KVCache across respond/streamResponse calls — but only
        // within the SAME session instance. By holding the session
        // across PaceMLXPlannerClient invocations (cache-keyed on
        // model identifier + system prompt hash + turn count) we
        // get the cache reuse without re-prefilling the
        // ~2-3k-token system+tool-list prefix every turn.
        //
        // Cache HIT path: send only the new userPrompt. The
        //   session's KV cache already reflects [system + history].
        // Cache MISS path: rebuild the session, send the flattened
        //   history+userPrompt (so the model sees the prior context).
        let cacheDecision = Self.lookUpOrInvalidateSessionCache(
            requestedModelIdentifier: modelIdentifier,
            requestedSystemPromptHash: wrappedSystemPrompt.hashValue,
            requestedConversationTurnCount: conversationHistory.count
        )

        let generationParameters = GenerateParameters(temperature: generationTemperature)
        let chatSession: ChatSession
        let promptToSendToModel: String

        switch cacheDecision {
        case .reuseExisting(let cachedSession):
            chatSession = cachedSession
            promptToSendToModel = userPrompt
        case .rebuildRequired:
            chatSession = ChatSession(
                modelContainer,
                instructions: wrappedSystemPrompt,
                generateParameters: generationParameters
            )
            promptToSendToModel = Self.combineHistoryIntoUserPrompt(
                conversationHistory: conversationHistory,
                userPrompt: userPrompt
            )
            Self.installFreshSessionAsCache(
                modelIdentifier: modelIdentifier,
                systemPromptHash: wrappedSystemPrompt.hashValue,
                priorTurnCountReflectedAtBuildTime: conversationHistory.count,
                session: chatSession
            )
        }

        var accumulatedText = ""
        do {
            for try await textChunk in chatSession.streamResponse(to: promptToSendToModel) {
                accumulatedText += textChunk
                await onTextChunk(textChunk)
            }
        } catch {
            // Any mid-stream error MAY have left the session's KV
            // cache in a partially-populated state. Drop the cache
            // so the next turn rebuilds from scratch rather than
            // continuing from a possibly-corrupt position.
            Self.invalidateSessionCache(reason: "inference error: \(error.localizedDescription)")
            throw PaceMLXPlannerError.inferenceFailed(
                underlyingErrorDescription: error.localizedDescription
            )
        }

        // Successful turn — increment the cached turn count so the
        // next call's hit-check accepts the now-larger conversation.
        Self.incrementCachedTurnCountAfterSuccessfulTurn()

        let elapsedSeconds = Date().timeIntervalSince(inferenceStartedAt)
        return (text: accumulatedText, duration: elapsedSeconds)
        #else
        _ = (images, systemPrompt, conversationHistory, userPrompt, onTextChunk)
        throw PaceMLXPlannerError.runtimeNotLinked
        #endif
    }

    // MARK: - Pure helpers

    /// Pace passes the full conversation history with every turn —
    /// the planner protocol is stateless. ChatSession's per-call
    /// `respond(to:)` replaces its message buffer on every call so
    /// history doesn't carry over through that path; we flatten the
    /// history into a single prompt string instead. Result is one
    /// stable, stateless turn shape that matches LocalPlannerClient.
    nonisolated static func combineHistoryIntoUserPrompt(
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String
    ) -> String {
        guard !conversationHistory.isEmpty else { return userPrompt }
        var renderedHistory = ""
        for (priorUser, priorAssistant) in conversationHistory {
            renderedHistory += "User: \(priorUser)\nAssistant: \(priorAssistant)\n\n"
        }
        return renderedHistory + "User: \(userPrompt)"
    }

    #if canImport(MLXLLM)
    /// Lever #1 — persistent session cache for KV-cache reuse.
    /// One slot for the whole process. Across turns: if the model
    /// identifier hasn't changed, the system prompt hasn't changed,
    /// AND the conversation count matches what we expect, we
    /// reuse the cached `ChatSession` (which preserves KV state
    /// across `streamResponse` calls inside its Generator).
    private struct CachedSessionState {
        let modelIdentifier: String
        let systemPromptHash: Int
        // Turn count "reflected" in the cache — meaning the cache
        // already holds the KV state for this many (user, assistant)
        // turn pairs. Incremented after each successful turn.
        var turnsReflectedInCache: Int
        let session: ChatSession
    }

    private static let sessionCacheLock = NSLock()
    private static var cachedSessionState: CachedSessionState?

    /// Outcome of the per-turn cache lookup. Wrapped in an enum
    /// rather than returning the session directly so the caller's
    /// switch statement makes the two paths visibly distinct (and
    /// so a future "stale cache; rebuild but keep the same key"
    /// case can be added without changing the call sites).
    private enum SessionCacheDecision {
        case reuseExisting(ChatSession)
        case rebuildRequired
    }

    /// Examine the cached session state; return the cached session
    /// if the requested turn is a continuation, else invalidate the
    /// cache slot and tell the caller to rebuild.
    private static func lookUpOrInvalidateSessionCache(
        requestedModelIdentifier: String,
        requestedSystemPromptHash: Int,
        requestedConversationTurnCount: Int
    ) -> SessionCacheDecision {
        sessionCacheLock.lock()
        defer { sessionCacheLock.unlock() }
        guard let cached = cachedSessionState else {
            return .rebuildRequired
        }
        let isContinuation =
            cached.modelIdentifier == requestedModelIdentifier
            && cached.systemPromptHash == requestedSystemPromptHash
            && cached.turnsReflectedInCache == requestedConversationTurnCount
        if isContinuation {
            return .reuseExisting(cached.session)
        }
        // Cache key mismatch — drop the cached session so this
        // turn rebuilds and subsequent turns can hit the new cache.
        cachedSessionState = nil
        return .rebuildRequired
    }

    private static func installFreshSessionAsCache(
        modelIdentifier: String,
        systemPromptHash: Int,
        priorTurnCountReflectedAtBuildTime: Int,
        session: ChatSession
    ) {
        sessionCacheLock.lock()
        cachedSessionState = CachedSessionState(
            modelIdentifier: modelIdentifier,
            systemPromptHash: systemPromptHash,
            // When we BUILD the session and send the flattened
            // history, the cache reflects all `prior` turns plus the
            // turn we're about to do. The turn count update happens
            // in `incrementCachedTurnCountAfterSuccessfulTurn`
            // AFTER streaming completes — so set the baseline here
            // to the count the CALLER sees right now, and bump it
            // once the turn lands.
            turnsReflectedInCache: priorTurnCountReflectedAtBuildTime,
            session: session
        )
        sessionCacheLock.unlock()
    }

    private static func incrementCachedTurnCountAfterSuccessfulTurn() {
        sessionCacheLock.lock()
        if var state = cachedSessionState {
            state.turnsReflectedInCache += 1
            cachedSessionState = state
        }
        sessionCacheLock.unlock()
    }

    /// Drop the cached session — used after a mid-stream error so
    /// the next turn doesn't continue from a possibly-corrupt KV
    /// state. Also called by tests + by anything that knows the
    /// conversation reset (e.g. an explicit thread-memory clear).
    static func invalidateSessionCache(reason: String) {
        sessionCacheLock.lock()
        let hadSession = cachedSessionState != nil
        cachedSessionState = nil
        sessionCacheLock.unlock()
        if hadSession {
            print("🧠 PaceMLXPlannerClient cache invalidated — \(reason)")
        }
    }

    /// Single per-process model container. The 4B MLX assets are
    /// ~2-3 GB once dequantised; loading them multiple times would
    /// blow memory and double-trigger ANE warm-up.
    private static var cachedModelContainer: ModelContainer?
    private static let modelLoadLock = NSLock()

    private static func sharedModelContainer(
        modelIdentifier: String,
        progressHandler: @Sendable @escaping (Progress) -> Void = { _ in }
    ) async throws -> ModelContainer {
        modelLoadLock.lock()
        let cached = cachedModelContainer
        modelLoadLock.unlock()
        if let cached { return cached }

        let loaded = try await MLXLMCommon.loadModelContainer(
            id: modelIdentifier,
            progressHandler: progressHandler
        )

        modelLoadLock.lock()
        cachedModelContainer = loaded
        modelLoadLock.unlock()
        return loaded
    }
    #endif
}
