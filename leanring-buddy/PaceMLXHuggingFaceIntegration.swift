import Foundation

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
