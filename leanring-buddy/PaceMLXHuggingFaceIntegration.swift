import Foundation

nonisolated enum PaceMLXModelCache {
    static func standardRepositoryDirectory(modelIdentifier: String, homeDirectoryURL: URL) -> URL {
        homeDirectoryURL.appendingPathComponent(".cache/huggingface/hub", isDirectory: true)
            .appendingPathComponent("models--" + modelIdentifier.replacingOccurrences(of: "/", with: "--"))
    }

    static func cachedModelDirectory(
        modelIdentifier: String, revision: String? = nil, useLatest: Bool = false,
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL? {
        guard !useLatest, revision == nil || revision == "main",
            modelIdentifier.range(
                of: #"^[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*$"#,
                options: .regularExpression) != nil
        else { return nil }
        let repository = standardRepositoryDirectory(
            modelIdentifier: modelIdentifier, homeDirectoryURL: homeDirectoryURL)
        var candidates: [URL] = []
        if let reference = try? String(contentsOf: repository.appendingPathComponent("refs/main"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
            reference.range(of: #"^[a-fA-F0-9]{40,64}$"#, options: .regularExpression) != nil
        {
            candidates.append(repository.appendingPathComponent("snapshots/" + reference, isDirectory: true))
        }
        // MLX 2 used these HubApi roots for LLM/VLM and embedding assets.
        for root in ["Library/Caches/models", "Documents/huggingface/models"] {
            candidates.append(
                homeDirectoryURL.appendingPathComponent(root, isDirectory: true)
                    .appendingPathComponent(modelIdentifier, isDirectory: true))
        }
        return candidates.first(where: containsCompleteModel)
    }

    private static func containsCompleteModel(at directory: URL) -> Bool {
        func containsFile(_ name: String) -> Bool {
            let path = directory.appendingPathComponent(name).path
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue,
                let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                let size = attributes[.size] as? NSNumber
            else { return false }
            return size.intValue > 0
        }
        guard ["config.json", "tokenizer.json", "tokenizer_config.json"].allSatisfy(containsFile),
            let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path),
            names.contains(where: { $0.hasSuffix(".safetensors") && containsFile($0) })
        else { return false }
        let indexName = "model.safetensors.index.json"
        guard names.contains(indexName) else { return true }
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(indexName)),
            let index = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let weights = index["weight_map"] as? [String: String], !weights.isEmpty
        else { return false }
        return Set(weights.values).allSatisfy { name in
            !name.contains("/") && name.hasSuffix(".safetensors") && containsFile(name)
        }
    }
}

#if canImport(MLXLMCommon)
    import HuggingFace
    import MLXLMCommon
    import Tokenizers

    // MLX 3 separates provider implementations from its loading protocols. Keep
    // these mappings shared by the planner, screen reader and embedder; the
    // upstream libraries still own downloads, caching and tokenization.
    nonisolated struct PaceMLXHuggingFaceDownloader: MLXLMCommon.Downloader {
        func download(
            id: String,
            revision: String?,
            matching patterns: [String],
            useLatest: Bool,
            progressHandler: @Sendable @escaping (Progress) -> Void
        ) async throws -> URL {
            guard let repository = HuggingFace.Repo.ID(rawValue: id) else {
                throw URLError(.badURL)
            }
            try Task.checkCancellation()
            if let cachedDirectory = PaceMLXModelCache.cachedModelDirectory(
                modelIdentifier: id, revision: revision, useLatest: useLatest)
            {
                let progress = Progress(totalUnitCount: 1)
                progress.completedUnitCount = 1
                progressHandler(progress)
                return cachedDirectory
            }
            return try await HubClient().downloadSnapshot(
                of: repository,
                revision: revision ?? "main",
                matching: patterns,
                progressHandler: { progress in progressHandler(progress) }
            )
        }
    }

    nonisolated struct PaceMLXHuggingFaceTokenizerLoader: MLXLMCommon.TokenizerLoader {
        func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
            let tokenizer = try await AutoTokenizer.from(modelFolder: directory)
            return PaceMLXHuggingFaceTokenizer(upstream: tokenizer)
        }
    }

    nonisolated struct PaceMLXHuggingFaceTokenizer: MLXLMCommon.Tokenizer {
        let upstream: any Tokenizers.Tokenizer

        func encode(text: String, addSpecialTokens: Bool) -> [Int] {
            upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
        }

        func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
            upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
        }

        func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
        func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }
        var bosToken: String? { upstream.bosToken }
        var eosToken: String? { upstream.eosToken }
        var unknownToken: String? { upstream.unknownToken }

        func applyChatTemplate(
            messages: [[String: any Sendable]],
            tools: [[String: any Sendable]]?,
            additionalContext: [String: any Sendable]?
        ) throws -> [Int] {
            do {
                return try upstream.applyChatTemplate(
                    messages: messages, tools: tools, additionalContext: additionalContext)
            } catch Tokenizers.TokenizerError.missingChatTemplate {
                throw MLXLMCommon.TokenizerError.missingChatTemplate
            }
        }
    }
#endif
