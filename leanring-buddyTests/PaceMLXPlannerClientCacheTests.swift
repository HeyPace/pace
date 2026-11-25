//
//  PaceMLXPlannerClientCacheTests.swift
//  leanring-buddyTests
//
//  Local planner runtime and Hugging Face asset-cache checks.

import Foundation
import Testing

@testable import Pace

#if canImport(MLXLLM)
    import MLXLMCommon
#endif

@MainActor
struct PaceMLXPlannerClientCacheTests {

    private func writeCompleteModel(at directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in ["config.json", "tokenizer.json", "tokenizer_config.json", "model.safetensors"] {
            let contents = name == "tokenizer_config.json" ? #"{"chat_template":"{{ messages }}"}"# : "fixture"
            try Data(contents.utf8).write(to: directory.appendingPathComponent(name))
        }
    }

    @Test func migrationReusesBothLegacyModelRootsWithoutMovingFiles() throws {
        for root in ["Library/Caches/models", "Documents/huggingface/models"] {
            let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: home) }
            let cached = home.appendingPathComponent(root + "/example/model", isDirectory: true)
            try writeCompleteModel(at: cached)
            let resolved = PaceMLXModelCache.cachedModelDirectory(
                modelIdentifier: "example/model", homeDirectoryURL: home)
            #expect(resolved?.path == cached.path)
            #expect(
                try String(contentsOf: cached.appendingPathComponent("model.safetensors"), encoding: .utf8) == "fixture"
            )
            #expect(
                PaceMLXModelCache.cachedModelDirectory(
                    modelIdentifier: "example/model", useLatest: true, homeDirectoryURL: home) == nil)
            #expect(
                PaceMLXModelCache.cachedModelDirectory(
                    modelIdentifier: "example/model", revision: "other", homeDirectoryURL: home) == nil)
            #expect(
                PaceMLXModelCache.cachedModelDirectory(modelIdentifier: "../example/model", homeDirectoryURL: home)
                    == nil)
        }
    }

    @Test func currentSnapshotTakesPriorityAndPartialShardsAreNotReused() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let legacy = home.appendingPathComponent("Library/Caches/models/example/model", isDirectory: true)
        try writeCompleteModel(at: legacy)
        let index = #"{"weight_map":{"first":"model.safetensors","second":"second.safetensors"}}"#
        try Data(index.utf8).write(to: legacy.appendingPathComponent("model.safetensors.index.json"))
        #expect(PaceMLXModelCache.cachedModelDirectory(modelIdentifier: "example/model", homeDirectoryURL: home) == nil)
        try Data("second shard".utf8).write(to: legacy.appendingPathComponent("second.safetensors"))
        #expect(
            PaceMLXModelCache.cachedModelDirectory(modelIdentifier: "example/model", homeDirectoryURL: home)?.path
                == legacy.path)
        let repository = PaceMLXModelCache.standardRepositoryDirectory(
            modelIdentifier: "example/model", homeDirectoryURL: home)
        let revision = String(repeating: "a", count: 40)
        let current = repository.appendingPathComponent("snapshots/" + revision, isDirectory: true)
        try writeCompleteModel(at: current)
        try FileManager.default.createDirectory(
            at: repository.appendingPathComponent("refs"), withIntermediateDirectories: true)
        try Data(revision.utf8).write(to: repository.appendingPathComponent("refs/main"))
        #expect(
            PaceMLXModelCache.cachedModelDirectory(modelIdentifier: "example/model", homeDirectoryURL: home)?.path
                == current.path)
    }

    @Test func chatModelsRequireTemplatesButEncoderCachesDoNot() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let directory = home.appendingPathComponent("Library/Caches/models/example/model", isDirectory: true)
        try writeCompleteModel(at: directory)
        try Data("{}".utf8).write(to: directory.appendingPathComponent("tokenizer_config.json"))
        #expect(PaceMLXModelCache.cachedModelDirectory(modelIdentifier: "example/model", homeDirectoryURL: home) == nil)
        #expect(
            PaceMLXModelCache.cachedModelDirectory(
                modelIdentifier: "example/model", requiresChatTemplate: false, homeDirectoryURL: home)?.path
                == directory.path)
        try Data("{{ messages }}".utf8).write(to: directory.appendingPathComponent("chat_template.jinja"))
        #expect(
            PaceMLXModelCache.cachedModelDirectory(modelIdentifier: "example/model", homeDirectoryURL: home)?.path
                == directory.path)
    }

    @Test func anInterruptedShardDownloadWithoutAnIndexIsNotReused() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let directory = home.appendingPathComponent("Library/Caches/models/example/model", isDirectory: true)
        try writeCompleteModel(at: directory)
        try Data("first shard".utf8).write(to: directory.appendingPathComponent("model-00001-of-00002.safetensors"))
        #expect(PaceMLXModelCache.cachedModelDirectory(modelIdentifier: "example/model", homeDirectoryURL: home) == nil)
    }

    @Test func tokenizerAdapterLoadsLocalVocabularyWithoutDownloadingAModel() async throws {
        #if canImport(MLXLLM)
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let tokenizerJSON =
                ###"{"version":"1.0","normalizer":{"type":"BertNormalizer","clean_text":true,"handle_chinese_chars":true,"strip_accents":null,"lowercase":true},"pre_tokenizer":{"type":"BertPreTokenizer"},"model":{"type":"WordPiece","unk_token":"[UNK]","continuing_subword_prefix":"##","max_input_chars_per_word":100,"vocab":{"[UNK]":0,"[CLS]":1,"[SEP]":2,"hello":3}}}"###
            let configuration =
                #"{"tokenizer_class":"BertTokenizer","unk_token":"[UNK]","cls_token":"[CLS]","sep_token":"[SEP]","eos_token":"[SEP]","model_max_length":512}"#
            try Data(tokenizerJSON.utf8).write(to: directory.appendingPathComponent("tokenizer.json"))
            try Data(configuration.utf8).write(to: directory.appendingPathComponent("tokenizer_config.json"))
            let tokenizer = try await PaceMLXHuggingFaceTokenizerLoader().load(from: directory)
            #expect(tokenizer.encode(text: "Hello", addSpecialTokens: false) == [3])
            #expect(tokenizer.decode(tokenIds: [3], skipSpecialTokens: true) == "hello")
            #expect(tokenizer.eosTokenId == 2)
            #expect(tokenizer.convertIdToToken(3) == "hello")
        #endif
    }

    @Test func localModelHonorsSystemAndHistoryWithoutLeakingPreviousRequestWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["PACE_RUN_LOCAL_NOTES"] == "1" else { return }
        let planner = PaceMLXPlannerClient(
            modelIdentifier: PaceBundledModelsSettings.plannerModelIdentifier(),
            requestsStructuredActionOutput: false
        )
        let firstResult = try await planner.generateResponseStreaming(
            images: [],
            systemPrompt: "Return ONLY a JSON object containing the saved code under the key code.",
            conversationHistory: [("Save this code: cobalt", "The saved code is cobalt.")],
            userPrompt: "Return the saved code.",
            onTextChunk: { _ in }
        )
        let firstObject = try JSONSerialization.jsonObject(with: Data(firstResult.text.utf8)) as? [String: String]
        #expect(firstObject?["code"] == "cobalt")
        let secondResult = try await planner.generateResponseStreaming(
            images: [],
            systemPrompt: "Reply with exactly the word cedar. No other text.",
            conversationHistory: [],
            userPrompt: "What is the saved code?",
            onTextChunk: { _ in }
        )
        #expect(secondResult.text.trimmingCharacters(in: .whitespacesAndNewlines) == "cedar")
    }

    @Test func runtimeAvailabilityFlagMatchesCanImport() async throws {
        // The compile-time flag this whole cache layer depends on.
        // If MLXLLM imports flip false, every cache method becomes
        // a no-op and the production code falls back to the
        // not-linked error path.
        #if canImport(MLXLLM)
            #expect(PaceMLXPlannerClient.isRuntimeAvailable == true)
        #else
            #expect(PaceMLXPlannerClient.isRuntimeAvailable == false)
        #endif
    }

    @Test func shortenedModelLabelStripsQuantizationSuffix() async throws {
        // The bf16 ↔ 4-bit toggle (Lever #4) lives on the same
        // model lineage; the display-label helper should strip
        // both quantization suffixes so the Settings UI shows
        // "Qwen3-4B" regardless of which variant the user picked.
        let bf16Label = PaceMLXPlannerClient.shortenedModelLabel(
            forIdentifier: "mlx-community/Qwen3-4B-Instruct-2507-bf16"
        )
        let fourBitLabel = PaceMLXPlannerClient.shortenedModelLabel(
            forIdentifier: "mlx-community/Qwen3-4B-Instruct-2507-4bit"
        )
        #expect(bf16Label.contains("Qwen3-4B"))
        #expect(fourBitLabel.contains("Qwen3-4B"))
    }

    @Test func standardHuggingFaceCachePathMatchesTheCLIConvention() async throws {
        let repositoryDirectory = PaceMLXPlannerClient.standardHuggingFaceRepositoryCacheDirectory(
            modelIdentifier: "mlx-community/Qwen3-4B-Instruct-2507-4bit",
            homeDirectoryURL: URL(fileURLWithPath: "/Users/example", isDirectory: true)
        )

        #expect(
            repositoryDirectory.path
                == "/Users/example/.cache/huggingface/hub/models--mlx-community--Qwen3-4B-Instruct-2507-4bit")
    }
}
