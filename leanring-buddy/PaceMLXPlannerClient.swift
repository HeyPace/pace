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
            return
                "MLX runtime not linked into this build. Add `mlx-swift-examples` as a Swift Package dependency in Xcode → Project → Package Dependencies."
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
    private let requestsStructuredActionOutput: Bool

    let displayName: String
    let supportsImageInput: Bool = false

    init(
        modelIdentifier: String = "mlx-community/Qwen3-4B-Instruct-4bit",
        generationTemperature: Float = 0.0,
        requestsStructuredActionOutput: Bool = true
    ) {
        self.modelIdentifier = modelIdentifier
        self.generationTemperature = generationTemperature
        self.requestsStructuredActionOutput = requestsStructuredActionOutput
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
        let trimmedSegment =
            lastSegment
            .replacingOccurrences(of: "-Instruct-4bit", with: "")
            .replacingOccurrences(of: "-Instruct", with: "")
            .replacingOccurrences(of: "-4bit", with: "")
        return trimmedSegment
    }

    /// Hugging Face's Python/CLI cache and MLX Swift's Hub client use
    /// different default roots. Reuse a complete CLI snapshot when it is
    /// already present so Pace does not download a second multi-gigabyte copy.
    nonisolated static func standardHuggingFaceRepositoryCacheDirectory(
        modelIdentifier: String,
        homeDirectoryURL: URL
    ) -> URL {
        let repositoryDirectoryName =
            "models--"
            + modelIdentifier
            .split(separator: "/")
            .joined(separator: "--")
        return
            homeDirectoryURL
            .appendingPathComponent(".cache", isDirectory: true)
            .appendingPathComponent("huggingface", isDirectory: true)
            .appendingPathComponent("hub", isDirectory: true)
            .appendingPathComponent(repositoryDirectoryName, isDirectory: true)
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
            if !requestsStructuredActionOutput {
                // Feature-specific JSON contracts must not inherit agent reasoning or action output.
                wrappedSystemPrompt = systemPrompt
            } else if systemPrompt.isEmpty {
                wrappedSystemPrompt = CompanionSystemPrompt.planThenExecuteScaffoldForBundledMLX
            } else {
                wrappedSystemPrompt = CompanionSystemPrompt.wrapWithPlanThenExecuteScaffoldForBundledMLX(
                    systemPrompt
                )
            }

            // The pinned ChatSession API replaces its messages when streaming,
            // discarding system instructions and retaining an unrelated token cache.
            // Prepare explicit roles with a fresh cache so each request honors its contract.
            var messages: [Chat.Message] = []
            if !wrappedSystemPrompt.isEmpty {
                messages.append(.system(wrappedSystemPrompt))
            }
            for turn in conversationHistory {
                if !turn.userPlaceholder.isEmpty {
                    messages.append(.user(turn.userPlaceholder))
                }
                if !turn.assistantResponse.isEmpty {
                    messages.append(.assistant(turn.assistantResponse))
                }
            }
            messages.append(.user(userPrompt))
            let preparedMessages = messages
            let generationParameters = GenerateParameters(
                maxTokens: 2048, temperature: generationTemperature
            )
            let accumulatedText: String
            do {
                accumulatedText = try await modelContainer.perform { context in
                    let input = try await context.processor.prepare(input: UserInput(chat: preparedMessages))
                    let cache = context.model.newCache(parameters: generationParameters)
                    var responseText = ""
                    for await item in try MLXLMCommon.generate(
                        input: input, cache: cache, parameters: generationParameters, context: context
                    ) {
                        try Task.checkCancellation()
                        if let textChunk = item.chunk {
                            responseText += textChunk
                            await onTextChunk(textChunk)
                        }
                    }
                    return responseText
                }
            } catch {
                throw PaceMLXPlannerError.inferenceFailed(
                    underlyingErrorDescription: error.localizedDescription
                )
            }

            let elapsedSeconds = Date().timeIntervalSince(inferenceStartedAt)
            return (text: accumulatedText, duration: elapsedSeconds)
        #else
            _ = (images, systemPrompt, conversationHistory, userPrompt, onTextChunk)
            throw PaceMLXPlannerError.runtimeNotLinked
        #endif
    }

    #if canImport(MLXLLM)
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

            let loaded: ModelContainer
            if let existingSnapshotDirectory = existingStandardHuggingFaceSnapshotDirectory(
                modelIdentifier: modelIdentifier
            ) {
                print("🧠 PaceMLXPlannerClient: reusing Hugging Face cache at \(existingSnapshotDirectory.path)")
                loaded = try await MLXLMCommon.loadModelContainer(
                    directory: existingSnapshotDirectory,
                    progressHandler: progressHandler
                )
            } else {
                loaded = try await MLXLMCommon.loadModelContainer(
                    id: modelIdentifier,
                    progressHandler: progressHandler
                )
            }

            modelLoadLock.lock()
            cachedModelContainer = loaded
            modelLoadLock.unlock()
            return loaded
        }

        private static func existingStandardHuggingFaceSnapshotDirectory(
            modelIdentifier: String
        ) -> URL? {
            let fileManager = FileManager.default
            let repositoryDirectory = standardHuggingFaceRepositoryCacheDirectory(
                modelIdentifier: modelIdentifier,
                homeDirectoryURL: fileManager.homeDirectoryForCurrentUser
            )
            let mainReferenceURL =
                repositoryDirectory
                .appendingPathComponent("refs", isDirectory: true)
                .appendingPathComponent("main", isDirectory: false)
            guard
                let mainRevision = try? String(contentsOf: mainReferenceURL, encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                !mainRevision.isEmpty
            else {
                return nil
            }

            let snapshotDirectory =
                repositoryDirectory
                .appendingPathComponent("snapshots", isDirectory: true)
                .appendingPathComponent(mainRevision, isDirectory: true)
            let configurationURL = snapshotDirectory.appendingPathComponent("config.json")
            guard fileManager.fileExists(atPath: configurationURL.path),
                let snapshotFileNames = try? fileManager.contentsOfDirectory(
                    atPath: snapshotDirectory.path
                ),
                snapshotFileNames.contains(where: { $0.hasSuffix(".safetensors") })
            else {
                return nil
            }
            return snapshotDirectory
        }
    #endif
}
